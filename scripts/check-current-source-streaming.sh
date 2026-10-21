#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
# Filled only after the complete source/test diff is reviewed and committed.
expected_ios_tree=8a1cae1ad2bf1d2deb3a2ec2902902f635937dca
test "$(git rev-parse HEAD:ios)" = "$expected_ios_tree"
export SWIFTC_MAXIMUM_DETERMINISM=1
mkdir -p artifacts/native
native_log=artifacts/native/xcodebuild-test.log
: > "$native_log"
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
    print('CurrentSourceSimulatorPreflight status=timeout deadlineSeconds=60', flush=True)
    raise SystemExit(2) from None
print(f'CurrentSourceSimulatorPreflight status=returned returnCode={result.returncode} elapsedSeconds={time.monotonic() - started:.6f}', flush=True)
if result.returncode:
    raise SystemExit(result.returncode)
PY
destination='platform=iOS Simulator,name=iPhone 17 Pro Max'
simulator_id="$(python3 scripts/capture-simulator-test-frames.py --resolve-destination "$destination")"
printf '%s\n' "CurrentSourceScope appAndTestsSource=483e8e6c5e2ac28f9bec1649db0362af3a0e78c4 iosTree=$expected_ios_tree expectedNative=3 expectedUI=0 compositorRequests=0 externalProfilerRequests=0 fullApplicationAcceptance=false"
# No screenshot/profile watcher is launched. Existing original capture cases
# remain in the full suite; this focused control does not accept visibility.
xcodebuild -project ios/OfflineTikTokPlayer.xcodeproj -scheme OfflineTikTokPlayer \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath artifacts/DerivedData -resultBundlePath "artifacts/native/CurrentSource-$(date +%Y%m%d-%H%M%S).xcresult" \
  -jobs 1 -parallel-testing-enabled NO \
  -only-testing:OfflineTikTokPlayerTests/PlaybackSelectionVideoRegressionTests/testStreamingCurrentSourceNativeReadWithoutCapture \
  -only-testing:OfflineTikTokPlayerTests/ContinuousPCMDecoderTests/testStagedNativeInputMatchesCompleteCallbackPresentationsAcrossCodecsAndRateRatios \
  -only-testing:OfflineTikTokPlayerTests/ContinuousPCMDecoderTests/testResampledStreamingLoopAndSeekRebuildTheOriginalConverterHistory \
  SWIFTC_MAXIMUM_DETERMINISM=1 SWIFT_USE_PARALLEL_WHOLE_MODULE_OPTIMIZATION=NO \
  CODE_SIGNING_ALLOWED=NO test 2>&1 | tee "$native_log"
