#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
expected_code_source=0b79bf2838c632a746428e39db27b7c32a300614
expected_ios_tree=9039a800b484a10de3ba5f46e49483dfda75c001
verify_source() {
  case "$expected_code_source$expected_ios_tree" in
    ''|*PENDING*|*[!0-9a-f]*) printf '%s\n' 'Final committed source pins required.' >&2; return 2 ;;
  esac
  test "${#expected_code_source}" -eq 40
  test "${#expected_ios_tree}" -eq 40
  git cat-file -e "$expected_code_source^{commit}"
  git merge-base --is-ancestor "$expected_code_source" HEAD
  test "$(git rev-parse "$expected_code_source:ios")" = "$expected_ios_tree"
  test "$(git rev-parse HEAD:ios)" = "$expected_ios_tree"
  git diff --quiet -- ios
  git diff --cached --quiet -- ios
}

# Local standard-library evidence operations only. No Saved data, credentials,
# or media bytes are opened. Raw process inventory is never printed or saved.
evidence_tool() {
  python3 - "$@" <<'PY'
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import time
import uuid

ROOT = Path.cwd().resolve()
NATIVE = ROOT / 'artifacts/native'
PRODUCTS = ROOT / 'artifacts/DerivedData/Build/Products'
RECEIPT = NATIVE / 'native-playback-build.json'
CONTROL_ROOT = NATIVE / 'native-playback-controls'
STATUSES = CONTROL_ROOT / 'statuses.tsv'
BUNDLE = 'dev.galaxybigbird.OfflineTikTokPlayer'
EXECUTABLE = 'OfflineTikTokPlayer'
PREFIX = 'OfflineTikTokPlayerTests.PlaybackSelectionVideoRegressionTests/'
CASES = (
    'testIndependentNativeOwnerSpanTracingOffThenOn',
    'testIndependentNativeOwnerSpanTracingOnThenOff',
    'testRetainedNativeHostControlExplicitSeekKeepsSynchronizedNumericFallback',
    'testRetainedNativeHostControlStaleRequestKeepsProductionArgument',
)

def require(condition, message):
    if not condition:
        raise ValueError(message)

class RuntimeHostIdentityError(ValueError):
    pass

def runtime_host(log, identity, simulator):
    def canonical_uuid(value):
        require(isinstance(value, str) and re.fullmatch(
            r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}', value) is not None,
            'Runtime UUID is unavailable or noncanonical')
        return str(uuid.UUID(value))

    def unique_object(pairs):
        require(len(dict(pairs)) == len(pairs), 'Duplicate runtime JSON field')
        return dict(pairs)

    try:
        lines = [line for line in log.splitlines() if 'NativeRuntimeHost' in line]
        require(len(lines) == 1 and len(lines[0]) <= 2048, 'Expected one bounded runtime host receipt')
        line = re.sub(r'^\d{4}-\d\d-\d\dT\S+Z ', '', lines[0])
        require(line.startswith('NativeRuntimeHost '), 'Malformed runtime host receipt prefix')
        value = json.loads(line[len('NativeRuntimeHost '):], object_pairs_hook=unique_object)
        require(isinstance(value, dict) and set(value) == {
            'schema', 'simulatorUDID', 'pid', 'bundleIdentifier', 'moduleNonce', 'testName'},
            'Unexpected runtime host receipt fields')
        require(type(value['schema']) is int and value['schema'] == 1, 'Wrong runtime host receipt schema')
        require(canonical_uuid(value['simulatorUDID']) == canonical_uuid(simulator), 'Runtime simulator mismatch')
        require(value['bundleIdentifier'] == BUNDLE, 'Runtime app bundle mismatch')
        require(type(value['pid']) is int and 0 < value['pid'] <= 2147483647, 'Runtime process identity unavailable')
        owner, method = identity.split('/', 1)
        require(owner == PREFIX[:-1]
                and value['testName'] == '-[PlaybackSelectionVideoRegressionTests %s]' % method,
                'Runtime XCTest identity mismatch')
        value['moduleNonce'] = canonical_uuid(value['moduleNonce'])
        return value
    except (ValueError, TypeError, KeyError):
        raise RuntimeHostIdentityError('Runtime host identity unavailable or mismatched') from None

def verifier():
    require(len(CASES) == 4 and len(set(CASES)) == 4, 'Expected four distinct isolated controls')
    spec = importlib.util.spec_from_file_location('evidence', ROOT / 'scripts/verify-native-test-log.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    require({PREFIX + name for name in CASES}.issubset(module.source_manifest(ROOT)),
            'An isolated control is absent from the pinned source manifest')
    return module

def raw_log(ordinal, name):
    require(1 <= ordinal <= len(CASES) and name == CASES[ordinal - 1], 'Control order/identity mismatch')
    return CONTROL_ROOT / ('%02d-%s.log' % (ordinal, name))

def plan_info():
    plans = sorted(PRODUCTS.glob('*.xctestrun'))
    require(len(plans) == 1, 'Expected exactly one benchmark-produced xctestrun; no rebuild fallback')
    plan = plans[0]
    require(not plan.is_symlink() and plan.is_file() and plan.resolve().parent == PRODUCTS.resolve(),
            'Unexpected xctestrun ownership')
    size = plan.stat().st_size
    require(0 < size <= 16 * 1024 * 1024, 'Unexpected xctestrun size')
    return {'path': plan.relative_to(ROOT).as_posix(), 'size': size,
            'sha256': hashlib.sha256(plan.read_bytes()).hexdigest()}

def read_receipt(source, tree, simulator):
    require(RECEIPT.is_file() and not RECEIPT.is_symlink() and RECEIPT.stat().st_size <= 4096,
            'Missing or unsafe benchmark build receipt')
    receipt = json.loads(RECEIPT.read_text())
    require(receipt.get('schema') == 1 and receipt.get('source') == source and receipt.get('iosTree') == tree,
            'Benchmark build receipt source mismatch')
    require(receipt.get('simulator') == simulator and receipt.get('run') == os.environ.get('GITHUB_RUN_ID')
            and receipt.get('attempt') == os.environ.get('GITHUB_RUN_ATTEMPT'), 'Benchmark build receipt run mismatch')
    require(receipt.get('plan') == plan_info(), 'Compiled test plan changed after benchmark')
    return receipt

def command(arguments, timeout, deadline=None):
    if deadline is not None:
        timeout = min(timeout, deadline - time.monotonic())
        require(timeout > 0, 'App-host boundary deadline elapsed')
    return subprocess.run(arguments, capture_output=True, text=True, timeout=timeout, check=False)

def owned_processes(simulator, deadline=None):
    device_rc, ps_rc, state_code, category = -1, -1, 0, 1
    try:
        require(str(uuid.UUID(simulator)).upper() == simulator.upper(), 'Invalid Simulator identity')
        lookup = command(['xcrun', 'simctl', 'list', 'devices', '--json'], 5, deadline)
        device_rc = lookup.returncode
        require(device_rc == 0, 'Device lookup failed')
        category = 2
        require(len(lookup.stdout) <= 262144, 'Device inventory exceeds bound')
        payload = json.loads(lookup.stdout)
        groups = payload.get('devices') if isinstance(payload, dict) else None
        require(isinstance(groups, dict) and len(groups) <= 64, 'Malformed device inventory')
        devices = []
        for group in groups.values():
            require(isinstance(group, list) and len(devices) + len(group) <= 512, 'Malformed device inventory')
            devices.extend(group)
        matches = [device for device in devices if isinstance(device, dict)
                   and isinstance(device.get('udid'), str) and device['udid'].upper() == simulator.upper()]
        require(len(matches) == 1, 'Device identity is missing or ambiguous')
        device = matches[0]
        state_code = {'Booted': 1, 'Shutdown': 2, 'Creating': 3, 'Deleting': 4}.get(device.get('state'), 0)
        raw_data = device.get('dataPath')
        require(isinstance(raw_data, str) and 0 < len(raw_data) <= 4096, 'Missing device data path')
        data = Path(raw_data)
        require(data.is_absolute() and data.name == 'data' and data.parent.name.upper() == simulator.upper()
                and str(uuid.UUID(data.parent.name)).upper() == simulator.upper()
                and not data.is_symlink() and data.is_dir() and data.resolve(strict=True) == data,
                'Unresolved device data ownership')
        application_root = data / 'Containers' / 'Bundle' / 'Application'
        require(not application_root.is_symlink() and application_root.resolve() == application_root,
                'Unresolved application family')
        category = 3
        listing = command(['/bin/ps', '-ww', '-axo', 'pid=,command='], 2, deadline)
        ps_rc = listing.returncode
        require(ps_rc == 0, 'Process lookup failed')
        category = 4
        require(len(listing.stdout) <= 1048576, 'Process inventory exceeds bound')
        rows = listing.stdout.splitlines()
        require(len(rows) <= 4096, 'Process inventory exceeds bound')
        found = []
        # Inspect only ps-reported candidates. No installation, boot, directory
        # scan, PID termination or cached device family is needed for absence.
        for row in rows:
            fields = row.strip().split(None, 1)
            if len(fields) != 2:
                continue
            pid, text = fields
            match = re.match(r'^(/.+?/OfflineTikTokPlayer\.app/OfflineTikTokPlayer)(?:\s|$)', text)
            if not match:
                require('OfflineTikTokPlayer.app/OfflineTikTokPlayer' not in text
                        and not re.match(r'^OfflineTikTokPlayer(?:\s|$)', text), 'Ambiguous app executable')
                continue
            executable = Path(match.group(1))
            family = executable.parent.parent.parent
            if family != application_root:
                require(family.resolve() != application_root
                        and (len(family.parents) < 4 or family.parents[3].name.upper() != simulator.upper()),
                        'Ambiguous selected-device app family')
                continue
            require(str(uuid.UUID(executable.parent.parent.name)).upper() == executable.parent.parent.name.upper(),
                    'Malformed app container identity')
            plist = executable.parent / 'Info.plist'
            require(not executable.is_symlink() and executable.is_file() and executable.resolve(strict=True) == executable
                    and not plist.is_symlink() and plist.is_file() and plist.stat().st_size <= 65536,
                    'Unresolved process bundle files')
            with plist.open('rb') as stream:
                info = plistlib.load(stream)
            require(isinstance(info, dict) and info.get('CFBundleIdentifier') == BUNDLE
                    and info.get('CFBundleExecutable') == EXECUTABLE,
                    'Unresolved app process identity')
            require(pid.isdigit() and 0 < int(pid) <= 2147483647 and int(pid) not in found and len(found) < 4,
                    'Ambiguous app process inventory')
            found.append(int(pid))
        category = 6 if found else 5
        return found
    except (OSError, ValueError, TypeError, KeyError, plistlib.InvalidFileException, subprocess.SubprocessError):
        raise ValueError('App-host ownership unavailable; numeric category reported') from None
    finally:
        print('NativeControlOwnership deviceLookupRC=%d stateCode=%d psRC=%d categoryCode=%d' %
              (device_rc, state_code, ps_rc, category))

def boundary(simulator, label):
    require(label == 'before-01' or label in {'after-%02d' % n for n in range(1, len(CASES) + 1)}, 'Unknown boundary label')
    before = owned_processes(simulator, time.monotonic() + 7)
    requested, terminate_rc = bool(before), -1
    if requested:
        result = command(['xcrun', 'simctl', 'terminate', simulator, BUNDLE], 5)
        terminate_rc = result.returncode
    # Two adjacent absent observations; no claim about SDK/service quiescence.
    # Each verified device/ps observation can consume5+2seconds. Preserve two
    # post-initial absences while allowing both to finish within a fixed bound.
    deadline, absent_count, after = time.monotonic() + 15, 0, before
    while time.monotonic() < deadline:
        after = owned_processes(simulator, deadline)
        absent_count = absent_count + 1 if not after else 0
        if absent_count == 2:
            print('NativeControlBoundary label=%s before=%d after=0 terminateRequested=%d terminateRC=%d gracefulCleanupClaim=false' %
                  (label, len(before), requested, terminate_rc))
            return
        time.sleep(0.25)
    raise ValueError('Exact own app host remains or absence is unconfirmed; later controls must not run')

try:
    mode, *args = sys.argv[1:]
    if mode == 'initialize-build':
        require(not RECEIPT.exists(), 'Refusing stale benchmark build receipt')
        require(not list(PRODUCTS.glob('*.xctestrun')), 'Fresh job must not reuse a preexisting test plan')
    elif mode == 'generated-plan':
        require(not args, 'Generated plan takes no arguments')
        print(json.dumps(plan_info(), sort_keys=True))
    elif mode == 'plan-path':
        require(len(args) == 1, 'Plan path requires the captured generated plan')
        captured_plan = json.loads(args[0])
        require(captured_plan == plan_info(), 'Compiled test plan changed before benchmark')
        print(captured_plan['path'])
    elif mode == 'record-build':
        source, tree, simulator, native_status, tee_status, captured_json = args
        captured_plan = json.loads(captured_json)
        require(captured_plan == plan_info(), 'Compiled test plan changed during benchmark')
        require(not RECEIPT.exists(), 'Refusing to replace a benchmark build receipt')
        receipt = {'schema': 1, 'source': source, 'iosTree': tree, 'simulator': simulator,
                   'run': os.environ.get('GITHUB_RUN_ID'), 'attempt': os.environ.get('GITHUB_RUN_ATTEMPT'),
                   'plan': captured_plan, 'benchmarkNativeExit': int(native_status), 'benchmarkTeeExit': int(tee_status)}
        RECEIPT.write_text(json.dumps(receipt, sort_keys=True) + '\n')
        print('NativeCompiledProductReceipt schema=1 planCount=1 reusedForControls=true noRebuildFallback=true')
    elif mode == 'read-plan':
        receipt = read_receipt(*args)
        print(receipt['plan']['path'])
    elif mode == 'initialize-controls':
        CONTROL_ROOT.mkdir(parents=True, exist_ok=True)
        require(not STATUSES.exists(), 'Refusing stale isolated control statuses')
        for ordinal, name in enumerate(CASES, 1):
            raw_log(ordinal, name).write_text('')
        STATUSES.write_text('')
    elif mode == 'boundary':
        boundary(*args)
    elif mode == 'verify-one':
        require(len(args) == 5, 'Singleton verification requires exact source/tree/device inputs')
        ordinal = int(args[0])
        name, source, tree, simulator = args[1:]
        read_receipt(source, tree, simulator)
        text = raw_log(ordinal, name).read_text()
        runtime_host(text, PREFIX + name, simulator)
        verifier().verify_log(text, {PREFIX + name}, invocation='test-without-building')
        print('NativeIsolatedControl ordinal=%d identity=%s native=1 ui=0' % (ordinal, PREFIX + name))
    elif mode == 'verify-controls':
        require(len(args) == 2, 'Final aggregate requires the exact source pins')
        receipt = json.loads(RECEIPT.read_text())
        read_receipt(args[0], args[1], receipt['simulator'])
        module, errors, seen, runtime_nonces = verifier(), [], set(), set()
        rows = STATUSES.read_text().splitlines() if STATUSES.is_file() else []
        if len(rows) != len(CASES):
            errors.append('Expected four isolated command receipts; found %d' % len(rows))
        for ordinal, name in enumerate(CASES, 1):
            identity = PREFIX + name
            try:
                require(ordinal <= len(rows), 'Missing isolated command receipt')
                fields = rows[ordinal - 1].split('\t')
                require(len(fields) == 6 and fields[:2] == [str(ordinal), name], 'Wrong, duplicate, or reordered command receipt')
                require(all(value == '0' for value in fields[2:]), 'Native/tee/evidence/host-boundary exit is nonzero: ' + ','.join(fields[2:]))
                text = raw_log(ordinal, name).read_text()
                host = runtime_host(text, identity, receipt['simulator'])
                require(host['moduleNonce'] not in runtime_nonces, 'Runtime process nonce reused across controls')
                runtime_nonces.add(host['moduleNonce'])
                module.verify_log(text, {identity}, invocation='test-without-building')
                seen.add(identity)
                print('NativeIsolatedControlVerified ordinal=%d identity=%s native=1 ui=0' % (ordinal, identity))
            except (OSError, ValueError) as error:
                errors.append('%s: %s' % (identity, error))
        require(len(seen) == 4 and not errors, '\n'.join(errors) or 'Missing unique control identity')
        print('Targeted isolated controls native=4 ui=0; four raw singleton logs; original guards retained; no full/device acceptance claim')
    else:
        raise ValueError('Unknown local evidence operation')
except RuntimeHostIdentityError:
    print('Native isolated harness: runtime host identity unavailable or mismatched', file=sys.stderr)
    raise SystemExit(2)
except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
    print('Native isolated harness: ' + str(error), file=sys.stderr)
    raise SystemExit(1)
PY
}

