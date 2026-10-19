#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
command -v xcodebuild >/dev/null || { printf '%s\n' 'Xcode 26 or later on macOS is required.' >&2; exit 2; }
python3 scripts/generate-ios-project.py --check
bash scripts/test-core.sh
mkdir -p artifacts/native
xcodebuild -project ios/OfflineTikTokPlayer.xcodeproj -scheme OfflineTikTokPlayer \
  -destination "${SIMULATOR_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro Max}" \
  -derivedDataPath artifacts/DerivedData -resultBundlePath "artifacts/native/Tests-$(date +%Y%m%d-%H%M%S).xcresult" \
  CODE_SIGNING_ALLOWED=NO test
