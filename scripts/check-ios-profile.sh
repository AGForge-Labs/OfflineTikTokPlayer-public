#!/usr/bin/env bash
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
case "${1:-}" in build|test) mode="$1";; *) echo 'Usage: check-ios-profile.sh build|test' >&2; exit 2;; esac
test "$#" -eq 1 || exit 2
export SWIFTC_MAXIMUM_DETERMINISM=1
mkdir -p artifacts/native
profile_flags="$(python3 scripts/verify-native-test-log.py --profile tests/playback-acceptance.json --print-xcode-tests)"
selectors=()
while IFS= read -r flag; do selectors+=("$flag"); done <<< "$profile_flags"
python3 scripts/generate-ios-project.py --check
command -v xcodebuild >/dev/null || { echo 'Xcode26 on macOS is required.' >&2; exit 2; }
echo 'NativePlaybackBuildMode schema=2 optimized=true requestedSwiftOptimization=-O testOnlySwiftFlags=-Onone debugHooks=retained caseProfile=unchanged acceptance=unchanged'
if [ "$mode" = build ]; then
  : > artifacts/native/xcodebuild-build.log
  set +e
  printf '' | python3 scripts/run-owned-xcodebuild.py --phase driver -- xcrun swiftc -driver-print-jobs -j1 -j3 -typecheck - > artifacts/native/swift-driver-plan.log 2>&1
  statuses=("${PIPESTATUS[@]}")
  set -e
  cat artifacts/native/swift-driver-plan.log
  test "${statuses[0]}" -eq 0 || exit "${statuses[0]}"
  test "${statuses[1]}" -eq 0 || exit "${statuses[1]}"
  grep -Fq 'SWIFTC_MAXIMUM_DETERMINISM overriding -j' artifacts/native/swift-driver-plan.log
  bash scripts/test-core.sh
  bash scripts/test-apple-buffer.sh
  set +e
  python3 scripts/run-owned-xcodebuild.py --phase profile-build -- xcodebuild \
    -project ios/OfflineTikTokPlayer.xcodeproj -scheme OfflineTikTokPlayer \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath artifacts/DerivedData \
    -jobs 1 -parallel-testing-enabled NO "${selectors[@]}" \
    SWIFT_OPTIMIZATION_LEVEL=-O PLAYBACK_TEST_SWIFT_FLAGS=-Onone \
    SWIFTC_MAXIMUM_DETERMINISM=1 SWIFT_USE_PARALLEL_WHOLE_MODULE_OPTIMIZATION=NO \
    ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build-for-testing 2>&1 | tee artifacts/native/xcodebuild-build.log
  statuses=("${PIPESTATUS[@]}")
  set -e
  test "${statuses[0]}" -eq 0 || exit "${statuses[0]}"
  test "${statuses[1]}" -eq 0 || exit "${statuses[1]}"
  python3 scripts/native-profile-products.py pack --products artifacts/DerivedData/Build/Products --archive artifacts/native/profile-products.tar.gz
  exit 0
fi
: > artifacts/native/xcodebuild-test.log
python3 scripts/native-profile-products.py unpack --products artifacts/DerivedData/Build/Products --archive artifacts/native/profile-products.tar.gz
shopt -s nullglob
test_runs=(artifacts/DerivedData/Build/Products/*.xctestrun)
test "${#test_runs[@]}" -eq 1 || { echo 'Expected exactly one compiled test run' >&2; exit 1; }
destination="${SIMULATOR_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro Max}"
simulator_id="$(python3 scripts/capture-simulator-test-frames.py --resolve-destination "$destination")"
python3 scripts/capture-simulator-test-frames.py --udid "$simulator_id" --lifetime 4800 &
capture_pid=$!
trap 'kill "$capture_pid" 2>/dev/null || true; wait "$capture_pid" 2>/dev/null || true' EXIT
set +e
python3 scripts/run-owned-xcodebuild.py --phase profile-test -- xcodebuild \
  -xctestrun "${test_runs[0]}" -destination "platform=iOS Simulator,id=$simulator_id" \
  -resultBundlePath "artifacts/native/Tests-$(date +%Y%m%d-%H%M%S).xcresult" \
  -jobs 1 -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 120 -maximum-test-execution-time-allowance 120 \
  "${selectors[@]}" CODE_SIGNING_ALLOWED=NO test-without-building 2>&1 | tee artifacts/native/xcodebuild-test.log
statuses=("${PIPESTATUS[@]}")
set -e
test "${statuses[0]}" -eq 0 || exit "${statuses[0]}"
test "${statuses[1]}" -eq 0 || exit "${statuses[1]}"
python3 scripts/verify-native-test-log.py --log artifacts/native/xcodebuild-test.log --profile tests/playback-acceptance.json --invocation test-without-building
