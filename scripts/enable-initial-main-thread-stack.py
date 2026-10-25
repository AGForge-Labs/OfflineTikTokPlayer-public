#!/usr/bin/env python3
"""Opt in only the native test target in this one owned xctestrun file."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib

def enable(value):
    if set(value) != {'OfflineTikTokPlayerTests', 'OfflineTikTokPlayerUITests', '__xctestrun_metadata__'}:
        raise ValueError('Expected the existing native and UI test targets')
    if value['__xctestrun_metadata__'].get('FormatVersion') != 1:
        raise ValueError('Unexpected xctestrun format')
    target = value['OfflineTikTokPlayerTests']
    if target.get('TestBundlePath') != '__TESTHOST__/PlugIns/OfflineTikTokPlayerTests.xctest':
        raise ValueError('Unexpected native test bundle')
    environment = target.setdefault('EnvironmentVariables', {})
    if 'OP_INITIAL_MAIN_THREAD_STACK' in environment:
        raise ValueError('Refuse an already modified diagnostic run')
    environment['OP_INITIAL_MAIN_THREAD_STACK'] = '1'

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('xctestrun', type=Path)
    args = parser.parse_args()
    original = args.xctestrun.read_bytes()
    value = plistlib.loads(original)
    enable(value)
    updated = plistlib.dumps(value)
    args.xctestrun.write_bytes(updated)
    print('InitialMainThreadRun ' + json.dumps(dict(schema=1, originalSHA256=hashlib.sha256(original).hexdigest(),
          updatedSHA256=hashlib.sha256(updated).hexdigest(), onlyNativeEnvironmentAdded=True,
          phaseExecutionQualified=False, runtimeAcceptance=False)))

if __name__ == '__main__': main()
