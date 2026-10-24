#!/usr/bin/env bash
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
export SWIFTC_MAXIMUM_DETERMINISM=1
mkdir -p artifacts/native
: > artifacts/native/xcodebuild-test.log
: > artifacts/native/xcodebuild-build.log
python3 scripts/generate-ios-project.py --check
flags="$(python3 scripts/verify-native-test-log.py --profile tests/playback-loop-diagnostic.json --print-xcode-tests)"
selectors=()
while IFS= read -r flag; do selectors+=("$flag"); done <<< "$flags"
destination="platform=iOS Simulator,name=iPhone 17 Pro Max"
simulator_id="$(python3 scripts/capture-simulator-test-frames.py --resolve-destination "$destination")"
common=(-project ios/OfflineTikTokPlayer.xcodeproj -scheme OfflineTikTokPlayer
  -derivedDataPath artifacts/DerivedData -destination "platform=iOS Simulator,id=$simulator_id"
  -jobs 1 -parallel-testing-enabled NO "${selectors[@]}"
  SWIFT_OPTIMIZATION_LEVEL=-O PLAYBACK_TEST_SWIFT_FLAGS=-Onone
  SWIFTC_MAXIMUM_DETERMINISM=1 SWIFT_USE_PARALLEL_WHOLE_MODULE_OPTIMIZATION=NO
  ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO)
echo 'LoopSourceMixerScope schema=1 originalDefaultCase=true diagnosticCase=true requiredUISmoke=true full74Acceptance=false ReleaseAcceptance=false runtimeUnchanged=true originalAssertions=true'
set +e
python3 scripts/run-owned-xcodebuild.py --phase profile-build -- xcodebuild "${common[@]}" \
  build-for-testing 2>&1 | tee artifacts/native/xcodebuild-build.log
statuses=("${PIPESTATUS[@]}")
set -e
test "${statuses[0]}" -eq 0 || exit "${statuses[0]}"
test "${statuses[1]}" -eq 0 || exit "${statuses[1]}"
set +e
python3 scripts/run-owned-xcodebuild.py --phase profile-test -- xcodebuild "${common[@]}" \
  -resultBundlePath artifacts/native/LoopSourceMixer.xcresult \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 120 \
  -maximum-test-execution-time-allowance 120 test-without-building \
  2>&1 | tee artifacts/native/xcodebuild-test.log
statuses=("${PIPESTATUS[@]}")
set -e
test "${statuses[0]}" -eq 0 || exit "${statuses[0]}"
test "${statuses[1]}" -eq 0 || exit "${statuses[1]}"
python3 scripts/verify-native-test-log.py --log artifacts/native/xcodebuild-test.log \
  --profile tests/playback-loop-diagnostic.json --invocation test-without-building
