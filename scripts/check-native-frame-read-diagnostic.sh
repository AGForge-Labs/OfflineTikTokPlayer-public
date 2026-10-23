#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
# Calibrate native reported states; counterbalance bounded extra queries after original clock observations.
expected_code_source=c0a1c69a473209a191e2ffa7cc00749f9862951c
expected_ios_tree=0fdb7a494106c210ba9f6b62be1d2ff0d91bb64c
native_log=artifacts/native/native-frame-read.log
native_status=artifacts/native/native-frame-read-status.tsv
preparation_receipt=artifacts/native/frame-read-prepared-source.tsv
mode=all
cases=(
  OfflineTikTokPlayerTests/PlaybackSelectionVideoRegressionTests/testNativePlayerReportedStateCalibratesPauseRecoveryAndSupersession
  OfflineTikTokPlayerTests/PlaybackSelectionVideoRegressionTests/testDefaultProductionSelectionLatencyAndStreamingContinuityWithoutCapture
  OfflineTikTokPlayerTests/PlaybackSelectionVideoRegressionTests/testNativePlayerReportedStateOffThenOn
  OfflineTikTokPlayerTests/PlaybackSelectionVideoRegressionTests/testNativePlayerReportedStateOnThenOff
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
    'OfflineTikTokPlayerTests.PlaybackSelectionVideoRegressionTests/testNativePlayerReportedStateCalibratesPauseRecoveryAndSupersession',
    'OfflineTikTokPlayerTests.PlaybackSelectionVideoRegressionTests/testDefaultProductionSelectionLatencyAndStreamingContinuityWithoutCapture',
    'OfflineTikTokPlayerTests.PlaybackSelectionVideoRegressionTests/testNativePlayerReportedStateOffThenOn',
    'OfflineTikTokPlayerTests.PlaybackSelectionVideoRegressionTests/testNativePlayerReportedStateOnThenOff',
}
if len(expected) != 4 or not expected.issubset(evidence.source_manifest(root)):
    raise SystemExit('Exactly four reported-state calibration and original guarded playback identities must exist in the pinned source')
if sys.argv[1:] == ['inventory']:
    raise SystemExit(0)
if sys.argv[1:] != ['results']:
    raise SystemExit('Unknown diagnostic evidence operation')
status = (root / 'artifacts/native/native-frame-read-status.tsv').read_text().splitlines()
if status != ['0\t0']:
    raise SystemExit('Diagnostic native and tee exits must both be zero')
evidence.verify_log((root / 'artifacts/native/native-frame-read.log').read_text(encoding='utf-8'), expected)
print('NativeFrameReadDiagnosticEvidence native=4 ui=0 nativeExit=0 teeExit=0 fullAcceptance=false repairAccepted=false physicalOutput=unverified')
PY
}
if [ "$#" -eq 1 ] && [ "$1" = --verify-source ]; then
  verify_source
  exit 0
elif [ "$#" -eq 1 ] && [ "$1" = --verify-results ]; then
  verify_source
  evidence_tool results
  exit 0
elif [ "$#" -eq 1 ] && [ "$1" = --prepare ]; then
  mode=prepare
elif [ "$#" -eq 1 ] && [ "$1" = --prepared-native ]; then
  mode=prepared-native
elif [ "$#" -ne 0 ]; then
  printf '%s\n' 'Usage: check-native-frame-read-diagnostic.sh [--verify-source|--verify-results|--prepare|--prepared-native]' >&2
  exit 2
fi
mkdir -p artifacts/native
# Early failures cannot reuse an old native result or successful exit receipt.
: > "$native_log"
: > "$native_status"
if [ "$mode" != prepared-native ]; then
  # A new preparation attempt revokes prior authorization even if its first
  # source, inventory, stale-result or tool-availability gate fails.
  : > "$preparation_receipt"
