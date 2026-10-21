#!/usr/bin/env python3
"""Capture compositor frames requested by the synthetic native video tests only.

Run beside the serial native test invocation; stop it when that invocation ends.
No apps are launched. Only this exact bundle's data/tmp request prefix is read.
"""
import argparse
import itertools
import json
import math
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import threading
import time
import uuid

BUNDLE = "dev.galaxybigbird.OfflineTikTokPlayer"
PREFIX = "OfflinePlayer-TestFrameCapture-"
REQUEST = re.compile(r"^" + PREFIX + r"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.request\.json$")
DEADLINE = float("inf")
WORKER_PREFIX = "OfflinePlayer-TestWorkerTrace-"
WORKER_REQUEST = re.compile(r"^" + WORKER_PREFIX + r"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.request\.json$")
WORKER_REPORT_LIMIT = 16 * 1024 * 1024
WORKER_SECTION_LIMIT = 64 * 1024


class WorkerTraceStopped(Exception):
    pass


def trace_termination_handler(stop):
    def terminate(_number, _frame):
        stop.set()
        raise SystemExit(0)
    return terminate


def canonical_worker_id(value):
    try:
        return type(value) is str and str(uuid.UUID(value)) == value
    except ValueError:
        return False


def worker_section(report, worker_id):
    """Return only this decoder's call-graph sections, never another worker."""
    if not canonical_worker_id(worker_id):
        raise ValueError("Invalid worker UUID")
    thread = re.compile(r"^\s*(?:\d+\s+)?Thread[_ ](?:0x)?[0-9a-fA-F]+\b")
    queue = re.compile(r"\bDispatchQueue[_ ]\d+:\s*OfflineTikTokPlayer\.PCMDecode\." + re.escape(worker_id) + r"(?=\s|\(|$)")
    any_decoder = re.compile(r"\bDispatchQueue[_ ]\d+:\s*OfflineTikTokPlayer\.PCMDecode(?:\.[0-9a-fA-F-]+)?(?=\s|\(|$)")
    lines, size, decoder_count = [], 0, 0
    in_graph = selected = truncated = full = False
    for line in report.splitlines():
        if line.strip() == "Call graph:":
            in_graph = True
            continue
        if not in_graph:
            continue
        if line.strip().startswith(("Total number in stack", "Sort by top of stack", "Binary Images:", "Analysis of sampling")):
            break
        if thread.match(line):
            decoder_count += int(any_decoder.search(line) is not None)
            selected = queue.search(line) is not None
            if not selected:
                continue
        elif not selected:
            continue
        elif line.strip() and not re.match(r"^\s*(?:[+!:|]|\d+\s)", line):
            selected = False
            continue
        encoded = (line + "\n").encode("utf-8")
        if full or size + len(encoded) > WORKER_SECTION_LIMIT:
            truncated = full = True
            continue
        lines.append(line + "\n")
        size += len(encoded)
    return "".join(lines), truncated, decoder_count


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate request key")
        result[key] = value
    return result


