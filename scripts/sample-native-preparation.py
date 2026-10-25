#!/usr/bin/env python3
"""One two-second stack sample of the exact synthetic XCTest host; no app launch."""
import argparse
import json
from pathlib import Path
import re
import signal
import subprocess
import time
import uuid

BUNDLE = "dev.galaxybigbird.OfflineTikTokPlayer"
METHOD = "testNaturalBoundaryAtPositiveIncomingOffsetRevealsB"
CASE = "-[PlaybackSelectionVideoRegressionTests " + METHOD + "]"
SOURCE = "9489d3b3ae85cb41b5ef4f56633dcf41b36505af"
FIELDS = {"schema", "bundleIdentifier", "moduleNonce", "pid", "simulatorUDID", "testName"}


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate field")
        result[key] = value
    return result


def parse_host(line, expected_udid):
    if not line.startswith("NativeRuntimeHost ") or len(line) > 4096:
        raise ValueError("invalid runtime header")
    host = json.loads(line[len("NativeRuntimeHost "):], object_pairs_hook=unique_object)
    if not isinstance(host, dict) or set(host) != FIELDS:
        raise ValueError("invalid runtime shape")
    if type(host["schema"]) is not int or host["schema"] != 1 or host["bundleIdentifier"] != BUNDLE or host["testName"] != CASE:
        raise ValueError("different runtime owner")
    if type(host["pid"]) is not int or not 2 <= host["pid"] < 10_000_000:
        raise ValueError("invalid process")
    if type(host["simulatorUDID"]) is not str or type(host["moduleNonce"]) is not str:
        raise ValueError("invalid runtime UUID type")
    if str(uuid.UUID(host["simulatorUDID"])).upper() != expected_udid.upper():
        raise ValueError("different simulator")
    if str(uuid.UUID(host["moduleNonce"])) != host["moduleNonce"].lower():
        raise ValueError("noncanonical module nonce")
    return host


def target_finished(text):
    return any("Test Case '-[" + name + " " + METHOD + "]' " + result in text
               for name in ["PlaybackSelectionVideoRegressionTests", "OfflineTikTokPlayerTests.PlaybackSelectionVideoRegressionTests"]
               for result in ["passed (", "failed ("])


def matches_executable(executable, app_container):
    try:
        app = Path(app_container).resolve(strict=True)
        actual = Path(executable).resolve(strict=True)
        expected = (app / "OfflineTikTokPlayer").resolve(strict=True)
        return app.name == "OfflineTikTokPlayer.app" and actual.is_file() and actual == expected
    except (OSError, ValueError):
        return False


def checked_output(arguments, timeout):
    reply = subprocess.run(arguments, capture_output=True, text=True, timeout=timeout, check=True)
    if len(reply.stdout) > 16384:
        raise ValueError("oversized attestation response")
    return reply.stdout.strip()


def cancelled(_number, _frame):
    # subprocess.run kills and waits for its own child when this interrupts it.
    raise InterruptedError("owned observation stopped")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    receipt = dict(schema=1, candidateSource=SOURCE, testName=CASE,
                   requestedSeconds=2, intervalMilliseconds=1, captured=False,
                   phaseQualified=False, startupCaptureProved=False, runtimeEventFreshnessUnproved=True,
                   acceptanceScope="one playback case plus required UI smoke; profiling observation; full80-case gate remains failed")
    status = 1
    try:
        signal.signal(signal.SIGTERM, cancelled)
        head = checked_output(["git", "-C", str(args.repo), "rev-parse", "HEAD"], 5)
        if head != SOURCE:
            raise ValueError("wrong compiled candidate source")
        expected_udid = str(uuid.UUID(args.udid)).upper()
        deadline = time.monotonic() + 300
        offset = 0
        pending = ""
        host = None
        while time.monotonic() < deadline:
            if args.log.exists():
                if args.log.is_symlink() or args.log.stat().st_size > 4 * 1024 * 1024:
                    raise ValueError("unbounded or redirected test log")
                with args.log.open("r", encoding="utf-8") as stream:
                    stream.seek(offset)
                    pending += stream.read()
                    offset = stream.tell()
                if target_finished(pending):
                    raise ValueError("target completed before startup observation")
                lines = pending.split("\n")
                pending = lines.pop()
                for line in lines:
                    if line.startswith("NativeRuntimeHost "):
                        host = parse_host(line.rstrip("\r"), expected_udid)
                        break
                if host is not None:
                    receipt["runtimeHeaderObservedMonotonic"] = time.monotonic()
                    break
                if len(pending) > 16384:
                    raise ValueError("unbounded partial header")
            time.sleep(0.025)
        if host is None:
            raise TimeoutError("no target runtime event")
        container = checked_output(["xcrun", "simctl", "get_app_container", expected_udid, BUNDLE, "app"], 5)
        executable = checked_output(["/bin/ps", "-p", str(host["pid"]), "-o", "comm="], 2)
        if not matches_executable(executable, container):
            raise ValueError("runtime executable mismatch")
        # Recheck after attestation: a buffered completed case is not startup proof.
        if target_finished(args.log.read_text(encoding="utf-8")):
            raise ValueError("target completed during attestation")
        receipt.update(pid=host["pid"], simulatorUDID=expected_udid, moduleNonce=host["moduleNonce"],
                       sourceAndExecutableAttested=True, observationEntryMonotonic=time.monotonic(),
                       phaseCaveat="RuntimeHost output may be buffered; a still-running case does not prove initial preparation remains active. Interpret only stacks actually observed.")
        destination = args.output / "native-case.sample.txt"
        subprocess.run(["/usr/bin/sample", str(host["pid"]), "2", "1", "-file", str(destination)],
                       capture_output=True, text=True, timeout=20, check=True)
        if destination.is_symlink() or not destination.is_file() or not 0 < destination.stat().st_size <= 8 * 1024 * 1024:
            raise ValueError("missing or oversized sample")
        text = destination.read_text(encoding="utf-8", errors="replace")
        names = sorted({name for name in ["PlaybackService", "ContinuousAudio", "ContinuousPCMDecoder", "ContinuousPictureInPicture"] if name in text})
        receipt.update(captured=True, bytes=destination.stat().st_size,
                       observationReturnMonotonic=time.monotonic(), firstPartyNamesObserved=names,
                       symbolsRequireManualInspection=True,
                       caveat="Sampling perturbs scheduling; absence of a blocked stack is inconclusive. No RT deadline or physical output proof.")
        status = 0
    except (OSError, ValueError, TimeoutError, subprocess.SubprocessError) as error:
        receipt.update(errorType=type(error).__name__, reason=str(error) if isinstance(error, (ValueError, TimeoutError)) else "native observation unavailable")
    finally:
        (args.output / "native-case.sample.receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print("PreparationStackObservation " + json.dumps(receipt, sort_keys=True), flush=True)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