fi
verify_source
evidence_tool inventory
shopt -s nullglob dotglob nocaseglob
existing_results=(artifacts/native/*.xcresult)
shopt -u nullglob dotglob nocaseglob
test "${#existing_results[@]}" -eq 0 || { printf '%s\n' 'A fresh job with no preexisting xcresult is required.' >&2; exit 2; }
# This diagnostic prepares only the architecture exercised by its ARM runner.
# Check the host without an SDK query; native device architecture is separate evidence.
if ! host_arch="$(uname -m)" || [ "$host_arch" != arm64 ]; then
  printf '%s\n' 'An arm64 host is required for this arm64 Simulator diagnostic.' >&2
  exit 2
fi
export SWIFTC_MAXIMUM_DETERMINISM=1
command -v xcodebuild >/dev/null || { printf '%s\n' 'Xcode on macOS is required.' >&2; exit 2; }
if [ "$mode" = prepared-native ]; then
  if [ ! -f "$preparation_receipt" ] || [ -L "$preparation_receipt" ] || \
     ! cmp -s "$preparation_receipt" <(printf '%s\t%s\t0\t0\n' "$expected_code_source" "$expected_ios_tree"); then
    printf '%s\n' 'Exact successful preparation required before native execution.' >&2
    exit 2
  fi
else
set +e
printf '' | python3 scripts/run-owned-xcodebuild.py --phase driver -- xcrun swiftc -driver-print-jobs -j1 -j3 -typecheck - > artifacts/native/frame-read-swift-plan.log 2>&1
driver_status=("${PIPESTATUS[@]}")
set -e
cat artifacts/native/frame-read-swift-plan.log
if [ "${driver_status[0]}" -ne 0 ]; then exit "${driver_status[0]}"; fi
if [ "${driver_status[1]}" -ne 0 ]; then exit "${driver_status[1]}"; fi
grep -Fq 'SWIFTC_MAXIMUM_DETERMINISM overriding -j' artifacts/native/frame-read-swift-plan.log
python3 scripts/generate-ios-project.py --check
bash scripts/test-core.sh
bash scripts/test-apple-buffer.sh
if [ "$mode" = prepare ]; then
  # Compile before boot so a CoreSimulator stall cannot hide SDK source errors.
  # The later ordinary `test` action retains its source checks and may perform
  # an incremental build; this receipt never claims an immutable test plan.
  build_log=artifacts/native/frame-read-build.log
  set +e
  python3 scripts/run-owned-xcodebuild.py --phase build -- xcodebuild \
    -project ios/OfflineTikTokPlayer.xcodeproj -scheme OfflineTikTokPlayer \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath artifacts/DerivedData \
    -jobs 1 -parallel-testing-enabled NO \
    SWIFTC_MAXIMUM_DETERMINISM=1 SWIFT_USE_PARALLEL_WHOLE_MODULE_OPTIMIZATION=NO \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build-for-testing 2>&1 | tee "$build_log"
  build_status=("${PIPESTATUS[@]}")
  set -e
  if [ "${build_status[0]}" -ne 0 ]; then exit "${build_status[0]}"; fi
  if [ "${build_status[1]}" -ne 0 ]; then exit "${build_status[1]}"; fi
  grep -Fxq '** TEST BUILD SUCCEEDED **' "$build_log"
  verify_source
  printf '%s\t%s\t0\t0\n' "$expected_code_source" "$expected_ios_tree" > "$preparation_receipt"
  printf '%s\n' "NativeFrameReadPreparedEvidence appAndTestsSource=$expected_code_source iosTree=$expected_ios_tree maximumBuildJobs=1 nativeAttempted=false buildDeadlineSeconds=720 driverDeadlineSeconds=60"
  exit 0
fi
fi
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
printf '%s\n' "NativeFrameReadDiagnosticScope appAndTestsSource=$expected_code_source iosTree=$expected_ios_tree expectedNative=4 expectedUI=0 expectedCore=110 maximumBuildJobs=1 fullAcceptance=false repairAccepted=false physicalOutput=unverified"
# These four exact identities execute in a fresh disposable process; actual XCTest records establish order.
# Original timing, continuity, capture, identity and cleanup assertions remain unchanged.
# No earlier case is credited as passed or bypassed through a fake/reset state.
# There is no promotion prefix. Actual XCTest start/result records determine
# execution history; selected-list order is not a matched-history guarantee.
# All other cases remain in full source; full acceptance remains mandatory.
# Every selected case and both native/tee exits must pass without exemptions.
if [ -n "${GITHUB_OUTPUT:-}" ]; then printf 'attempted=true\n' >> "$GITHUB_OUTPUT"; fi
set +e
xcodebuild -project ios/OfflineTikTokPlayer.xcodeproj -scheme OfflineTikTokPlayer \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath artifacts/DerivedData -resultBundlePath "artifacts/native/Tests-$(date +%Y%m%d-%H%M%S).xcresult" \
  -jobs 1 -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 120 -maximum-test-execution-time-allowance 120 \
  "${arguments[@]}" SWIFTC_MAXIMUM_DETERMINISM=1 SWIFT_USE_PARALLEL_WHOLE_MODULE_OPTIMIZATION=NO \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO test 2>&1 | tee "$native_log"
pipeline_status=("${PIPESTATUS[@]}")
set -e
printf '%s\t%s\n' "${pipeline_status[0]}" "${pipeline_status[1]}" > "$native_status"
if [ "${pipeline_status[0]}" -ne 0 ]; then exit "${pipeline_status[0]}"; fi
if [ "${pipeline_status[1]}" -ne 0 ]; then exit "${pipeline_status[1]}"; fi
evidence_tool results
