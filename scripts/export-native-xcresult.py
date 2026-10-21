#!/usr/bin/env python3
"""Recover exact bounded JSON evidence; never decide native-test acceptance.

Exit codes: 0 export complete, 2 input/bundle, 3 child failure, 4 deadline,
5 byte limit, 6 JSON, 7 I/O or unexpected failure, 130 interruption.
The 2 MiB limit bounds accepted/read bytes, not transient temporary-file growth.
"""
import base64
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time


MODES = ("summary", "tests")
MAX_BYTES = 2 * 1024 * 1024
CHUNK_CHARACTERS = 1024
BUDGET_SECONDS = 120
COMMAND_SECONDS = 60
PREFIX = "NativeXCResultExport "


class ExportError(Exception):
    def __init__(self, code):
        self.code = code


def remaining(deadline, monotonic):
    value = deadline - monotonic()
    if value <= 0:
        raise ExportError(4)
    return value


def clear_outputs(outputs):
    failed = False
    for output in outputs:
        try:
            output.unlink(missing_ok=True)
        except OSError:
            failed = True
    if failed:
        raise ExportError(7)


def native_directory(repo_root):
    root = Path(repo_root).resolve(strict=True)
    native = root / "artifacts" / "native"
    if not root.is_dir() or not native.is_dir() or native.is_symlink():
        raise ExportError(2)
    if native.resolve(strict=True) != native:
        raise ExportError(2)
    return native


def exact_bundle(native):
    candidates = [path for path in native.iterdir()
                  if path.name.lower().endswith(".xcresult")]
    if len(candidates) != 1:
        raise ExportError(2)
    bundle = candidates[0]
    match = re.fullmatch(r"Tests-([0-9]{8}-[0-9]{6})\.xcresult", bundle.name)
    if match is None or bundle.is_symlink() or not bundle.is_dir():
        raise ExportError(2)
    try:
        datetime.strptime(match.group(1), "%Y%m%d-%H%M%S")
    except ValueError:
        raise ExportError(2) from None
    if bundle.resolve(strict=True) != bundle:
        raise ExportError(2)
    return bundle


def reject_constant(value):
    raise ValueError("non-JSON constant")


def extract(mode, bundle, native, deadline, run, monotonic):
    started = monotonic()
    timeout = min(COMMAND_SECONDS, remaining(deadline, monotonic))
    # Never accumulate native stdout in a PIPE or expose native stderr. The
    # temporary stream is closed on every path; only MAX_BYTES + 1 are read.
    with tempfile.TemporaryFile(mode="w+b", dir=native) as stream:
        completed = run(["xcrun", "xcresulttool", "get", "test-results", mode,
                         "--path", str(bundle)],
                        stdin=subprocess.DEVNULL, stdout=stream,
                        stderr=subprocess.DEVNULL, shell=False,
                        timeout=timeout, check=False)
        finished = monotonic()
        remaining(deadline, monotonic)
        if finished - started >= COMMAND_SECONDS or finished - started >= timeout:
            raise ExportError(4)
        if completed.returncode != 0:
            raise ExportError(3)
        stream.seek(0, 2)
        if stream.tell() > MAX_BYTES:
            raise ExportError(5)
        stream.seek(0)
        raw = stream.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        raise ExportError(5)
    try:
        decoded = json.loads(raw.decode("utf-8"), parse_constant=reject_constant)
    except (ValueError, UnicodeError, RecursionError):
        raise ExportError(6) from None
    if not isinstance(decoded, (dict, list)):
        raise ExportError(6)
    remaining(deadline, monotonic)
    return raw, max(0, int((finished - started) * 1000))


def records_for(mode, bundle, raw, elapsed_ms):
    encoded = base64.b64encode(raw).decode("ascii")
    chunks = [encoded[index:index + CHUNK_CHARACTERS]
              for index in range(0, len(encoded), CHUNK_CHARACTERS)]
    common = {"schema": 1, "mode": mode, "testAcceptance": False}
    records = [dict(common, event="metadata", bundle=bundle.name,
                    bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest(),
                    chunks=len(chunks), childReturnCode=0,
                    elapsedMilliseconds=elapsed_ms)]
    records.extend(dict(common, event="chunk", index=index, base64=chunk)
                   for index, chunk in enumerate(chunks))
    return records


def export(repo_root, *, run, monotonic, stdout):
    deadline = monotonic() + BUDGET_SECONDS
    native = native_directory(repo_root)
    outputs = [native / f"xcresult-{mode}.json" for mode in MODES]
    complete = False
    try:
        # Clear both fixed names before discovery or any extraction attempt.
        clear_outputs(outputs)
        remaining(deadline, monotonic)
        bundle = exact_bundle(native)
        payloads, records = [], []
        for mode in MODES:
            raw, elapsed_ms = extract(mode, bundle, native, deadline, run, monotonic)
            payloads.append(raw)
            records.extend(records_for(mode, bundle, raw, elapsed_ms))
            remaining(deadline, monotonic)
        # Neither fixed output appears until both child results are validated.
        for output, raw in zip(outputs, payloads):
            remaining(deadline, monotonic)
            output.write_bytes(raw)
        remaining(deadline, monotonic)
        for record in records:
            remaining(deadline, monotonic)
            print(PREFIX + json.dumps(record, separators=(",", ":")),
                  file=stdout, flush=True)
        remaining(deadline, monotonic)
        complete = True
    finally:
        if not complete:
            clear_outputs(outputs)


def main(argv=None, *, run=subprocess.run, monotonic=time.monotonic,
         stdout=None, stderr=None):
    argv = sys.argv[1:] if argv is None else argv
    stdout = sys.stdout if stdout is None else stdout
    stderr = sys.stderr if stderr is None else stderr
    code = 0
    try:
        if not argv:
            root = Path(__file__).resolve().parents[1]
        elif len(argv) == 2 and argv[0] == "--repo-root":
            root = Path(argv[1])
        else:
            raise ExportError(2)
        export(root, run=run, monotonic=monotonic, stdout=stdout)
    except ExportError as failure:
        code = failure.code
    except subprocess.TimeoutExpired:
        code = 4
    except KeyboardInterrupt:
        code = 130
    except Exception:
        code = 7
    if code:
        print(code, file=stderr)
    return code


if __name__ == "__main__":
    raise SystemExit(main())
