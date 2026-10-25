#!/usr/bin/env bash
set -euo pipefail
test "$#" -eq 1 || { echo 'Expected exact candidate checkout path' >&2; exit 2; }
harness="$(cd "$(dirname "$0")/.." && pwd)"
cd "$1"
test "$(git rev-parse HEAD)" = 9489d3b3ae85cb41b5ef4f56633dcf41b36505af
git diff --quiet -- ios tests/playback-acceptance.json
git diff --cached --quiet -- ios tests/playback-acceptance.json
mkdir -p artifacts/native
python3 scripts/native-profile-products.py unpack --products artifacts/DerivedData/Build/Products --archive artifacts/native/profile-products.tar.gz
mkdir -p artifacts/native/preparation-stacks
python3 - <<'PY'
from pathlib import Path
import json, re, subprocess
root = Path('artifacts/DerivedData/Build/Products/Debug-iphonesimulator')
paths = [root / 'OfflineTikTokPlayer.app/OfflineTikTokPlayer', root / 'OfflineTikTokPlayer.app.dSYM/Contents/Resources/DWARF/OfflineTikTokPlayer']
rows = []
for path in paths:
    output = subprocess.check_output(['xcrun', 'dwarfdump', '--uuid', str(path)], text=True, timeout=10)
    uuids = re.findall(r'UUID: ([0-9A-Fa-f-]{36}) \(arm64\)', output)
    if len(uuids) != 1: raise SystemExit('Exact arm64 app and dSYM UUIDs required')
    rows.append(dict(path=str(path), uuid=uuids[0].upper()))
if rows[0]['uuid'] != rows[1]['uuid']: raise SystemExit('App/dSYM UUID mismatch')
Path('artifacts/native/preparation-stacks/source-symbols.json').write_text(json.dumps(dict(rows=rows, matched=True, actualTraceSymbolsRequireInspection=True), indent=2) + '\n')
PY
profile="$harness/tests/preparation-stack-profile.json"
flags="$(python3 scripts/verify-native-test-log.py --profile "$profile" --print-xcode-tests)"
selectors=()
while IFS= read -r flag; do selectors+=("$flag"); done <<< "$flags"
test "${#selectors[@]}" -eq 2
shopt -s nullglob
test_runs=(artifacts/DerivedData/Build/Products/*.xctestrun)
test "${#test_runs[@]}" -eq 1
simulator_id="$(python3 scripts/capture-simulator-test-frames.py --resolve-destination 'platform=iOS Simulator,name=iPhone 17 Pro Max')"
: > artifacts/native/xcodebuild-test.log
python3 scripts/capture-simulator-test-frames.py --udid "$simulator_id" --lifetime 900 &
capture_pid=$!
python3 "$harness/scripts/sample-native-preparation.py" --repo "$PWD" --udid "$simulator_id" \
  --log artifacts/native/xcodebuild-test.log --output artifacts/native/preparation-stacks &
sample_pid=$!
cleanup() {
  kill "$capture_pid" 2>/dev/null || true
  wait "$capture_pid" 2>/dev/null || true
  if [ -n "${sample_pid:-}" ]; then
    kill "$sample_pid" 2>/dev/null || true
    wait "$sample_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT
printf '%s\n' 'PreparationStackDiagnostic scope=one-existing-playback-case-plus-required-UI-smoke candidate=Native35 products=reused full80caseAcceptance=not-run samplingPerturbsTiming=true'
set +e
python3 scripts/run-owned-xcodebuild.py --phase profile-test -- xcodebuild \
  -xctestrun "${test_runs[0]}" -destination "platform=iOS Simulator,id=$simulator_id" \
  -resultBundlePath "artifacts/native/Preparation-$(date +%Y%m%d-%H%M%S).xcresult" \
  -jobs 1 -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 120 -maximum-test-execution-time-allowance 120 \
  "${selectors[@]}" CODE_SIGNING_ALLOWED=NO test-without-building 2>&1 | tee artifacts/native/xcodebuild-test.log
statuses=("${PIPESTATUS[@]}")
kill "$sample_pid" 2>/dev/null || true
wait "$sample_pid"
sample_status=$?
sample_pid=""
python3 scripts/verify-native-test-log.py --log artifacts/native/xcodebuild-test.log --profile "$profile" --invocation test-without-building
verification_status=$?
set -e
test "${statuses[0]}" -eq 0 || exit "${statuses[0]}"
test "${statuses[1]}" -eq 0 || exit "${statuses[1]}"
test "$verification_status" -eq 0 || exit "$verification_status"
test "$sample_status" -eq 0 || exit "$sample_status"
