#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

# Require the reviewed final app/test commit and its exact ios tree.
expected_code_source=dab05658a1d3b22fb6d1a7d4bb1636bc322a26a5
expected_ios_tree=34f022f848de547962b2b5eb6482dd83f93d8c84
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
# The unfiltered route retains every source-manifest identity and assertion,
# including the traced benchmark previously run twice. This is one full-suite
# invocation, not a fresh-host singleton comparison. Its native exit propagates
# unchanged; the workflow separately verifies all identities after a failed run.
printf '%s\n' "NativeReaderFullScope appAndTestsSource=$expected_code_source iosTree=$expected_ios_tree expectedNative=141 expectedUI=1 expectedCore=97 maximumBuildJobs=1 fullApplicationAcceptance=pending physicalOutput=unverified"
exec bash scripts/check-ios.sh
