#!/usr/bin/env python3
"""Capture compositor frames requested by the synthetic native video tests only.

Run beside the serial native test invocation; stop it when that invocation ends.
No apps are launched. Only this exact bundle's data/tmp request prefix is read.
"""
import argparse
import json
import math
import os
from pathlib import Path
import re
import stat
import subprocess
import time
import uuid

BUNDLE = "dev.galaxybigbird.OfflineTikTokPlayer"
PREFIX = "OfflinePlayer-TestFrameCapture-"
REQUEST = re.compile(r"^" + PREFIX + r"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.request\.json$")
DEADLINE = float("inf")


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
    listing = run("list", "devices", "available", "--json", timeout=60)
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


def capture_lifecycle(event, reason, started, deadline, lifetime, observed):
    # Fixed numeric fields only. Failure to write diagnostics must not replace
    # the helper's original exit/interrupt or prevent request processing.
    payload = {"schema": 1, "eventCode": event, "reasonCode": reason,
               "startUptime": started, "deadlineUptime": deadline,
               "effectiveLifetimeSeconds": lifetime, "observedUptime": observed,
               "elapsedSeconds": max(0, observed - started)}
    try:
        print("SimulatorCaptureLifecycle " + json.dumps(payload, sort_keys=True), flush=True)
    except OSError:
        pass


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
    started = time.monotonic()
    lifetime = min(2400, arguments.lifetime)
    deadline = started + lifetime
    DEADLINE = deadline
    capture_lifecycle(0, 0, started, deadline, lifetime, started)
    reason = 2  # Uncaught Python exception; default signal behavior is unchanged.
    try:
        target = None
        next_lookup = 0.0
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
        reason = 1  # The existing loop reached its deadline.
        return 0
    except KeyboardInterrupt:
        reason = 3
        raise
    finally:
        capture_lifecycle(1, reason, started, deadline, lifetime, time.monotonic())


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(0)
