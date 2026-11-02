#!/usr/bin/env python3
"""Verify the complete native case profile and five distinct process witnesses."""
import argparse
import json
from pathlib import Path
import re
import runpy
import uuid

HD = "OfflineTikTokPlayerTests.PictureRecoveryTests/testFullResolutionProductionPlaybackKeepsVideoAndAudioMoving"
ACTIVATED = "OfflineTikTokPlayerTests.PictureRecoveryTests/testFullResolutionProductionPlaybackWithExplicitSessionActivation"
BENCHMARK = "OfflineTikTokPlayerTests.PlaybackSelectionVideoRegressionTests/testSourceCallbackExecutionTimingOffThenOn"
LEAD = "OfflineTikTokPlayerTests.VideoPresentationContinuityTests/testNativeClockLeadInsideDriftToleranceStillProducesDisplayableFrames"
MAIN_HOST_METHODS = frozenset({
    "testInitialZeroClockBindingExplicitSeekDuringReadyAcceptanceWithFirstCopiedPixelTrace",
    "testMutedNativeTimingPreservesRetainedVideoAndPCM",
    "testNativeTimingConfigurationCannotUndoPauseOrDeniedInterruptionResume",
    "testNativeTimingConfigurationRejectsSupersessionAtEveryPrewriteRead",
    "testPreparedNextVideoFirstFrameCapabilityBeforeSelection",
})
PHASE_FILES = {"main28": "native.log", "native-lead": "native-lead.log", "benchmark": "benchmark.log",
               "hd-fresh-1": "hd-fresh-1.log", "hd-fresh-2": "hd-fresh-2.log"}
AQ_SPLIT_HOST = re.compile(
    r'(NativeRuntimeHost \{.{0,2048}"testName":"-\[(?:PlaybackSelectionVideoRegressionTests|VideoPresentationContinuityTests) test[A-Za-z0-9_]*)'
    r'\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+\+\d{4} OfflineTikTokPlayer\[([1-9][0-9]*):[0-9]+\] '
    r'\[AQ\] {8}LoudnessManager\.mm:1215  IsHardwareSupported: no plist loaded, returning false')
AQ_TRAILING_HOST = re.compile(
    r'(NativeRuntimeHost \{.{1,3072}\})'
    r'\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+\+\d{4} OfflineTikTokPlayer\[([1-9][0-9]*):[0-9]+\] '
    r'\[AQ\] {8}LoudnessManager\.mm:1215  IsHardwareSupported: no plist loaded, returning false')
AQ_PID_HOST = re.compile(
    r'\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+\+\d{4} OfflineTikTokPlayer\[([1-9][0-9]{0,8})'
    r'(NativeRuntimeHost \{.{1,3072}\})([0-9]{1,9}):[0-9]+\] '
    r'\[AQ\] {8}LoudnessManager\.mm:1215  IsHardwareSupported: no plist loaded, returning false')


def native_host_rows(lines):
    """Join only the observed adjacent AQ diagnostic split inside a test name."""
    rows = []
    for index, line in enumerate(lines):
        if "NativeRuntimeHost " not in line:
            continue
        embedded = AQ_PID_HOST.fullmatch(line)
        if embedded:
            row = json.loads(embedded[2].removeprefix("NativeRuntimeHost "))
            assert str(row["pid"]) == embedded[1] + embedded[3]
            rows.append(row)
            continue
        assert line.startswith("NativeRuntimeHost ") and len(line) <= 4096
        try:
            row = json.loads(line.removeprefix("NativeRuntimeHost "))
        except json.JSONDecodeError:
            trailing = AQ_TRAILING_HOST.fullmatch(line)
            if trailing:
                row = json.loads(trailing[1].removeprefix("NativeRuntimeHost "))
                assert str(row["pid"]) == trailing[2]
                rows.append(row)
                continue
            split = AQ_SPLIT_HOST.fullmatch(line)
            assert split and index + 1 < len(lines), line
            tail = lines[index + 1]
            assert re.fullmatch(r'[A-Za-z0-9_]{1,200}\]"\}', tail), tail
            row = json.loads((split[1] + tail).removeprefix("NativeRuntimeHost "))
            assert str(row["pid"]) == split[2]
        rows.append(row)
    return rows


