"""Bounded post-attempt crash evidence. Diagnostic only; main always returns zero.

Run only AFTER a successful existing summary/tests export, with --export-succeeded.
No native test launch/retry, production change, upload, credential or Atos operation.
Native acceptance is decided by the original launcher and strict verifier.
The deadline is a checked work budget; filesystem and output calls are not interruptible.
"""

import argparse
from datetime import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from uuid import UUID

HELP_BYTES = 8 * 1024
METADATA_BYTES = 20 * 1024
EXPORT_BYTES = 8 * 1024 * 1024
LOG_BYTES = 32 * 1024 * 1024
JSON_BYTES = 2 * 1024 * 1024
ENTRY_LIMIT, DEPTH_LIMIT, IPS_LIMIT = 64, 4, 32
COLLECT_SECONDS, HELP_SECONDS, CHILD_SECONDS = 60, 20, 20
CASE_NAMES = {
    "PlaybackSelectionVideoRegressionTests/testPreparedNextVideoPrerollCapabilityOffThenOn()":
        "-[PlaybackSelectionVideoRegressionTests testPreparedNextVideoPrerollCapabilityOffThenOn]",
    "PlaybackSelectionVideoRegressionTests/testPreparedNextVideoPrerollCapabilityOnThenOff()":
        "-[PlaybackSelectionVideoRegressionTests testPreparedNextVideoPrerollCapabilityOnThenOff]",
}


class Unavailable(Exception):
    def __init__(self, reason):
        self.reason = reason


def _json(raw):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise Unavailable("duplicate-json-key")
            result[key] = value
        return result

    def constant(_):
        raise Unavailable("non-json-constant")

    try:
        return json.loads(raw.decode("utf-8"), object_pairs_hook=unique, parse_constant=constant)
    except (UnicodeError, ValueError, RecursionError, OverflowError):
        raise Unavailable("invalid-json") from None


