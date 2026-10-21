#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
# Launch commits must preserve the reviewed app, test and fixture tree.
expected_ios_tree=f15663a48e48fe25fb66d5506042a1ce49c91459
test "$(git rev-parse HEAD:ios)" = "$expected_ios_tree"
export SWIFTC_MAXIMUM_DETERMINISM=1
mkdir -p artifacts/native
native_log=artifacts/native/xcodebuild-test.log
worker_log=artifacts/native/worker-trace.log
: > "$native_log"
: > "$worker_log"
printf '' | xcrun swiftc -driver-print-jobs -j1 -j3 -typecheck - > artifacts/native/swift-driver-plan.log 2>&1
cat artifacts/native/swift-driver-plan.log
grep -Fq 'SWIFTC_MAXIMUM_DETERMINISM overriding -j' artifacts/native/swift-driver-plan.log
python3 scripts/generate-ios-project.py --check
# A fresh hosted VM has not started CoreSimulator during preceding test classes.
# Bound that service startup separately; keep the existing destination resolver
# and all application/test deadlines unchanged.
python3 - <<'PY'
import subprocess
import time
started = time.monotonic()
try:
    result = subprocess.run(['xcrun', 'simctl', 'list', 'devices', 'available', '--json'],
                            capture_output=True, timeout=60, check=False)
except subprocess.TimeoutExpired:
    print('StartupGraceSimulatorPreflight status=timeout deadlineSeconds=60', flush=True)
    raise SystemExit(2) from None
print(f'StartupGraceSimulatorPreflight status=returned returnCode={result.returncode} elapsedSeconds={time.monotonic() - started:.6f}', flush=True)
if result.returncode:
    raise SystemExit(result.returncode)
PY
destination='platform=iOS Simulator,name=iPhone 17 Pro Max'
simulator_id="$(python3 scripts/capture-simulator-test-frames.py --resolve-destination "$destination")"
python3 scripts/capture-simulator-test-frames.py --udid "$simulator_id" --lifetime 1200 > "$worker_log" &
capture_pid=$!
cleanup_capture() {
  local cleanup_status=$?
  trap - EXIT
  kill "$capture_pid" 2>/dev/null || true
  wait "$capture_pid" 2>/dev/null || true
  cat "$worker_log"
  exit "$cleanup_status"
}
trap cleanup_capture EXIT
printf '%s\n' "StartupGraceScope appAndTestsSource=a6f346feecb6b433ebb9358bb8baee921b8dcf9b iosTree=$expected_ios_tree expectedNative=3 expectedUI=0 fullApplicationAcceptance=false"
xcodebuild -project ios/OfflineTikTokPlayer.xcodeproj -scheme OfflineTikTokPlayer \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath artifacts/DerivedData -resultBundlePath "artifacts/native/StartupGrace-$(date +%Y%m%d-%H%M%S).xcresult" \
  -jobs 1 -parallel-testing-enabled NO \
  -only-testing:OfflineTikTokPlayerTests/PlaybackSelectionVideoRegressionTests/testCommandToEngineToneAndSelectedCustomFrameLatency \
  -only-testing:OfflineTikTokPlayerTests/PlaybackSelectionVideoRegressionTests/testDebugPausedVideoReanchorRejectsUserActionsBeforeFirstFrame \
  -only-testing:OfflineTikTokPlayerTests/ZZZWorkerTraceCalibrationTests/testKnownWorkerWaitPublishesBoundedSamplerCalibration \
  SWIFTC_MAXIMUM_DETERMINISM=1 SWIFT_USE_PARALLEL_WHOLE_MODULE_OPTIMIZATION=NO \
  CODE_SIGNING_ALLOWED=NO test 2>&1 | tee "$native_log"
