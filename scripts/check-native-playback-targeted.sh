#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
expected_code_source=da866ce5064a1968fb192b85b8031eb5be6962b1
expected_ios_tree=5a7a28c05d9e28dad97fd1245e215d414c446d2c
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
test "$#" -eq 1 || { printf '%s\n' 'Usage: check-native-playback-targeted.sh --verify-source|benchmark|controls' >&2; exit 2; }
verify_source
if [ "$1" = --verify-source ]; then exit 0; fi
mode="$1"
case "$mode" in
  benchmark) cases=(testDefaultProductionSelectionLatencyAndStreamingContinuityWithoutCapture testProductionSelectionLatencyAndStreamingContinuityWithoutCapture) ;;
  controls) cases=(testExplicitSeekEntryBeforeInitialOwnerInstallationPreservesNativeCorrection testNaturalBoundaryAtPositiveIncomingOffsetRevealsB testNaturalBoundaryWithNativeLaneActivityRevealsB testPauseSeekResumeBeforeFirstReturnedVisitPreservesExplicitForce testReturnedVideoWaitsForInitialReadyCallbackBeforeVisitOrDriftSeek) ;;
  *) printf '%s\n' 'Unknown targeted validation scope.' >&2; exit 2 ;;
esac
export SWIFTC_MAXIMUM_DETERMINISM=1
mkdir -p artifacts/native
native_log="artifacts/native/native-playback-$mode.log"
: > "$native_log"
command -v xcodebuild >/dev/null || { printf '%s\n' 'Xcode on macOS is required.' >&2; exit 2; }
printf '' | xcrun swiftc -driver-print-jobs -j1 -j3 -typecheck - > artifacts/native/targeted-swift-plan.log 2>&1
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
if [ "$mode" = controls ]; then
  python3 scripts/capture-simulator-test-frames.py --udid "$simulator_id" --lifetime 1200 &
  capture_pid=$!
fi
arguments=()
for name in "${cases[@]}"; do arguments+=("-only-testing:OfflineTikTokPlayerTests/PlaybackSelectionVideoRegressionTests/$name"); done
printf '%s\n' "NativePlaybackTargetedScope mode=$mode appAndTestsSource=$expected_code_source iosTree=$expected_ios_tree expectedNative=${#cases[@]} expectedUI=0 maximumBuildJobs=1 physicalOutput=unverified fullAcceptance=false"
xcodebuild -project ios/OfflineTikTokPlayer.xcodeproj -scheme OfflineTikTokPlayer \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath artifacts/DerivedData -resultBundlePath "artifacts/native/Targeted-$mode-$(date +%Y%m%d-%H%M%S).xcresult" \
  -jobs 1 -parallel-testing-enabled NO "${arguments[@]}" \
  SWIFTC_MAXIMUM_DETERMINISM=1 SWIFT_USE_PARALLEL_WHOLE_MODULE_OPTIMIZATION=NO \
  CODE_SIGNING_ALLOWED=NO test 2>&1 | tee "$native_log"
