#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
: "${APPLE_TEAM_ID:?Set the approved Apple developer team ID.}"
build_number="${BUILD_NUMBER:?Set an increasing build number, such as 4.1.}"
python3 -c 'import runpy,sys; runpy.run_path("scripts/private-delivery.py")["validate_build_number"](sys.argv[1])' "$build_number"
archive_path="$repo_root/artifacts/release/OfflineTikTokPlayer-$build_number.xcarchive"
python3 scripts/generate-ios-project.py --check
mkdir -p artifacts/release
xcodebuild -project ios/OfflineTikTokPlayer.xcodeproj -scheme OfflineTikTokPlayer \
  -configuration Release -destination 'generic/platform=iOS' -archivePath "$archive_path" \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CURRENT_PROJECT_VERSION="$build_number" archive
printf 'Archive saved: %s\n' "$archive_path"
printf '%s\n' 'Validate and distribute privately in Xcode Organizer after the acceptance checklist passes. No upload was performed.'
