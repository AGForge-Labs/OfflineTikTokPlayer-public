#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
if ! command -v swiftc >/dev/null 2>&1 && [ -f "$HOME/.cache/offline-tiktok-swift/home/env.sh" ]; then
  source "$HOME/.cache/offline-tiktok-swift/home/env.sh"
fi
cd "$repo_root"
find ios/OfflineTikTokPlayer ios/OfflineTikTokPlayerTests ios/OfflineTikTokPlayerUITests -name '*.swift' -print0 |
  xargs -0 swiftc -frontend -parse
