#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo_root/artifacts/apple-buffer"
xcrun swiftc -j 1 -parse-as-library -swift-version 5 -strict-concurrency=complete \
  "$repo_root/ios/OfflineTikTokPlayer/Playback/PlaybackBuffer.swift" \
  "$repo_root/tests/apple-playback/PreviousPreparationCheck.swift" \
  -o "$repo_root/artifacts/apple-buffer/previous-preparation"
"$repo_root/artifacts/apple-buffer/previous-preparation" "$repo_root/ios/OfflineTikTokPlayerTests/test-video.mp4"
