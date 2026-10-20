#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
swift_bin="${SWIFT_BIN:-swift}"
if ! command -v "$swift_bin" >/dev/null 2>&1 && [ -f "$HOME/.cache/offline-tiktok-swift/home/env.sh" ]; then
  source "$HOME/.cache/offline-tiktok-swift/home/env.sh"
fi
"$swift_bin" test --jobs 1 --package-path "$repo_root/ios/PlayerCore" --scratch-path "$repo_root/artifacts/swift-build"
