#!/usr/bin/env python3
"""Export bounded structured evidence from each exact isolated command, never acceptance."""
from datetime import datetime
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import time

SPEC = importlib.util.spec_from_file_location("bounded_export", Path(__file__).with_name("export-native-xcresult.py"))
BOUNDED = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BOUNDED)
PREFIX = "NativeControlXCResultExport "
EXPECTED = frozenset(range(5))  # Calibration=0, four fresh-process playback arms=1...4.


def discover(native):
    candidates = [path for path in native.iterdir() if path.name.lower().endswith(".xcresult")]
    if not 1 <= len(candidates) <= 6:
        raise BOUNDED.ExportError(2)
    found = {}
    for path in candidates:
        if path.is_symlink() or not path.is_dir() or path.resolve(strict=True) != path:
            raise BOUNDED.ExportError(2)
        match = re.fullmatch(r"Targeted-(build|benchmark|control-([1-4]))-([0-9]{8}-[0-9]{6})\.xcresult", path.name)
        if match is None:
            raise BOUNDED.ExportError(2)
        try:
            datetime.strptime(match.group(3), "%Y%m%d-%H%M%S")
        except ValueError:
            raise BOUNDED.ExportError(2) from None
        ordinal = -1 if match.group(1) == "build" else (0 if match.group(1) == "benchmark" else int(match.group(2)))
        if ordinal in found:
            raise BOUNDED.ExportError(2)
        found[ordinal] = path
    return {ordinal: path for ordinal, path in sorted(found.items()) if ordinal in EXPECTED}


def export(root, *, run=subprocess.run, monotonic=time.monotonic, stdout=None):
    stdout = sys.stdout if stdout is None else stdout
    native = BOUNDED.native_directory(root)
    outputs = {(ordinal, mode): native / ("control-%02d-xcresult-%s.json" % (ordinal, mode))
               for ordinal in EXPECTED for mode in BOUNDED.MODES}
    BOUNDED.clear_outputs(outputs.values())
    bundles = discover(native)
    completed = []
    errors = []
    for ordinal, bundle in bundles.items():
        deadline = monotonic() + BOUNDED.BUDGET_SECONDS
        try:
            payloads = [(mode, *BOUNDED.extract(mode, bundle, native, deadline, run, monotonic))
                        for mode in BOUNDED.MODES]
            records = [dict(record, ordinal=ordinal) for mode, raw, elapsed in payloads
                       for record in BOUNDED.records_for(mode, bundle, raw, elapsed)]
            for mode, raw, _elapsed in payloads:
                BOUNDED.remaining(deadline, monotonic)
                outputs[ordinal, mode].write_bytes(raw)
            for record in records:
                BOUNDED.remaining(deadline, monotonic)
                print(PREFIX + json.dumps(record, separators=(",", ":")), file=stdout, flush=True)
            BOUNDED.remaining(deadline, monotonic)
            completed.append(ordinal)
        except (BOUNDED.ExportError, subprocess.TimeoutExpired, OSError) as error:
            BOUNDED.clear_outputs([outputs[ordinal, mode] for mode in BOUNDED.MODES])
            errors.append(dict(ordinal=ordinal, code=error.code if isinstance(error, BOUNDED.ExportError)
                               else (4 if isinstance(error, subprocess.TimeoutExpired) else 7)))
    complete = set(completed) == EXPECTED and not errors
    print("NativeControlXCResultCensus " + json.dumps(dict(schema=1, attempted=sorted(bundles),
          completed=completed, missing=sorted(EXPECTED - set(bundles)), errors=errors,
          expected=sorted(EXPECTED), complete=complete, testAcceptance=False), separators=(",", ":")),
          file=stdout, flush=True)
    return 0 if complete else 2


def main():
    try:
        return export(Path.cwd())
    except (BOUNDED.ExportError, OSError, ValueError):
        print("Native isolated structured export failed input validation", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
