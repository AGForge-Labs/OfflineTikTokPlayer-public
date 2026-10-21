#!/usr/bin/env python3
"""Bounded exact-device preflight; no test, app, reset or process-management action."""
import json
import re
import subprocess
import sys
import tempfile
import time
import uuid


BUDGET_SECONDS = 240
MAX_QUERY_BYTES = 262144
STATES = {"Booted": 1, "Shutdown": 2}


class PreflightError(Exception):
    def __init__(self, code):
        self.code = code


def canonical_uuid(value):
    if not isinstance(value, str) or not re.fullmatch(
            r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", value):
        raise PreflightError(1)
    parsed = uuid.UUID(value)
    if parsed.int == 0:
        raise PreflightError(1)
    return str(parsed).upper()


def prepare_simulator(identifier, *, run=subprocess.run, monotonic=time.monotonic):
    """Return fixed numeric/boolean evidence; raw native output never escapes."""
    started = monotonic()
    deadline = started + BUDGET_SECONDS
    result = {"schema": 1, "statusCode": 0, "stageCode": 1, "budgetSeconds": BUDGET_SECONDS,
              "initialStateCode": 0, "finalStateCode": 0, "identityChecksPassed": 0,
              "bootRequested": False, "bootReturnCode": -1, "waitReturnCode": -1,
              "lastQueryReturnCode": -1, "queryCount": 0, "elapsedMs": 0}

    def command(arguments, *, stdout=subprocess.DEVNULL, maximum=None):
        remaining = deadline - monotonic()
        if remaining <= 0:
            raise PreflightError(10)
        completed = run(["xcrun", "simctl", *arguments], stdout=stdout,
                        stderr=subprocess.DEVNULL, check=False,
                        timeout=min(remaining, maximum) if maximum is not None else remaining)
        if monotonic() >= deadline:
            raise PreflightError(10)
        return completed.returncode

    def query(wanted):
        result["queryCount"] += 1
        result["lastQueryReturnCode"] = -1
        # A temporary stream avoids unbounded Python PIPE accumulation. It is
        # closed on every path; only a bounded query read is parsed or retained.
        with tempfile.TemporaryFile() as stream:
            code = command(["list", "devices", "--json"], stdout=stream, maximum=60)
            result["lastQueryReturnCode"] = code
            if code:
                raise PreflightError(2)
            stream.seek(0)
            raw = stream.read(MAX_QUERY_BYTES + 1)
        if len(raw) > MAX_QUERY_BYTES:
            raise PreflightError(3)
        try:
            payload = json.loads(raw)
        except (ValueError, UnicodeError, RecursionError):
            raise PreflightError(3) from None
        groups = payload.get("devices") if isinstance(payload, dict) else None
        if not isinstance(groups, dict) or len(groups) > 64:
            raise PreflightError(3)
        matches, count = [], 0
        for runtime, devices in groups.items():
            if not isinstance(devices, list):
                raise PreflightError(3)
            count += len(devices)
            if count > 512:
                raise PreflightError(3)
            for device in devices:
                if not isinstance(device, dict) or not isinstance(device.get("udid"), str):
                    raise PreflightError(3)
                if device["udid"].upper() == wanted:
                    matches.append((runtime, device))
        if not matches:
            raise PreflightError(4)
        if len(matches) != 1:
            raise PreflightError(5)
        runtime, device = matches[0]
        if canonical_uuid(device["udid"]) != wanted:
            raise PreflightError(4)
        result["identityChecksPassed"] += 1
        if device.get("isAvailable") is not True:
            raise PreflightError(6)
        if not isinstance(runtime, str) or not re.fullmatch(
                r"com\.apple\.CoreSimulator\.SimRuntime\.iOS-\d+(?:-\d+)*", runtime):
            raise PreflightError(7)
        state_name = device.get("state")
        state = STATES.get(state_name, 0) if isinstance(state_name, str) else 0
        if state == 0:
            raise PreflightError(7)
        return state

    try:
        wanted = canonical_uuid(identifier)
        result["stageCode"] = 2
        result["initialStateCode"] = query(wanted)
        if result["initialStateCode"] == 2:
            result["stageCode"] = 3
            result["bootRequested"] = True
            result["bootReturnCode"] = command(["boot", wanted], maximum=30)
            if result["bootReturnCode"]:
                raise PreflightError(8)
        result["stageCode"] = 4
        result["waitReturnCode"] = command(["bootstatus", wanted, "-b"])
        if result["waitReturnCode"]:
            raise PreflightError(9)
        result["stageCode"] = 5
        result["finalStateCode"] = query(wanted)
        if result["finalStateCode"] != 1:
            raise PreflightError(7)
        if monotonic() >= deadline:
            raise PreflightError(10)
        result["stageCode"] = 6
    except PreflightError as failure:
        result["statusCode"] = failure.code
    except subprocess.TimeoutExpired:
        result["statusCode"] = 10
    except OSError:
        result["statusCode"] = 11
    finished = monotonic()
    if result["statusCode"] == 0 and finished >= deadline:
        result["statusCode"] = 10
        result["stageCode"] = 5
    result["elapsedMs"] = max(0, round((finished - started) * 1000))
    return result


def main(argv=None):
    arguments = sys.argv[1:] if argv is None else argv
    identifier = arguments[1] if len(arguments) == 2 and arguments[0] == "--udid" else None
    result = prepare_simulator(identifier)
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if result["statusCode"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