def canonical_uuid(value):
    parsed = uuid.UUID(value)
    assert parsed.int and str(parsed) == value.lower(), value
    return str(parsed)


def phase_cases(root):
    verifier = runpy.run_path(str(root / "scripts/verify-native-test-log.py"))
    profile = json.loads((root / "tests/native-video-format-cases.json").read_text())["cases"]
    cases = set(profile)
    assert len(profile) == len(cases) == 31 and cases <= verifier["source_manifest"](root)
    assert {HD, BENCHMARK, LEAD} <= cases and ACTIVATED not in cases
    groups = {"main28": cases - {HD, BENCHMARK, LEAD}, "native-lead": {LEAD}, "benchmark": {BENCHMARK},
              "hd-fresh-1": {HD}, "hd-fresh-2": {ACTIVATED}}
    assert [len(group) for group in groups.values()] == [28, 1, 1, 1, 1]
    assert set.union(*groups.values()) == cases | {ACTIVATED}
    return verifier, groups


def inspect_profile(root, texts, simulator, *, diagnose=False):
    simulator = canonical_uuid(simulator)
    verifier, groups = phase_cases(root)
    assert set(texts) == set(groups)
    results, hosts = {}, []
    for name, cases in groups.items():
        text = texts[name]
        assert "Restarting after unexpected exit, crash, or test timeout" not in text, (name, "XCTest host restarted")
        try:
            verifier["verify_log"](text, cases, invocation="test-without-building")
            results[name] = {"passed": True, "cases": len(cases)}
        except verifier["EvidenceError"] as error:
            results[name] = {"passed": False, "cases": len(cases), "reason": str(error)[:3000]}
        clean = [re.sub(r"^\d{4}-\d\d-\d\dT\S+Z ", "", line) for line in text.splitlines()]
        native = native_host_rows(clean)
        hd = [line for line in clean if "PRODUCTION_HD_HOST " in line]
        if name in ("main28", "native-lead", "benchmark"):
            assert not hd, (name, hd)
            methods = MAIN_HOST_METHODS if name == "main28" else {(LEAD if name == "native-lead" else BENCHMARK).split("/")[1]}
            host_class = "VideoPresentationContinuityTests" if name == "native-lead" else "PlaybackSelectionVideoRegressionTests"
            assert len(native) == len(methods), (name, native)
            witnesses, observed = set(), set()
            for row in native:
                assert set(row) == {"schema", "bundleIdentifier", "pid", "simulatorUDID", "moduleNonce", "testName"}
                assert row["schema"] == 1 and row["bundleIdentifier"] == "dev.galaxybigbird.OfflineTikTokPlayer"
                assert type(row["pid"]) is int and row["pid"] > 0
                assert canonical_uuid(row["simulatorUDID"]) == simulator
                method = re.fullmatch(r"-\[" + host_class + r" (test[A-Za-z0-9_]+)\]", row["testName"])
                assert method and method[1] in methods and method[1] not in observed
                observed.add(method[1])
                witnesses.add((row["pid"], canonical_uuid(row["moduleNonce"])))
            assert observed == methods and len(witnesses) == 1, (name, observed, witnesses)
            hosts.append(next(iter(witnesses)))
        else:
            assert not native and len(hd) == 1, (name, native, hd)
            row = re.fullmatch(r"PRODUCTION_HD_HOST schema=1 processID=([1-9][0-9]*) moduleNonce=([0-9a-f-]{36}) explicitActivation=(true|false)", hd[0])
            assert row and row[3] == ("true" if name == "hd-fresh-2" else "false"), (name, hd)
            hosts.append((int(row[1]), canonical_uuid(row[2])))
    assert len({pid for pid, _ in hosts}) == len({nonce for _, nonce in hosts}) == 5, hosts
    report = {"phases": results, "distinctHosts": 5, "requiredUniqueCases": 31,
              "executions": 32, "activationModes": [False, True],
              "allPassed": all(row["passed"] for row in results.values())}
    if not diagnose:
        assert report["allPassed"], report
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--folder", type=Path, required=True)
    parser.add_argument("--simulator", required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    texts = {role: (args.folder / file).read_text() for role, file in PHASE_FILES.items()}
    report = inspect_profile(root, texts, args.simulator)
    (args.folder / "verified-profile.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))