def _encode(value):
    return (json.dumps(value, ensure_ascii=False, allow_nan=False,
                       sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def _case_unavailable(case_id, reason):
    return _encode({"schema": 1, "testAcceptance": False, "caseID": case_id,
                    "availability": "unavailable", "attributionAvailability": "unavailable",
                    "reason": reason, "truncated": False})


class Output:
    def __init__(self, stream):
        self.stream = stream
        self.metadata_used = 0

    def write(self, raw):
        if self.stream.write(raw) != len(raw):
            raise OSError("short diagnostic write")

    def metadata(self, event, **fields):
        raw = _encode(dict(schema=1, testAcceptance=False, event=event, **fields))
        if self.metadata_used + len(raw) > METADATA_BYTES:
            raise Unavailable("metadata-size")
        self.metadata_used += len(raw)
        self.write(raw)

    def cases(self, records):
        if len(records) != 2 or sum(map(len, records)) > 128 * 1024:
            raise Unavailable("case-output-size")
        for case_id, raw in zip(CASE_NAMES, records):
            if type(raw) is not bytes or len(raw) > 64 * 1024:
                raise Unavailable("case-output-size")
            value = _json(raw)
            if (type(value) is not dict or value.get("caseID") != case_id
                    or value.get("testAcceptance") is not False):
                raise Unavailable("case-output-shape")
        for raw in records:
            self.write(raw)


def _canonical_uuid(value, upper=False):
    if type(value) is not str:
        raise Unavailable("invalid-host-binding")
    try:
        canonical = str(UUID(value))
    except (ValueError, AttributeError):
        raise Unavailable("invalid-host-binding") from None
    if value.lower() != canonical:
        raise Unavailable("invalid-host-binding")
    return canonical.upper() if upper else canonical


def _flags():
    if not hasattr(os, "O_NOFOLLOW") or not hasattr(os, "O_DIRECTORY"):
        raise Unavailable("safe-open-unavailable")
    return os.O_RDONLY | os.O_NOFOLLOW, os.O_RDONLY | os.O_NOFOLLOW | os.O_DIRECTORY


def _read_fixed(path, parent, limit):
    file_flags, _ = _flags()
    if path.parent != parent or path.is_symlink() or path.resolve(strict=True) != path:
        raise Unavailable("noncanonical-input")
    descriptor = os.open(path, file_flags)
    with os.fdopen(descriptor, "rb") as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_size > limit:
            raise Unavailable("input-size")
        raw = stream.read(limit + 1)
        after = os.fstat(stream.fileno())
        if (len(raw) > limit or len(raw) != before.st_size
                or (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
                != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)):
            raise Unavailable("input-mutated")
    return raw


def _load(name, path, parent):
    _read_fixed(path, parent, 128 * 1024)  # Canonical nonsymlink reviewed source only.
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise Unavailable("support-import")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # Required by dataclasses during module execution.
    spec.loader.exec_module(module)
    return module


def _nodes(tests, expected_udid):
    if type(tests) is not dict or type(tests.get("testNodes")) is not list:
        raise Unavailable("unsupported-tests-shape")
    devices = tests.get("devices")
    if (type(devices) is not list or len(devices) != 1 or type(devices[0]) is not dict
            or devices[0].get("platform") != "iOS Simulator"
            or _canonical_uuid(devices[0].get("deviceId"), upper=True) != expected_udid):
        raise Unavailable("tests-destination-mismatch")
    found = {}
    stack = [(item, 0) for item in tests["testNodes"]]
    visited = 0
    while stack:
        node, depth = stack.pop()
        visited += 1
        if visited > 8192 or depth > 64 or type(node) is not dict:
            raise Unavailable("tests-tree-limit")
        identifier = node.get("nodeIdentifier")
        if identifier in CASE_NAMES:
            if (identifier in found or node.get("nodeType") != "Test Case"
                    or node.get("name") != identifier.split("/", 1)[1]):
                raise Unavailable("ambiguous-test-case")
            found[identifier] = node
        children = node.get("children", [])
        if type(children) is not list:
            raise Unavailable("unsupported-tests-shape")
        stack.extend((child, depth + 1) for child in children)
    if set(found) != set(CASE_NAMES):
        raise Unavailable("missing-test-case")
    return found


def _known_aq_duplicate(payload, validated):
    # Only the first fully validated payload per allowlisted case is eligible.
    # No JSON prefix is decoded or accepted as a new binding.
    for original, pid, source_line in validated.values():
        if not payload.startswith(original):
            continue
        suffix = payload[len(original):]
        match = re.fullmatch(
            rb"(?P<stamp>[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}"
            rb"\.[0-9]{6}\+0000) OfflineTikTokPlayer\[(?P<pid>[1-9][0-9]{0,19}):"
            rb"(?P<tid>[1-9][0-9]{0,19})\] \[AQ\] {8}LoudnessManager\.mm:1215 {2}"
            rb"IsHardwareSupported: no plist loaded, returning false", suffix)
        if match is None or int(match["pid"]) != pid or int(match["tid"]) > (1 << 64) - 1:
            continue
        try:
            datetime.strptime(match["stamp"].decode("ascii"), "%Y-%m-%d %H:%M:%S.%f%z")
        except ValueError:
            continue
        return source_line
    return None


def _input_failure(output, stage, raw, failure, native_log_line=None):
    if output is not None:
        output.metadata("collection-input-failure", stage=stage, reason=failure.reason,
                        inputBytes=len(raw), inputSHA256=hashlib.sha256(raw).hexdigest(),
                        nativeLogLine=native_log_line)


def _bindings(log, expected_udid, parser, output=None):
    expected = {value: key for key, value in CASE_NAMES.items()}
    seen = {key: [] for key in CASE_NAMES}
    host_count = 0
    validated = {}  # At most two exact first payloads, each already bounded to 8192 bytes.
    recovered = 0
    first_recovery = None
    for line_number, line in enumerate(log.splitlines(), 1):
        if not line.startswith(b"NativeRuntimeHost "):
            continue
        host_count += 1
        if host_count > 1024 or len(line) > 8192:
            raise Unavailable("host-receipt-limit")
        payload = line[len(b"NativeRuntimeHost "):]
        try:
            record = _json(payload)
        except Unavailable as failure:
            source_line = (_known_aq_duplicate(payload, validated)
                           if failure.reason == "invalid-json" else None)
            if source_line is not None:
                recovered += 1
                if first_recovery is None:
                    first_recovery = (line_number, source_line, hashlib.sha256(payload).hexdigest())
                continue  # This duplicate contributes no binding or attribution facts.
            _input_failure(output, "native-host-receipt-json", payload, failure, line_number)
            raise
        if type(record) is not dict:
            raise Unavailable("host-receipt-shape")
        name = record.get("testName")
        if name not in expected:
            continue
        case_id = expected[name]
        required = {"schema", "testName", "pid", "bundleIdentifier", "simulatorUDID",
                    "moduleNonce", "caseStartUTC"}
        if set(record) != required or type(record["schema"]) is not int or record["schema"] != 1:
            raise Unavailable("host-receipt-shape")
        if (record["bundleIdentifier"] != parser.BUNDLE_ID
                or _canonical_uuid(record["simulatorUDID"], upper=True) != expected_udid
                or type(record["pid"]) is not int or record["pid"] <= 0
                or type(record["caseStartUTC"]) is not str
                or not re.search(r"(?:Z|\+00:?00)\Z", record["caseStartUTC"])):
            raise Unavailable("host-binding-mismatch")
        nonce = _canonical_uuid(record["moduleNonce"])
        if nonce != record["moduleNonce"]:
            raise Unavailable("host-binding-mismatch")
        try:
            start = parser._utc(record["caseStartUTC"])
            binding = parser.CaseBinding(case_id, record["pid"], nonce, start)
            parser._binding_base(binding)
        except parser._Problem:
            raise Unavailable("host-start-unavailable") from None
        # No adjacent case/log timestamps are consulted. Repeated arm receipts must agree.
        identity = (binding.pid, binding.module_nonce, binding.case_start_utc)
        if seen[case_id] and seen[case_id][0][0] != identity:
            raise Unavailable("inconsistent-host-binding")
        seen[case_id].append((identity, binding))
        validated.setdefault(case_id, (payload, record["pid"], line_number))
    if recovered and output is not None:
        output.metadata("host-receipt-recovery", count=recovered,
                        rule="exact-prior-payload-plus-same-pid-known-aq",
                        firstNativeLogLine=first_recovery[0],
                        priorNativeLogLine=first_recovery[1], firstInputSHA256=first_recovery[2])
    return {case_id: values[0][1] for case_id, values in seen.items() if values}


def _scan(case_roots, ips_bytes, read=False):
    """FD-relative nonsymlink walk; raw filenames and unrelated file content never escape."""
    file_flags, directory_flags = _flags()
    totals = {"bytes": 0, "entries": 0, "ips": 0,
              "fileTypes": {"ips": 0, "crash": 0, "json": 0, "txt": 0, "other": 0}}
    records = {case_id: [] for case_id, _, _ in case_roots}

    def walk(descriptor, path, root, case_id, depth):
        with os.scandir(descriptor) as entries:
            for entry in entries:
                totals["entries"] += 1
                if totals["entries"] > ENTRY_LIMIT:
                    raise Unavailable("export-entry-limit")
                info = entry.stat(follow_symlinks=False)
                item = path / entry.name
                if stat.S_ISLNK(info.st_mode):
                    raise Unavailable("export-symlink")
                if item.resolve(strict=True) != item or not item.is_relative_to(root):
                    raise Unavailable("export-noncanonical")
                if stat.S_ISDIR(info.st_mode):
                    if depth >= DEPTH_LIMIT:
                        raise Unavailable("export-depth-limit")
                    child = os.open(entry.name, directory_flags, dir_fd=descriptor)
                    try:
                        actual = os.fstat(child)
                        if (info.st_dev, info.st_ino) != (actual.st_dev, actual.st_ino):
                            raise Unavailable("export-mutated")
                        walk(child, item, root, case_id, depth + 1)
                    finally:
                        os.close(child)
                elif stat.S_ISREG(info.st_mode):
                    suffix = item.suffix.lower().removeprefix(".")
                    totals["fileTypes"][suffix if suffix in totals["fileTypes"] else "other"] += 1
                    totals["bytes"] += info.st_size
                    if totals["bytes"] > EXPORT_BYTES:
                        raise Unavailable("export-byte-limit")
                    if item.suffix != ".ips":
                        continue
                    totals["ips"] += 1
                    if totals["ips"] > IPS_LIMIT or info.st_size > ips_bytes:
                        raise Unavailable("ips-file-limit")
                    if not read:
                        continue
                    child = os.open(entry.name, file_flags, dir_fd=descriptor)
                    with os.fdopen(child, "rb") as stream:
                        before = os.fstat(stream.fileno())
                        if (not stat.S_ISREG(before.st_mode)
                                or (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)
                                != (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)):
                            raise Unavailable("export-mutated")
                        raw = stream.read(ips_bytes + 1)
                        after = os.fstat(stream.fileno())
                        if (len(raw) > ips_bytes or len(raw) != before.st_size
                                or (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
                                != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)):
                            raise Unavailable("export-mutated")
                    records[case_id].append(raw)
                else:
                    raise Unavailable("export-special-file")

    for case_id, root, identity in case_roots:
        if root.is_symlink() or root.resolve(strict=True) != root:
            raise Unavailable("export-root-mutated")
        descriptor = os.open(root, directory_flags)
        try:
            current = os.fstat(descriptor)
            if (current.st_dev, current.st_ino) != identity:
                raise Unavailable("export-root-mutated")
            walk(descriptor, root, root, case_id, 0)
        finally:
            os.close(descriptor)
    return records, totals


def _group_exists(pid):
    try:
        os.killpg(pid, 0)
        return True
    except ProcessLookupError:
        return False


def _reap_owned_group(child, monotonic):
    """Only the new-session group created for this collector child; <=1s cleanup."""
    for sent_signal in (signal.SIGTERM, signal.SIGKILL):
        child.poll()
        if not _group_exists(child.pid):
            child.wait(timeout=0.1)
            return True
        try:
            os.killpg(child.pid, sent_signal)
        except ProcessLookupError:
            pass
        deadline = monotonic() + 0.5
        while monotonic() < deadline:
            child.poll()
            if not _group_exists(child.pid):
                child.wait(timeout=0.1)
                return True
            time.sleep(0.01)
    return child.poll() is not None and not _group_exists(child.pid)


def _owned_child(argv, root, work, deadline, stdout_limit, case_roots, parser, owner,
                 monotonic=time.monotonic):
    child = None
    try:
        with tempfile.TemporaryFile(mode="w+b", dir=work) as capture:
            if monotonic() >= deadline:
                raise Unavailable("child-timeout")
            try:
                child = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=capture,
                                         stderr=subprocess.DEVNULL, cwd=root, shell=False,
                                         close_fds=True, start_new_session=True)
            except OSError:
                raise Unavailable("child-start-failed") from None
            owner["child"] = child
            try:
                while True:
                    if monotonic() >= deadline:
                        raise Unavailable("child-timeout")
                    if os.fstat(capture.fileno()).st_size > stdout_limit:
                        raise Unavailable("child-stdout-limit")
                    if case_roots:
                        _scan(case_roots, parser.MAX_IPS_BYTES)
                    code = child.poll()
                    if code is not None:
                        break
                    time.sleep(min(0.1, max(0, deadline - monotonic())))
                capture.seek(0)
                raw = capture.read(stdout_limit + 1)
                if len(raw) > stdout_limit:
                    raise Unavailable("child-stdout-limit")
                return code, raw
            finally:
                if not _reap_owned_group(child, monotonic):
                    owner["cleanup_ok"] = False
                    raise Unavailable("child-cleanup-unacknowledged")
                owner["child"] = None
    except (subprocess.TimeoutExpired, PermissionError):
        owner["cleanup_ok"] = False
        raise Unavailable("child-cleanup-unacknowledged") from None


def _advertises(text, command):
    return re.search(r"(?m)^\s*" + re.escape(command) + r"(?:\s|$)", text) is not None


def _discover_help(run_child, root, work, deadline, parser, owner, output, monotonic):
    help_deadline = min(deadline, monotonic() + HELP_SECONDS)
    responses = []
    for suffix in ((), ("export",), ("export", "attachments")):  # Three calls; never >4.
        if suffix == ("export",) and not _advertises(responses[-1], "export"):
            raise Unavailable("export-help-unavailable")
        if suffix == ("export", "attachments") and not _advertises(responses[-1], "attachments"):
            raise Unavailable("attachments-help-unavailable")
        code, raw = run_child(["xcrun", "xcresulttool", *suffix, "--help"], root, work,
                              min(help_deadline, monotonic() + 5), HELP_BYTES, (), parser,
                              owner, monotonic=monotonic)
        if code != 0:
            raise Unavailable("help-child-failed")
        if type(raw) is not bytes or len(raw) > HELP_BYTES:
            raise Unavailable("help-size")
        try:
            text = raw.decode("utf-8")
        except UnicodeError:
            raise Unavailable("help-encoding") from None
        if any(ord(character) < 32 and character not in "\r\n\t" for character in text):
            raise Unavailable("help-control")
        responses.append(text)
    if monotonic() >= help_deadline:
        raise Unavailable("help-deadline")
    text = responses[-1]
    output.metadata("active-attachment-help", stdout=text, stdoutBytes=len(raw),
                    stdoutSHA256=hashlib.sha256(raw).hexdigest(),
                    command="xcrun xcresulttool export attachments --help",
                    selectorCandidate="literal-returned-nodeIdentifier",
                    metadataBudgetBytes=METADATA_BYTES)
    for option in ("path", "output-path", "test-id"):
        if not re.search(r"(?m)^\s*--" + option + r"\s+<[^>\r\n]+>", text):
            raise Unavailable("unsupported-help-option")
    if not re.search(r"(?m)^\s*--only-failures(?:[ \t]+|$)", text):
        raise Unavailable("unsupported-help-option")
    if re.search(r"(?m)^\s*--only-failures\s+<", text):
        raise Unavailable("unsupported-help-option")
    option = re.search(r"(?ms)^\s*--test-id\s+<[^>\r\n]+>(.*?)(?=^\s*--|\Z)", text)
    if option is None or not re.search(
            r"(?i)(?:test(?:\s+case)?\s+identifier|identifier\s+(?:of|for)\s+(?:the\s+|a\s+)?test)",
            option[1]):
        raise Unavailable("selector-semantics-unavailable")
    return "literal-returned-nodeIdentifier"


def collect(root, expected_udid, export_succeeded, output, *, parser=None, exporter=None,
            run_child=_owned_child, monotonic=time.monotonic):
    deadline = monotonic() + COLLECT_SECONDS
    root = Path(root).resolve(strict=True)
    expected_udid = _canonical_uuid(expected_udid, upper=True)
    if export_succeeded is not True:
        raise Unavailable("structured-export-not-confirmed")
    _flags()
    parser = parser or _load("preroll_crash_excerpt",
                            root / "scripts" / "preroll-crash-excerpt.py", root / "scripts")
    exporter = exporter or _load("preroll_native_exporter",
                                root / "scripts" / "export-native-xcresult.py", root / "scripts")
    if tuple(parser.CASE_IDS) != tuple(CASE_NAMES):
        raise Unavailable("parser-case-scope")
    native = exporter.native_directory(root)
    bundle = exporter.exact_bundle(native)
    tests_raw = _read_fixed(native / "xcresult-tests.json", native, JSON_BYTES)
    native_log = _read_fixed(native / "xcodebuild-test.log", native, LOG_BYTES)
    try:
        tests_document = _json(tests_raw)
    except Unavailable as failure:
        _input_failure(output, "xcresult-tests-json", tests_raw, failure)
        raise
    tests = _nodes(tests_document, expected_udid)
    bindings = _bindings(native_log, expected_udid, parser, output=output)
    owner = {"child": None, "cleanup_ok": True}
    work = Path(tempfile.mkdtemp(prefix="preroll-crash-", dir=native)).resolve(strict=True)
    case_roots = []
    records = {}
    try:
        selector_semantics = _discover_help(run_child, root, work, deadline, parser, owner,
                                            output, monotonic)
        for ordinal, case_id in enumerate(CASE_NAMES):
            if monotonic() >= deadline:
                raise Unavailable("collection-deadline")
            if tests[case_id].get("result") != "Failed":
                records[case_id] = _case_unavailable(case_id, "case-not-failed")
                continue
            if case_id not in bindings:
                records[case_id] = _case_unavailable(case_id, "host-start-unavailable")
                continue
            case_dir = work / ("case-" + str(ordinal))
            case_dir.mkdir(mode=0o700)
            info = case_dir.stat()
            case_roots.append((case_id, case_dir, (info.st_dev, info.st_ino)))
            # Literal returned identifier, never nodeIdentifierURL or a transformed spelling.
            selector = tests[case_id]["nodeIdentifier"]
            code, _ = run_child(
                ["xcrun", "xcresulttool", "export", "attachments",
                 "--path", str(bundle), "--output-path", str(case_dir),
                 "--test-id", selector, "--only-failures"],
                root, work, min(deadline, monotonic() + CHILD_SECONDS), HELP_BYTES,
                tuple(case_roots), parser, owner, monotonic=monotonic)
            if code != 0:
                records[case_id] = _case_unavailable(case_id, "attachment-export-failed")
                continue
            inputs, _ = _scan(tuple(case_roots), parser.MAX_IPS_BYTES, read=True)
            records[case_id] = parser.parse_case_ips(
                inputs[case_id], bindings[case_id], case_scoped_export_confirmed=True)
        if exporter.exact_bundle(native) != bundle or monotonic() >= deadline:
            raise Unavailable("collection-mutated-or-deadline")
        _, totals = _scan(tuple(case_roots), parser.MAX_IPS_BYTES)
        output.metadata("collection-provenance", bundle=bundle.name,
                        testsSHA256=hashlib.sha256(tests_raw).hexdigest(),
                        nativeLogSHA256=hashlib.sha256(native_log).hexdigest(),
                        simulatorUDID=expected_udid, selectorSemantics=selector_semantics,
                        exportBytes=totals["bytes"], exportEntries=totals["entries"],
                        ipsCandidateFiles=totals["ips"], exportFileTypes=totals["fileTypes"],
                        byteCap=EXPORT_BYTES, instantaneousFilesystemQuota=False,
                        fullFilesEchoed=False, fullFilesUploaded=False)
        return [records[case_id] for case_id in CASE_NAMES]
    finally:
        # A child whose cleanup is unacknowledged retains ONLY this owned local workspace.
        if owner["cleanup_ok"] and owner["child"] is None:
            if work.parent != native or work.is_symlink() or work.resolve(strict=True) != work:
                raise Unavailable("cleanup-path")
            if not getattr(shutil.rmtree, "avoids_symlink_attacks", False):
                raise Unavailable("safe-cleanup-unavailable")
            shutil.rmtree(work)


class _Arguments(argparse.ArgumentParser):
    def error(self, _):
        raise Unavailable("arguments")


def main(argv=None, *, stream=None):
    stream = stream if stream is not None else sys.stdout.buffer
    output = Output(stream)
    try:
        arguments = _Arguments(description="Bounded post-attempt preroll crash evidence; never test acceptance.")
        arguments.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[1])
        arguments.add_argument("--simulator-udid", required=True)
        arguments.add_argument("--export-succeeded", action="store_true")
        options = arguments.parse_args(argv)
        if sys.platform != "darwin":
            raise Unavailable("mac-only")
        records = collect(options.repo_root, options.simulator_udid, options.export_succeeded, output)
    except Unavailable as failure:
        records = [_case_unavailable(case_id, failure.reason) for case_id in CASE_NAMES]
    except KeyboardInterrupt:
        records = [_case_unavailable(case_id, "interrupted") for case_id in CASE_NAMES]
    except Exception:
        records = [_case_unavailable(case_id, "collector-unavailable") for case_id in CASE_NAMES]
    try:
        output.cases(records)
    except Unavailable:
        try:
            output.cases([_case_unavailable(case_id, "case-output-unavailable") for case_id in CASE_NAMES])
        except Exception:
            pass
    except Exception:
        pass  # Never replace the original native exit/strict-verification outcome.
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