test "$#" -eq 1 || { printf '%s\n' 'Usage: check-native-playback-targeted.sh --verify-source|benchmark|controls|--verify-controls' >&2; exit 2; }
verify_source
if [ "$1" = --verify-source ]; then exit 0; fi
if [ "$1" = --verify-controls ]; then evidence_tool verify-controls "$expected_code_source" "$expected_ios_tree"; exit 0; fi
mode="$1"
case "$mode" in
  benchmark) cases=(
    OfflineTikTokPlayerTests/PlaybackSelectionVideoRegressionTests/testDefaultProductionSelectionLatencyAndStreamingContinuityWithoutCapture
  ) ;;
  controls) cases=(testIndependentNativeOwnerSpanTracingOffThenOn testIndependentNativeOwnerSpanTracingOnThenOff testRetainedNativeHostControlExplicitSeekKeepsSynchronizedNumericFallback testRetainedNativeHostControlStaleRequestKeepsProductionArgument) ;;
  *) printf '%s\n' 'Unknown targeted validation scope.' >&2; exit 2 ;;
esac
export SWIFTC_MAXIMUM_DETERMINISM=1
mkdir -p artifacts/native
native_log="artifacts/native/native-playback-$mode.log"
: > "$native_log"
command -v xcodebuild >/dev/null || { printf '%s\n' 'Xcode on macOS is required.' >&2; exit 2; }
printf '' | python3 scripts/run-owned-xcodebuild.py --phase driver -- xcrun swiftc -driver-print-jobs -j1 -j3 -typecheck - > artifacts/native/targeted-swift-plan.log 2>&1
cat artifacts/native/targeted-swift-plan.log
grep -Fq 'SWIFTC_MAXIMUM_DETERMINISM overriding -j' artifacts/native/targeted-swift-plan.log
python3 scripts/generate-ios-project.py --check
simulator_id="$(python3 scripts/capture-simulator-test-frames.py --resolve-destination 'platform=iOS Simulator,name=iPhone 17 Pro Max')"
capture_pid=''
cleanup() {
  local status=$?
  trap - EXIT
  if [ -n "$capture_pid" ]; then
    kill "$capture_pid" 2>/dev/null || true
    wait "$capture_pid" 2>/dev/null || true
  fi
  exit "$status"
}
trap cleanup EXIT
printf '%s\n' "NativePlaybackTargetedScope mode=$mode appAndTestsSource=$expected_code_source iosTree=$expected_ios_tree expectedNative=${#cases[@]} expectedUI=0 maximumBuildJobs=1 physicalOutput=unverified fullAcceptance=false"
owned_phase=case-01
xcodebuild() { python3 scripts/run-owned-xcodebuild.py --phase "$owned_phase" -- xcodebuild "$@"; }
if [ "$mode" = benchmark ]; then
  evidence_tool initialize-build
  build_log="artifacts/native/native-playback-build.log"
  : > "$build_log"
  owned_phase=build
  # Only build-for-testing promises to emit the immutable xctestrun product.
  # Build the complete pinned test target; selectors belong to the later run.
  set +e
  xcodebuild -project ios/OfflineTikTokPlayer.xcodeproj -scheme OfflineTikTokPlayer \
    -destination "platform=iOS Simulator,id=$simulator_id" \
    -derivedDataPath artifacts/DerivedData -resultBundlePath "artifacts/native/Targeted-build-$(date +%Y%m%d-%H%M%S).xcresult" \
    -jobs 1 -parallel-testing-enabled NO \
    SWIFTC_MAXIMUM_DETERMINISM=1 SWIFT_USE_PARALLEL_WHOLE_MODULE_OPTIMIZATION=NO \
    CODE_SIGNING_ALLOWED=NO build-for-testing 2>&1 | tee "$build_log"
  build_pipeline_status=("${PIPESTATUS[@]}")
  set -e
  if [ "${build_pipeline_status[0]}" -ne 0 ]; then exit "${build_pipeline_status[0]}"; fi
  if [ "${build_pipeline_status[1]}" -ne 0 ]; then exit "${build_pipeline_status[1]}"; fi
  # Capture once before execution, then bind the final receipt to this exact
  # path/size/hash. A failed build or plan check cannot create a receipt.
  generated_plan="$(evidence_tool generated-plan)"
  test_plan="$(evidence_tool plan-path "$generated_plan")"
  owned_phase=case-01
  arguments=()
  for name in "${cases[@]}"; do arguments+=("-only-testing:$name"); done
  set +e
  xcodebuild -xctestrun "$test_plan" \
    -destination "platform=iOS Simulator,id=$simulator_id" \
    -resultBundlePath "artifacts/native/Targeted-$mode-$(date +%Y%m%d-%H%M%S).xcresult" \
    -jobs 1 -parallel-testing-enabled NO "${arguments[@]}" \
    -test-timeouts-enabled YES -default-test-execution-time-allowance 120 -maximum-test-execution-time-allowance 120 \
    SWIFTC_MAXIMUM_DETERMINISM=1 SWIFT_USE_PARALLEL_WHOLE_MODULE_OPTIMIZATION=NO \
    CODE_SIGNING_ALLOWED=NO test-without-building 2>&1 | tee "$native_log"
  pipeline_status=("${PIPESTATUS[@]}")
  set -e
  receipt_status=0
  evidence_tool record-build "$expected_code_source" "$expected_ios_tree" "$simulator_id" "${pipeline_status[0]}" "${pipeline_status[1]}" "$generated_plan" || receipt_status=$?
  if [ "${pipeline_status[0]}" -ne 0 ]; then exit "${pipeline_status[0]}"; fi
  if [ "${pipeline_status[1]}" -ne 0 ]; then exit "${pipeline_status[1]}"; fi
  exit "$receipt_status"
