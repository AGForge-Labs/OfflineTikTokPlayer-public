#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
mkdir -p artifacts/native
native_log=artifacts/native/xcodebuild-test.log
: > "$native_log"
expected_ios_tree=3b2cbcb84bf67397e1ff90b8f0d69151d90854f0
test "$(git rev-parse HEAD:ios)" = "$expected_ios_tree"
export SWIFTC_MAXIMUM_DETERMINISM=1
printf '' | xcrun swiftc -driver-print-jobs -j1 -j3 -typecheck - > artifacts/native/swift-driver-plan.log 2>&1
cat artifacts/native/swift-driver-plan.log
grep -Fq 'SWIFTC_MAXIMUM_DETERMINISM overriding -j' artifacts/native/swift-driver-plan.log
python3 scripts/generate-ios-project.py --check
bash scripts/test-core.sh
python3 - <<'PY'
import subprocess
import time
started = time.monotonic()
try:
    result = subprocess.run(['xcrun', 'simctl', 'list', 'devices', 'available', '--json'],
                            capture_output=True, timeout=60, check=False)
except subprocess.TimeoutExpired:
    print('NativeReaderSimulatorPreflight status=timeout deadlineSeconds=60', flush=True)
    raise SystemExit(2) from None
print(f'NativeReaderSimulatorPreflight status=returned returnCode={result.returncode} elapsedSeconds={time.monotonic() - started:.6f}', flush=True)
if result.returncode:
    raise SystemExit(result.returncode)
PY
simulator_id="$(python3 scripts/capture-simulator-test-frames.py --resolve-destination 'platform=iOS Simulator,name=iPhone 17 Pro Max')"
printf '%s\n' "NativeReaderIndependenceScope appAndTestsSource=618fdfecbc79ebe1ffc4ef31fa9b04b7b15804c5 iosTree=$expected_ios_tree expectedNative=18 expectedUI=0 compositorRequests=0 externalProfilerRequests=0 nativeGateMaximumSeconds=5 refillMaximumSeconds=1 fullApplicationAcceptance=false purpose=bounded-reader-mailbox-causal-green-and-decoder-parity"
xcodebuild -project ios/OfflineTikTokPlayer.xcodeproj -scheme OfflineTikTokPlayer \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath artifacts/DerivedData -resultBundlePath "artifacts/native/NativeReaderIndependence-$(date +%Y%m%d-%H%M%S).xcresult" \
  -jobs 1 -parallel-testing-enabled NO \
  -only-testing:OfflineTikTokPlayerTests/ContinuousPCMDecoderTests \
  SWIFTC_MAXIMUM_DETERMINISM=1 SWIFT_USE_PARALLEL_WHOLE_MODULE_OPTIMIZATION=NO \
  CODE_SIGNING_ALLOWED=NO test 2>&1 | tee "$native_log"
