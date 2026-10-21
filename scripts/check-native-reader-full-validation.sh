#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

# Require the reviewed final app/test commit and its exact ios tree.
expected_code_source=e2557146b6f1aacb415c8318372276576778c6cd
expected_ios_tree=6116fe6b71cd0e797c527e5eb31d6b797646b4d0
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
printf '%s\n' "NativeReaderFullScope appAndTestsSource=$expected_code_source iosTree=$expected_ios_tree expectedNative=128 expectedUI=1 expectedCore=95 maximumBuildJobs=1 fullApplicationAcceptance=pending physicalOutput=unverified"
exec bash scripts/check-ios.sh