fi

test_plan="$(evidence_tool read-plan "$expected_code_source" "$expected_ios_tree" "$simulator_id")"
evidence_tool initialize-controls
# This is the same bounded helper used by the existing natural pixel tests.
# It is absent during both benchmarks and never launches an app.
evidence_tool boundary "$simulator_id" before-01
python3 scripts/capture-simulator-test-frames.py --udid "$simulator_id" --lifetime 2400 &
capture_pid=$!
overall_status=0
ordinal=0
for name in "${cases[@]}"; do
  ordinal=$((ordinal + 1))
  # Revalidate the original plan before every invocation. No alternate products,
  # test-plan rewriting, or build fallback is permitted.
  plan_status=0
  evidence_tool read-plan "$expected_code_source" "$expected_ios_tree" "$simulator_id" > /dev/null || plan_status=$?
  if [ "$plan_status" -ne 0 ]; then
    if [ "$overall_status" -eq 0 ]; then overall_status="$plan_status"; fi
    break
  fi
  case_log="$(printf 'artifacts/native/native-playback-controls/%02d-%s.log' "$ordinal" "$name")"
  set +e
  xcodebuild -xctestrun "$test_plan" \
    -destination "platform=iOS Simulator,id=$simulator_id" \
    -resultBundlePath "artifacts/native/Targeted-control-$ordinal-$(date +%Y%m%d-%H%M%S).xcresult" \
    -jobs 1 -parallel-testing-enabled NO \
    "-only-testing:OfflineTikTokPlayerTests/PlaybackSelectionVideoRegressionTests/$name" \
    -test-timeouts-enabled YES -default-test-execution-time-allowance 120 -maximum-test-execution-time-allowance 120 \
    SWIFTC_MAXIMUM_DETERMINISM=1 SWIFT_USE_PARALLEL_WHOLE_MODULE_OPTIMIZATION=NO \
    CODE_SIGNING_ALLOWED=NO test-without-building 2>&1 | tee "$case_log"
  pipeline_status=("${PIPESTATUS[@]}")
  set -e
  verify_status=0
  evidence_tool verify-one "$ordinal" "$name" "$expected_code_source" "$expected_ios_tree" "$simulator_id" || verify_status=$?
  boundary_status=0
  evidence_tool boundary "$simulator_id" "$(printf 'after-%02d' "$ordinal")" || boundary_status=$?
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ordinal" "$name" "${pipeline_status[0]}" "${pipeline_status[1]}" "$verify_status" "$boundary_status" >> artifacts/native/native-playback-controls/statuses.tsv
  for status in "${pipeline_status[0]}" "${pipeline_status[1]}" "$verify_status" "$boundary_status"; do
    if [ "$overall_status" -eq 0 ] && [ "$status" -ne 0 ]; then overall_status="$status"; fi
  done
  if [ "$boundary_status" -ne 0 ]; then break; fi
  if [ "$verify_status" -eq 2 ]; then break; fi
done
aggregate_status=0
evidence_tool verify-controls "$expected_code_source" "$expected_ios_tree" || aggregate_status=$?
if [ "$overall_status" -ne 0 ]; then exit "$overall_status"; fi
exit "$aggregate_status"
