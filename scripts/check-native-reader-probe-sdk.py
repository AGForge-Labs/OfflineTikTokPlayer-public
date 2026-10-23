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


def main():
    if sys.platform != 'darwin' or sys.argv[1:]:
        raise ValueError('A local macOS SDK and no command arguments are required')
    if SOURCE.is_symlink() or not SOURCE.is_file() or not 0 < SOURCE.stat().st_size <= 65536:
        raise ValueError('Exact regular probe source is required')
    lookup = subprocess.run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'],
        stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=15, check=False)
    if lookup.returncode or not 0 < len(lookup.stdout) <= 4096:
        raise ValueError('The selected Simulator SDK did not resolve')
    sdk = Path(lookup.stdout.strip()).resolve(strict=True)
    if not sdk.is_dir() or not re.fullmatch(r'iPhoneSimulator[0-9.]+\.sdk', sdk.name):
        raise ValueError('A canonical named public Simulator SDK is required')
    spec = importlib.util.spec_from_file_location('owned_sdk', ROOT / 'scripts/run-owned-xcodebuild.py')
    owned = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(owned)
    cancelled = [0]
    def receive(signum, _frame):
        if not cancelled[0]: cancelled[0] = signum
    for signum in (signal.SIGINT, signal.SIGTERM): signal.signal(signum, receive)
    command = ['xcrun', '--sdk', 'iphonesimulator', 'clang', '-target', 'arm64-apple-ios26.0-simulator',
        '-isysroot', str(sdk), '-fobjc-arc', '-fmodules', '-fsyntax-only', '-ferror-limit=12',
        '-Werror=implicit-function-declaration', str(SOURCE)]
    # Reuse the existing reserved-session guardian, including actual descendant
    # cleanup. Fixed read-only clang arguments only; no new CLI allow-list entry.
    report = owned.run_owned(command, 60, 9, lambda: cancelled[0], stdin=subprocess.DEVNULL)
    print('NativeReaderProbeSDK ' + json.dumps(dict(schema=1, sdk=sdk.name, architecture='arm64',
        target='iOS26-Simulator', sourceSHA256=hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
        wrapperExit=report['wrapperExit'], timedOut=report['timedOut'],
        elapsedMilliseconds=report['elapsedMilliseconds'], nativeTestsExecuted=0,
        runtimeCalibration=False, fullAcceptance=False), sort_keys=True), flush=True)
    return report['wrapperExit']


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.SubprocessError):
        print('Native reader probe SDK preflight unavailable; no build or native acceptance', file=sys.stderr)
        raise SystemExit(2)
