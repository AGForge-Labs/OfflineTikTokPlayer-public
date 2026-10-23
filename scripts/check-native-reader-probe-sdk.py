#!/usr/bin/env python3
"""Compile only the test probe against the selected public Simulator SDK first."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'ios/OfflineTikTokPlayerTests/NativeReaderWaitProbe.m'
STAGE = 'platform'


def resolve_sdk(value):
    candidate = Path(value.strip())
    if not candidate.is_absolute():
        raise ValueError('sdk-path-not-absolute')
    sdk = candidate.resolve(strict=True)
    # Xcode may resolve the versioned SDK alias to iPhoneSimulator.sdk.
    if not sdk.is_dir() or not re.fullmatch(r'iPhoneSimulator(?:[0-9.]+)?\.sdk', sdk.name):
        raise ValueError('sdk-path-not-simulator-directory')
    return sdk


def load_owned():
    spec = importlib.util.spec_from_file_location('owned_sdk', ROOT / 'scripts/run-owned-xcodebuild.py')
    owned = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(owned)
    return owned


def main():
    global STAGE
    STAGE = 'platform'
    if sys.platform != 'darwin' or sys.argv[1:]:
        raise ValueError('requires-macos-and-no-arguments')
    STAGE = 'source'
    if SOURCE.is_symlink() or not SOURCE.is_file() or not 0 < SOURCE.stat().st_size <= 65536:
        raise ValueError('requires-exact-regular-probe-source')
    STAGE = 'sdk-lookup'
    lookup = subprocess.run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'],
        stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=15, check=False)
    if lookup.returncode or not 0 < len(lookup.stdout) <= 4096:
        raise ValueError('sdk-lookup-failed-or-empty')
    STAGE = 'sdk-path'
    sdk = resolve_sdk(lookup.stdout)
    print('NativeReaderProbeSDKPrerequisite ' + json.dumps(dict(schema=1, stage=STAGE,
        resolvedSDK=sdk.name, selectedSDK=Path(lookup.stdout.strip()).name,
        nativeTestsExecuted=0, runtimeCalibration=False), sort_keys=True), flush=True)
    STAGE = 'guardian-import'
    owned = load_owned()
    cancelled = [0]
    def receive(signum, _frame):
        if not cancelled[0]: cancelled[0] = signum
    for signum in (signal.SIGINT, signal.SIGTERM): signal.signal(signum, receive)
    command = ['xcrun', '--sdk', 'iphonesimulator', 'clang', '-target', 'arm64-apple-ios26.0-simulator',
        '-isysroot', str(sdk), '-fobjc-arc', '-fmodules', '-fsyntax-only', '-ferror-limit=12',
        '-Werror=implicit-function-declaration', str(SOURCE)]
    # Reuse the existing reserved-session guardian, including actual descendant
    # cleanup. Fixed read-only clang arguments only; no new CLI allow-list entry.
    STAGE = 'owned-clang'
    report = owned.run_owned(command, 60, 9, lambda: cancelled[0], stdin=subprocess.DEVNULL)
    print('NativeReaderProbeSDK ' + json.dumps(dict(schema=1, sdk=sdk.name, architecture='arm64',
        target='iOS26-Simulator', sourceSHA256=hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
        wrapperExit=report['wrapperExit'], timedOut=report['timedOut'],
        elapsedMilliseconds=report['elapsedMilliseconds'], nativeTestsExecuted=0,
        runtimeCalibration=False, fullAcceptance=False), sort_keys=True), flush=True)
    return report['wrapperExit']


def cli():
    try:
        return main()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        # Stage/type are fixed metadata; never print arbitrary SDK lookup output,
        # paths, exception text or environment values.
        print('NativeReaderProbeSDKFailure ' + json.dumps(dict(schema=1, stage=STAGE,
            errorType=type(error).__name__, nativeTestsExecuted=0,
            runtimeCalibration=False, fullAcceptance=False), sort_keys=True), file=sys.stderr, flush=True)
        return 2


if __name__ == '__main__':
    raise SystemExit(cli())
