#!/usr/bin/env bash
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
export SWIFTC_MAXIMUM_DETERMINISM=1
mkdir -p artifacts/native
profile=tests/initial-main-thread-profile.json
flags="$(python3 scripts/verify-native-test-log.py --profile "$profile" --print-xcode-tests)"
selectors=()
while IFS= read -r flag; do selectors+=("$flag"); done <<< "$flags"
python3 scripts/generate-ios-project.py --check
{
  git rev-parse HEAD HEAD:ios/OfflineTikTokPlayer HEAD:ios/PlayerCore
  xcodebuild -version
  xcrun --sdk iphonesimulator --show-sdk-version
  printf 'InitialMainThreadCaptureScope schema=1 oneQuery=true phaseExecutionQualified=false full80Acceptance=false signing=false runtimeChanged=false\n'
} | tee artifacts/native/initial-main-thread-identity.log
python3 scripts/run-owned-xcodebuild.py --phase profile-build -- xcodebuild \
  -project ios/OfflineTikTokPlayer.xcodeproj -scheme OfflineTikTokPlayer \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath artifacts/DerivedData \
  -jobs 1 -parallel-testing-enabled NO "${selectors[@]}" \
  SWIFT_OPTIMIZATION_LEVEL=-O PLAYBACK_TEST_SWIFT_FLAGS=-Onone \
  SWIFTC_MAXIMUM_DETERMINISM=1 SWIFT_USE_PARALLEL_WHOLE_MODULE_OPTIMIZATION=NO \
  ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build-for-testing 2>&1 | tee artifacts/native/xcodebuild-build.log

products=artifacts/DerivedData/Build/Products/Debug-iphonesimulator
symbols=artifacts/native/source-symbols.log
check_symbols() {
  local binary="$1" dwarf="$2" first second
  first="$(xcrun dwarfdump --uuid "$binary" | tee -a "$symbols")"
  second="$(xcrun dwarfdump --uuid "$dwarf" | tee -a "$symbols")"
  test "$(awk '{print $2}' <<< "$first")" = "$(awk '{print $2}' <<< "$second")"
  test "$(awk '{print $3}' <<< "$first")" = "($(uname -m))"
}
check_symbols "$products/OfflineTikTokPlayer.app/OfflineTikTokPlayer" \
  "$products/OfflineTikTokPlayer.app.dSYM/Contents/Resources/DWARF/OfflineTikTokPlayer"
check_symbols "$products/OfflineTikTokPlayer.app/PlugIns/OfflineTikTokPlayerTests.xctest/OfflineTikTokPlayerTests" \
  "$products/OfflineTikTokPlayer.app/PlugIns/OfflineTikTokPlayerTests.xctest.dSYM/Contents/Resources/DWARF/OfflineTikTokPlayerTests"
cat "$symbols"
shopt -s nullglob
test_runs=(artifacts/DerivedData/Build/Products/*.xctestrun)
test "${#test_runs[@]}" -eq 1
python3 scripts/enable-initial-main-thread-stack.py "${test_runs[0]}" | tee artifacts/native/initial-main-thread-run.log
destination='platform=iOS Simulator,name=iPhone 17 Pro Max'
simulator_id="$(python3 scripts/capture-simulator-test-frames.py --resolve-destination "$destination")"
python3 scripts/capture-simulator-test-frames.py --udid "$simulator_id" --lifetime 4800 &
capture_pid=$!
trap 'kill "$capture_pid" 2>/dev/null || true; wait "$capture_pid" 2>/dev/null || true' EXIT
python3 scripts/run-owned-xcodebuild.py --phase profile-test -- xcodebuild \
  -xctestrun "${test_runs[0]}" -destination "platform=iOS Simulator,id=$simulator_id" \
  -resultBundlePath artifacts/native/InitialMainThread.xcresult \
  -jobs 1 -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 120 -maximum-test-execution-time-allowance 120 \
  "${selectors[@]}" CODE_SIGNING_ALLOWED=NO test-without-building 2>&1 | tee artifacts/native/xcodebuild-test.log
python3 scripts/verify-native-test-log.py --log artifacts/native/xcodebuild-test.log --profile "$profile" --invocation test-without-building
