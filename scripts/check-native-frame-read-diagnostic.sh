#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
expected_code_source=bbae31de82789d446feaecb29d805f92e4cd6dd2
expected_ios_tree=39202bc7e291f30a4af790a2af43d46f4a70dd8e
native_log=artifacts/native/native-frame-read.log
native_status=artifacts/native/native-frame-read-status.tsv
cases=(
  OfflineTikTokPlayerTests/PlaybackSelectionVideoRegressionTests/testNativeClockHandoffOffThenOn
  OfflineTikTokPlayerTests/PlaybackSelectionVideoRegressionTests/testNativeClockHandoffOnThenOff
  OfflineTikTokPlayerTests/PlaybackSelectionVideoRegressionTests/testNativeItemTimebaseCalibratesAcrossPlaybackSeekAndReinsertion
  OfflineTikTokPlayerTests/PlaybackSelectionVideoRegressionTests/testDefaultProductionSelectionLatencyAndStreamingContinuityWithoutCapture
  OfflineTikTokPlayerTests/PlaybackSelectionVideoRegressionTests/testProductionSelectionLatencyAndStreamingContinuityWithoutCapture
  OfflineTikTokPlayerTests/PlaybackSelectionVideoRegressionTests/testInitialReadyBindsNativeVideoToAdvancedAudioWithoutReseeking
  OfflineTikTokPlayerTests/PlaybackSelectionVideoRegressionTests/testOrdinaryDriftRejectsStoppedNativeClockAndPreservesForcedRecovery
)
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
evidence_tool() {
  python3 - "$@" <<'PY'
import importlib.util
from pathlib import Path
import sys

root = Path.cwd()
spec = importlib.util.spec_from_file_location('evidence', root / 'scripts/verify-native-test-log.py')
evidence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evidence)
expected = {
    'OfflineTikTokPlayerTests.PlaybackSelectionVideoRegressionTests/testNativeClockHandoffOffThenOn',
    'OfflineTikTokPlayerTests.PlaybackSelectionVideoRegressionTests/testNativeClockHandoffOnThenOff',
    'OfflineTikTokPlayerTests.PlaybackSelectionVideoRegressionTests/testNativeItemTimebaseCalibratesAcrossPlaybackSeekAndReinsertion',
    'OfflineTikTokPlayerTests.PlaybackSelectionVideoRegressionTests/testDefaultProductionSelectionLatencyAndStreamingContinuityWithoutCapture',
    'OfflineTikTokPlayerTests.PlaybackSelectionVideoRegressionTests/testProductionSelectionLatencyAndStreamingContinuityWithoutCapture',
    'OfflineTikTokPlayerTests.PlaybackSelectionVideoRegressionTests/testInitialReadyBindsNativeVideoToAdvancedAudioWithoutReseeking',
    'OfflineTikTokPlayerTests.PlaybackSelectionVideoRegressionTests/testOrdinaryDriftRejectsStoppedNativeClockAndPreservesForcedRecovery'}
if len(expected) != 7 or not expected.issubset(evidence.source_manifest(root)):
    raise SystemExit('Exactly seven diagnostic identities must exist in the pinned source')
if sys.argv[1:] == ['inventory']:
    raise SystemExit(0)
if sys.argv[1:] != ['results']:
    raise SystemExit('Unknown diagnostic evidence operation')
status = (root / 'artifacts/native/native-frame-read-status.tsv').read_text().splitlines()
if status != ['0\t0']:
    raise SystemExit('Diagnostic native and tee exits must both be zero')
evidence.verify_log((root / 'artifacts/native/native-frame-read.log').read_text(encoding='utf-8'), expected)
print('NativeFrameReadDiagnosticEvidence native=7 ui=0 nativeExit=0 teeExit=0 fullAcceptance=false repairAccepted=false physicalOutput=unverified')
PY
}
if [ "$#" -eq 1 ] && [ "$1" = --verify-source ]; then
  verify_source
  exit 0
elif [ "$#" -eq 1 ] && [ "$1" = --verify-results ]; then
  verify_source
  evidence_tool results
  exit 0
elif [ "$#" -ne 0 ]; then
  printf '%s\n' 'Usage: check-native-frame-read-diagnostic.sh [--verify-source|--verify-results]' >&2
  exit 2
fi
mkdir -p artifacts/native
# Early failures cannot reuse an old native result or successful exit receipt.
: > "$native_log"
: > "$native_status"
verify_source
evidence_tool inventory
shopt -s nullglob dotglob nocaseglob
existing_results=(artifacts/native/*.xcresult)
shopt -u nullglob dotglob nocaseglob
test "${#existing_results[@]}" -eq 0 || { printf '%s\n' 'A fresh job with no preexisting xcresult is required.' >&2; exit 2; }
export SWIFTC_MAXIMUM_DETERMINISM=1
command -v xcodebuild >/dev/null || { printf '%s\n' 'Xcode on macOS is required.' >&2; exit 2; }
printf '' | python3 scripts/run-owned-xcodebuild.py --phase driver -- xcrun swiftc -driver-print-jobs -j1 -j3 -typecheck - > artifacts/native/frame-read-swift-plan.log 2>&1
cat artifacts/native/frame-read-swift-plan.log
grep -Fq 'SWIFTC_MAXIMUM_DETERMINISM overriding -j' artifacts/native/frame-read-swift-plan.log
python3 scripts/generate-ios-project.py --check
bash scripts/test-core.sh
bash scripts/test-apple-buffer.sh
destination="${SIMULATOR_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro Max}"
simulator_id="$(python3 scripts/capture-simulator-test-frames.py --resolve-destination "$destination")"
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
python3 scripts/capture-simulator-test-frames.py --udid "$simulator_id" --lifetime 1200 &
capture_pid=$!
arguments=()
for name in "${cases[@]}"; do
  arguments+=("-only-testing:$name")
done
printf '%s\n' "NativeFrameReadDiagnosticScope appAndTestsSource=$expected_code_source iosTree=$expected_ios_tree expectedNative=7 expectedUI=0 maximumBuildJobs=1 fullAcceptance=false repairAccepted=false physicalOutput=unverified"
# Invoke the single filtered native attempt.
if [ -n "${GITHUB_OUTPUT:-}" ]; then printf 'attempted=true\n' >> "$GITHUB_OUTPUT"; fi
set +e
xcodebuild -project ios/OfflineTikTokPlayer.xcodeproj -scheme OfflineTikTokPlayer \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath artifacts/DerivedData -resultBundlePath "artifacts/native/Tests-$(date +%Y%m%d-%H%M%S).xcresult" \
  -jobs 1 -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 120 -maximum-test-execution-time-allowance 120 \
  "${arguments[@]}" SWIFTC_MAXIMUM_DETERMINISM=1 SWIFT_USE_PARALLEL_WHOLE_MODULE_OPTIMIZATION=NO \
  CODE_SIGNING_ALLOWED=NO test 2>&1 | tee "$native_log"
pipeline_status=("${PIPESTATUS[@]}")
set -e
printf '%s\t%s\n' "${pipeline_status[0]}" "${pipeline_status[1]}" > "$native_status"
if [ "${pipeline_status[0]}" -ne 0 ]; then exit "${pipeline_status[0]}"; fi
if [ "${pipeline_status[1]}" -ne 0 ]; then exit "${pipeline_status[1]}"; fi
evidence_tool results