class WorkerTraceWatcher:
    """Explicit failure/calibration observer; never launches or discovers processes."""
    def __init__(self, udid, temporary, stop):
        self.udid, self.temporary, self.stop = udid, temporary, stop
        self.seen = set()
        self.processed = 0
        self.purposes = set()
        self.profile_count = 0
        self.application_queried = False
        self.application = None

    def _owned_identity(self, path):
        if (self.temporary.is_symlink() or self.temporary.resolve(strict=True) != self.temporary
                or path.parent != self.temporary or path.is_symlink()
                or path.resolve(strict=True).parent != self.temporary):
            raise ValueError("Unsafe trace path")
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode):
            raise ValueError("Non-regular trace path")
        return info.st_dev, info.st_ino

    def _read(self, path, maximum, identity):
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        with os.fdopen(descriptor, "rb") as stream:
            info = os.fstat(stream.fileno())
            if (not stat.S_ISREG(info.st_mode) or (info.st_dev, info.st_ino) != identity
                    or info.st_size > maximum):
                raise ValueError("Unsafe or oversized trace file")
            data = stream.read(maximum + 1)
        if len(data) > maximum:
            raise ValueError("Oversized trace file")
        return data

    def _remove(self, path, identity):
        if identity is None:
            return
        try:
            if self._owned_identity(path) == identity:
                path.unlink()
        except (OSError, ValueError):
            pass

    def _command(self, arguments, timeout):
        remaining = min(timeout, DEADLINE - time.monotonic())
        if self.stop.is_set() or remaining <= 0:
            raise WorkerTraceStopped()
        expires = time.monotonic() + remaining
        capture_output = (arguments[0] == "/bin/ps"
                          or arguments[:3] == ["/usr/bin/xcrun", "simctl", "get_app_container"])
        output_mode = subprocess.PIPE if capture_output else subprocess.DEVNULL
        process = subprocess.Popen(arguments, stdout=output_mode, stderr=subprocess.DEVNULL,
                                   text=True)
        try:
            while True:
                if self.stop.is_set() or time.monotonic() >= DEADLINE:
                    raise WorkerTraceStopped()
                remaining = expires - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(arguments, timeout)
                try:
                    output, _ = process.communicate(timeout=min(0.1, remaining))
                    if self.stop.is_set() or time.monotonic() >= DEADLINE:
                        raise WorkerTraceStopped()
                    return subprocess.CompletedProcess(arguments, process.returncode, output or "", "")
                except subprocess.TimeoutExpired:
                    continue
        finally:
            if process.poll() is None:
                process.kill()
                try:
                    process.communicate(timeout=0.25)
                except subprocess.TimeoutExpired:
                    pass

    def _owns_process(self, process_id):
        result = self._command(["/bin/ps", "-ww", "-p", str(process_id), "-o", "comm="], timeout=1)
        if result.returncode:
            return None
        output = result.stdout.strip()
        if not output or len(output) > 4096 or len(output.splitlines()) != 1:
            return False
        executable = Path(output)
        if not executable.is_absolute() or str(executable) != output:
            return False
        # The data-container and bundle-container UUIDs differ, but both must
        # belong to this exact, already located Simulator device root.
        if len(self.temporary.parents) < 6:
            return False
        device = self.temporary.parents[5]
        relative = self.temporary.relative_to(device).parts
        if (device.name.upper() != self.udid.upper() or len(relative) != 6
                or relative[:4] != ("data", "Containers", "Data", "Application")
                or relative[-1] != "tmp"):
            return False
        uuid.UUID(relative[4])
        bundles = device / "data" / "Containers" / "Bundle" / "Application"
        try:
            parts = executable.relative_to(bundles).parts
        except ValueError:
            return False
        if len(parts) != 3 or parts[1:] != ("OfflineTikTokPlayer.app", "OfflineTikTokPlayer"):
            return False
        uuid.UUID(parts[0])
        if (executable.is_symlink() or not executable.is_file()
                or executable.resolve(strict=True) != executable):
            return False
        if not self.application_queried:
            self.application_queried = True
            result = self._command(["/usr/bin/xcrun", "simctl", "get_app_container", self.udid, BUNDLE, "app"], timeout=1)
            if result.returncode:
                return False
            output = result.stdout.strip()
            if not output or len(output) > 4096 or len(output.splitlines()) != 1:
                return False
            application = Path(output)
            if (not application.is_absolute() or str(application) != output or application.is_symlink()
                    or not application.is_dir() or application.resolve(strict=True) != application):
                return False
            try:
                parts = application.relative_to(bundles).parts
            except ValueError:
                return False
            if len(parts) != 2 or parts[1] != "OfflineTikTokPlayer.app":
                return False
            uuid.UUID(parts[0])
            self.application = application
        return self.application is not None and executable == self.application / "OfflineTikTokPlayer"

    def process_request(self, request, identifier):
        if identifier in self.seen or self.processed >= 32:
            return
        self.seen.add(identifier)
        self.processed += 1
        purpose, code, section, truncated, native_returncode = -1, 1, "", False, -1
        sample_started, sample_elapsed = -1.0, 0.0
        worker_id, decoder_count = None, 0
        request_identity = report_identity = None
        report = self.temporary / f"{WORKER_PREFIX}{identifier}.sample.txt"
        try:
            if self.stop.is_set() or time.monotonic() >= DEADLINE:
                raise WorkerTraceStopped()
            if (str(uuid.UUID(identifier)) != identifier
                    or request.name != f"{WORKER_PREFIX}{identifier}.request.json"):
                return
            request_identity = self._owned_identity(request)
            payload = json.loads(self._read(request, 4096, request_identity).decode("utf-8"),
                                 object_pairs_hook=_unique_object)
            if (not isinstance(payload, dict)
                    or set(payload) != {"schemaVersion", "requestID", "processID", "purposeCode", "workerID"}
                    or type(payload["schemaVersion"]) is not int or payload["schemaVersion"] != 2
                    or payload["requestID"] != identifier
                    or type(payload["processID"]) is not int or not 0 < payload["processID"] <= 2**31 - 1
                    or type(payload["purposeCode"]) is not int or payload["purposeCode"] not in (0, 1, 2)
                    or not canonical_worker_id(payload["workerID"])):
                return
            purpose = payload["purposeCode"]
            worker_id = payload["workerID"]
            if purpose in self.purposes or self.profile_count >= 2:
                code = 3
                return
            code = 5
            owned = self._owns_process(payload["processID"])
            if owned is None:
                return
            if not owned:
                code = 2
                return
            code = 9
            if report.exists() or report.is_symlink() or report.resolve().parent != self.temporary:
                return
            descriptor = os.open(report, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            info = os.fstat(descriptor)
            report_identity = info.st_dev, info.st_ino
            os.close(descriptor)
            self.purposes.add(purpose)
            self.profile_count += 1
            code = 8
            sample_started = time.monotonic()
            try:
                result = self._command(["/usr/bin/sample", str(payload["processID"]), "1", "-file", str(report)], timeout=4)
            finally:
                sample_elapsed = time.monotonic() - sample_started
            native_returncode = result.returncode
            if result.returncode:
                return
            code = 9
            if self._owned_identity(report) != report_identity:
                return
            raw = self._read(report, WORKER_REPORT_LIMIT, report_identity)
            section, truncated, decoder_count = worker_section(raw.decode("utf-8", errors="replace"), worker_id)
            code = 0 if section else 10
        except WorkerTraceStopped:
            code = 4
        except subprocess.TimeoutExpired:
            code = 11
        except FileNotFoundError:
            code = 6 if code == 8 else code
        except PermissionError:
            code = 7 if code == 8 else code
        except (OSError, ValueError, TypeError, UnicodeError):
            pass
        finally:
            self._remove(report, report_identity)
            self._remove(request, request_identity)
            worker_field = f" workerID={worker_id}" if worker_id is not None else ""
            print(f"NativeWorkerTraceResult requestID={identifier} purposeCode={purpose}{worker_field} statusCode={code} nativeReturnCode={native_returncode} bytes={len(section.encode('utf-8'))} truncated={int(truncated)} decoderQueueCount={decoder_count} startUptime={sample_started:.6f} elapsedSeconds={sample_elapsed:.6f}", flush=True)
            if section:
                print(section, end="", flush=True)

    def poll_once(self):
        if self.stop.is_set() or time.monotonic() >= DEADLINE or self.processed >= 32:
            return
        try:
            if self.temporary.resolve(strict=True) != self.temporary or not self.temporary.is_dir():
                return
            for request in itertools.islice(self.temporary.glob(WORKER_PREFIX + "*.request.json"), 64):
                if self.stop.is_set() or time.monotonic() >= DEADLINE or self.processed >= 32:
                    break
                match = WORKER_REQUEST.fullmatch(request.name)
                if match:
                    self.process_request(request, match.group(1))
        except OSError:
            return

    def watch(self):
        while not self.stop.is_set() and time.monotonic() < DEADLINE and self.processed < 32:
            self.poll_once()
            self.stop.wait(0.1)


def run(*arguments, timeout=15):
    remaining = DEADLINE - time.monotonic()
    if remaining <= 0:
        raise subprocess.TimeoutExpired(["xcrun", "simctl", *arguments], timeout=0)
    return subprocess.run(["xcrun", "simctl", *arguments], capture_output=True,
                          text=True, timeout=min(timeout, remaining), check=False)


def regular(path, parent, maximum):
    if path.parent != parent or path.is_symlink() or path.resolve().parent != parent:
        return False
    info = path.stat()
    return stat.S_ISREG(info.st_mode) and info.st_size <= maximum


def locate(requested_udid):
    listing = run("list", "devices", "booted", "--json")
    if listing.returncode:
        return None
    devices = json.loads(listing.stdout).get("devices", {})
    for group in devices.values():
        for device in group:
            udid = device.get("udid", "")
            if device.get("state") != "Booted" or udid.upper() != requested_udid:
                continue
            result = run("get_app_container", udid, BUNDLE, "data")
            if result.returncode:
                continue
            container = Path(result.stdout.strip()).resolve(strict=True)
            temporary = (container / "tmp").resolve(strict=True)
            if temporary.is_dir() and temporary.is_relative_to(container):
                return udid, temporary
    return None


def resolve_destination(destination):
    """Resolve a supported xcodebuild destination without booting or launching anything."""
    fields = {}
    for entry in destination.split(","):
        key, separator, value = entry.strip().partition("=")
        key, value = key.strip(), value.strip()
        if not separator or key in fields or key not in {"platform", "name", "id", "OS"} or not value:
            raise ValueError("Unsupported or duplicate Simulator destination field")
        fields[key] = value
    if fields.get("platform") != "iOS Simulator" or not (fields.get("name") or fields.get("id")):
        raise ValueError("Destination must select an iOS Simulator by exact name or UUID")
    identifier = str(uuid.UUID(fields["id"])).upper() if "id" in fields else None
    wanted_os = fields.get("OS", "latest")
    wanted_version = None
    if wanted_os.lower() != "latest":
        if not re.fullmatch(r"\d+(?:\.\d+)*", wanted_os):
            raise ValueError("Simulator OS must be a numeric version or latest")
        wanted_version = tuple(int(part) for part in wanted_os.split("."))
    listing = run("list", "devices", "available", "--json")
    if listing.returncode:
        raise ValueError("Could not list available iOS Simulators")
    candidates = []
    for runtime, devices in json.loads(listing.stdout).get("devices", {}).items():
        match = re.search(r"(?:^|\.)iOS-(\d+(?:-\d+)*)$", runtime)
        if not match:
            continue
        version = tuple(int(part) for part in match.group(1).split("-"))
        if wanted_version and version[:len(wanted_version)] != wanted_version:
            continue
        for device in devices:
            if not device.get("isAvailable", False):
                continue
            udid = str(uuid.UUID(device["udid"])).upper()
            if identifier and udid != identifier:
                continue
            if "name" in fields and device.get("name") != fields["name"]:
                continue
            candidates.append((version, udid))
    if candidates and wanted_version is None:
        latest = max(version for version, _ in candidates)
        candidates = [candidate for candidate in candidates if candidate[0] == latest]
    if len(candidates) != 1:
        raise ValueError("Simulator destination is missing or ambiguous; supply an exact available UUID")
    return candidates[0][1]


def acknowledge(temporary, identifier, code):
    response = temporary / f"{PREFIX}{identifier}.response.json"
    if response.is_symlink() or response.resolve().parent != temporary:
        return
    if response.exists():
        return
    partial = temporary / f"{PREFIX}{identifier}.{uuid.uuid4()}.partial"
    payload = {"schemaVersion": 1, "requestID": identifier, "errorCode": code,
               "imageName": f"{PREFIX}{identifier}.png"}
    try:
        with partial.open("x", encoding="utf-8") as stream:
            json.dump(payload, stream, separators=(",", ":"))
        os.replace(partial, response)
    finally:
        partial.unlink(missing_ok=True)


def capture(udid, temporary, request, identifier):
    response = temporary / f"{PREFIX}{identifier}.response.json"
    if response.exists() or response.is_symlink():
        return
    image = temporary / f"{PREFIX}{identifier}.png"
    code = 1  # Invalid request or unsafe path.
    started = time.monotonic()
    try:
        if not regular(request, temporary, 4096):
            return
        payload = json.loads(request.read_text(encoding="utf-8"))
        if (not isinstance(payload, dict) or set(payload) != {"schemaVersion", "requestID"}
                or type(payload["schemaVersion"]) is not int or payload["schemaVersion"] != 1
                or payload["requestID"] != identifier or str(uuid.UUID(identifier)) != identifier):
            return
        if image.exists() or image.is_symlink() or image.resolve().parent != temporary:
            return
        code = 2  # The compositor capture command failed.
        result = run("io", udid, "screenshot", "--type=png", str(image), timeout=30)
        if result.returncode == 0 and regular(image, temporary, 32 * 1024 * 1024):
            code = 0
    except subprocess.TimeoutExpired:
        code = 3
    except (OSError, ValueError, TypeError):
        pass
    finally:
        print(f"SimulatorCaptureResult errorCode={code} startUptime={started:.6f} elapsedSeconds={time.monotonic() - started:.6f}", flush=True)
        acknowledge(temporary, identifier, code)


def main():
    global DEADLINE
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--udid", help="Exact test Simulator UUID; waits for this device to boot")
    mode.add_argument("--resolve-destination", help="Print only the exact available Simulator UUID and exit")
    parser.add_argument("--lifetime", type=float, default=1200)
    arguments = parser.parse_args()
    if arguments.resolve_destination:
        try:
            print(resolve_destination(arguments.resolve_destination))
        except (OSError, ValueError, TypeError, KeyError, subprocess.TimeoutExpired) as error:
            parser.error(str(error))
        return 0
    if not math.isfinite(arguments.lifetime) or arguments.lifetime <= 0:
        parser.error("--lifetime must be a positive finite number")
    try:
        arguments.udid = str(uuid.UUID(arguments.udid)).upper()
    except ValueError:
        parser.error("--udid must be a Simulator UUID")
    deadline = time.monotonic() + min(1200, arguments.lifetime)
    DEADLINE = deadline
    target = None
    next_lookup = 0.0
    trace_stop = threading.Event()
    trace_thread = None
    previous_termination = None
    if threading.current_thread() is threading.main_thread():
        previous_termination = signal.signal(signal.SIGTERM, trace_termination_handler(trace_stop))
    try:
        while time.monotonic() < deadline:
            if target is None:
                if time.monotonic() < next_lookup:
                    time.sleep(0.1)
                    continue
                next_lookup = time.monotonic() + 3
                try:
                    target = locate(arguments.udid)
                except (OSError, ValueError, TypeError, subprocess.TimeoutExpired):
                    target = None
                continue
            udid, temporary = target
            if trace_thread is None:
                watcher = WorkerTraceWatcher(udid, temporary, trace_stop)
                trace_thread = threading.Thread(target=watcher.watch, name="OfflinePlayer.NativeWorkerTrace", daemon=True)
                trace_thread.start()
            try:
                if not temporary.is_dir():
                    target = None
                    continue
                for request in temporary.glob(PREFIX + "*.request.json"):
                    if time.monotonic() >= deadline:
                        break
                    match = REQUEST.fullmatch(request.name)
                    if match:
                        capture(udid, temporary, request, match.group(1))
            except OSError:
                target = None
            time.sleep(0.1)
    finally:
        trace_stop.set()
        if trace_thread is not None:
            trace_thread.join(timeout=1)
        if previous_termination is not None:
            signal.signal(signal.SIGTERM, previous_termination)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(0)
