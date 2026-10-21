#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

# Require the reviewed final app/test commit and its exact ios tree.
expected_code_source=8f7af3d192e8c85a7d20dbe8bb766fee173a67f6
expected_ios_tree=b3128730940eb36df8fa05959b946e7fd838d842
verify_source() {
  case "$expected_code_source" in
    ''|PENDING|*[!0-9a-f]*) printf '%s\n' 'A final committed app/test source pin is required.' >&2; return 2 ;;
  esac
  case "$expected_ios_tree" in
    ''|PENDING|*[!0-9a-f]*) printf '%s\n' 'A final committed ios tree pin is required.' >&2; return 2 ;;
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

if [ "$#" -eq 1 ] && [ "$1" = '--verify-source' ]; then
  verify_source
  exit 0
elif [ "$#" -ne 0 ]; then
  printf '%s\n' 'Usage: check-native-reader-full-validation.sh [--verify-source]' >&2
  exit 2
fi
verify_source
mkdir -p artifacts/native
native_log=artifacts/native/xcodebuild-test.log
: > "$native_log"
export SWIFTC_MAXIMUM_DETERMINISM=1
command -v xcodebuild >/dev/null || { printf '%s\n' 'Xcode 26 or later on macOS is required.' >&2; exit 2; }
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
    print('NativeReaderFullSimulatorPreflight status=timeout deadlineSeconds=60', flush=True)
    raise SystemExit(2) from None
print(f'NativeReaderFullSimulatorPreflight status=returned returnCode={result.returncode} elapsedSeconds={time.monotonic() - started:.6f}', flush=True)
if result.returncode:
    raise SystemExit(result.returncode)
PY
simulator_id="$(python3 scripts/capture-simulator-test-frames.py --resolve-destination 'platform=iOS Simulator,name=iPhone 17 Pro Max')"
printf '%s\n' "NativeReaderFullInitialScope appAndTestsSource=$expected_code_source iosTree=$expected_ios_tree expectedNative=1 expectedUI=0 compositorRequests=0 externalProfilerRequests=0 fullApplicationAcceptance=false purpose=production-benchmark-before-unchanged-full-regressions"
xcodebuild -project ios/OfflineTikTokPlayer.xcodeproj -scheme OfflineTikTokPlayer \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath artifacts/DerivedData -resultBundlePath "artifacts/native/NativeReaderProduction-$(date +%Y%m%d-%H%M%S).xcresult" \
  -jobs 1 -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 120 -maximum-test-execution-time-allowance 120 \
  -only-testing:OfflineTikTokPlayerTests/PlaybackSelectionVideoRegressionTests/testProductionSelectionLatencyAndStreamingContinuityWithoutCapture \
  SWIFTC_MAXIMUM_DETERMINISM=1 SWIFT_USE_PARALLEL_WHOLE_MODULE_OPTIMIZATION=NO \
  CODE_SIGNING_ALLOWED=NO test 2>&1 | tee "$native_log"
