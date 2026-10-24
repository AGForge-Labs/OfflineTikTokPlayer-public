#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
# Xcode's build queue limit does not replace the Swift driver's generated -jN.
export SWIFTC_MAXIMUM_DETERMINISM=1
mkdir -p artifacts/native
native_log="artifacts/native/xcodebuild-test.log"
# An early failure must never leave a previous run's successful evidence behind.
: > "$native_log"
validation_complete=0
validation_mode=full
optimized_playback=0
if [ "$#" -eq 0 ]; then
  set --
elif [ "$#" -eq 1 ] && [ "$1" = "--selection-only" ]; then
  validation_mode=selection-only
  set -- \
    -only-testing:OfflineTikTokPlayerTests/PlaybackSelectionFailureTests \
    -only-testing:OfflineTikTokPlayerTests/PlaybackSelectionVideoRegressionTests \
    -only-testing:OfflineTikTokPlayerTests/ContinuousAudioPlayerTests \
    -only-testing:OfflineTikTokPlayerTests/ContinuousPCMDecoderTests
elif [ "$#" -eq 1 ] && { [ "$1" = "--playback-acceptance" ] || [ "$1" = "--optimized-playback-acceptance" ]; }; then
  validation_mode=playback-acceptance
  if [ "$1" = "--optimized-playback-acceptance" ]; then optimized_playback=1; fi
  profile_flags="$(python3 scripts/verify-native-test-log.py --profile tests/playback-acceptance.json --print-xcode-tests)"
  set --
  while IFS= read -r flag; do
    set -- "$@" "$flag"
  done <<< "$profile_flags"
else
  printf '%s\n' 'Usage: check-ios.sh [--selection-only|--playback-acceptance|--optimized-playback-acceptance]' >&2
  exit 2
fi
# Keep the default full/profile configuration intact. This explicit comparison
# retains DEBUG hooks and exactly the same source-validated cases/assertions.
# Actual compiler commands must be checked before claiming optimized evidence.
if [ "$optimized_playback" -eq 1 ]; then
  set -- "$@" SWIFT_OPTIMIZATION_LEVEL=-O PLAYBACK_TEST_SWIFT_FLAGS=-Onone
  printf '%s\n' 'NativePlaybackBuildMode schema=2 optimized=true requestedSwiftOptimization=-O testOnlySwiftFlags=-Onone debugHooks=retained caseProfile=unchanged acceptance=unchanged'
fi
command -v xcodebuild >/dev/null || { printf '%s\n' 'Xcode 26 or later on macOS is required.' >&2; exit 2; }
# Print the selected driver's plan only; no compilation is executed by this probe.
set +e
printf '' | python3 scripts/run-owned-xcodebuild.py --phase driver -- xcrun swiftc -driver-print-jobs -j1 -j3 -typecheck - > artifacts/native/swift-driver-plan.log 2>&1
driver_status=("${PIPESTATUS[@]}")
set -e
cat artifacts/native/swift-driver-plan.log
if [ "${driver_status[0]}" -ne 0 ]; then exit "${driver_status[0]}"; fi
if [ "${driver_status[1]}" -ne 0 ]; then exit "${driver_status[1]}"; fi
grep -Fq 'SWIFTC_MAXIMUM_DETERMINISM overriding -j' artifacts/native/swift-driver-plan.log || {
  printf '%s\n' 'The selected Swift driver did not confirm its one-job override.' >&2
  exit 1
}
python3 scripts/generate-ios-project.py --check
bash scripts/test-core.sh
bash scripts/test-apple-buffer.sh
destination="${SIMULATOR_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro Max}"
simulator_id="$(python3 scripts/capture-simulator-test-frames.py --resolve-destination "$destination")"
# Native window tests request real compositor pixels through their own app tmp.
# Pin the test and capture to the same existing Simulator; one helper, no extra app launch.
python3 scripts/capture-simulator-test-frames.py --udid "$simulator_id" --lifetime 4800 &
capture_pid=$!
cleanup_capture() {
  local cleanup_status=$?
  trap - EXIT
  kill "$capture_pid" 2>/dev/null || true
  wait "$capture_pid" 2>/dev/null || true
  if [ "$cleanup_status" -eq 0 ] && [ "$validation_complete" -ne 1 ]; then
    cleanup_status=1
  fi
  exit "$cleanup_status"
}
trap cleanup_capture EXIT
set +e
python3 scripts/run-owned-xcodebuild.py --phase full-test -- xcodebuild -project ios/OfflineTikTokPlayer.xcodeproj -scheme OfflineTikTokPlayer \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath artifacts/DerivedData -resultBundlePath "artifacts/native/Tests-$(date +%Y%m%d-%H%M%S).xcresult" \
  -jobs 1 -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 120 -maximum-test-execution-time-allowance 120 \
  "$@" SWIFTC_MAXIMUM_DETERMINISM=1 SWIFT_USE_PARALLEL_WHOLE_MODULE_OPTIMIZATION=NO \
  CODE_SIGNING_ALLOWED=NO test 2>&1 | tee "$native_log"
native_status=("${PIPESTATUS[@]}")
set -e
if [ "${native_status[0]}" -ne 0 ]; then exit "${native_status[0]}"; fi
if [ "${native_status[1]}" -ne 0 ]; then exit "${native_status[1]}"; fi
if [ "$validation_mode" = selection-only ]; then
  python3 scripts/verify-native-test-log.py --log "$native_log" --selection-only
elif [ "$validation_mode" = playback-acceptance ]; then
  python3 scripts/verify-native-test-log.py --log "$native_log" --profile tests/playback-acceptance.json
else
  python3 scripts/verify-native-test-log.py --log "$native_log"
fi
validation_complete=1
