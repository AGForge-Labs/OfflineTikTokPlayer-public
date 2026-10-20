#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
if [ "$#" -eq 0 ]; then
  set --
elif [ "$#" -eq 1 ] && [ "$1" = "--selection-only" ]; then
  set -- \
    -only-testing:OfflineTikTokPlayerTests/PlaybackSelectionFailureTests \
    -only-testing:OfflineTikTokPlayerTests/PlaybackSelectionVideoRegressionTests \
    -only-testing:OfflineTikTokPlayerTests/ContinuousAudioPlayerTests \
    -only-testing:OfflineTikTokPlayerTests/ContinuousPCMDecoderTests
else
  printf '%s\n' 'Usage: check-ios.sh [--selection-only]' >&2
  exit 2
fi
command -v xcodebuild >/dev/null || { printf '%s\n' 'Xcode 26 or later on macOS is required.' >&2; exit 2; }
python3 scripts/generate-ios-project.py --check
bash scripts/test-core.sh
bash scripts/test-apple-buffer.sh
mkdir -p artifacts/native
destination="${SIMULATOR_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro Max}"
simulator_id="$(python3 scripts/capture-simulator-test-frames.py --resolve-destination "$destination")"
# Native window tests request real compositor pixels through their own app tmp.
# Pin the test and capture to the same existing Simulator; one helper, no extra app launch.
python3 scripts/capture-simulator-test-frames.py --udid "$simulator_id" --lifetime 1200 &
capture_pid=$!
cleanup_capture() {
  local cleanup_status=$?
  trap - EXIT
  kill "$capture_pid" 2>/dev/null || true
  wait "$capture_pid" 2>/dev/null || true
  exit "$cleanup_status"
}
trap cleanup_capture EXIT
xcodebuild -project ios/OfflineTikTokPlayer.xcodeproj -scheme OfflineTikTokPlayer \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath artifacts/DerivedData -resultBundlePath "artifacts/native/Tests-$(date +%Y%m%d-%H%M%S).xcresult" \
  -jobs 1 -parallel-testing-enabled NO \
  "$@" CODE_SIGNING_ALLOWED=NO test
