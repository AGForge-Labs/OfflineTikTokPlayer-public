#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
swift_bin="${SWIFT_BIN:-swift}"
if ! command -v "$swift_bin" >/dev/null 2>&1 && [ -f "$HOME/.cache/offline-tiktok-swift/home/env.sh" ]; then
  source "$HOME/.cache/offline-tiktok-swift/home/env.sh"
fi
task_package="$repo_root/artifacts/native-cloud-package"
mkdir -p "$task_package/Sources/CloudAdapter" "$task_package/Tests/CloudAdapterTests"
cp "$repo_root/tests/cloud-adapter/Package.swift" "$task_package/Package.swift"
cp "$repo_root/ios/OfflineTikTokPlayer/Services/OneDriveClient.swift" "$task_package/Sources/CloudAdapter/OneDriveClient.swift"
cp "$repo_root/ios/OfflineTikTokPlayer/Services/LibraryRepository.swift" "$task_package/Sources/CloudAdapter/LibraryRepository.swift"
cp "$repo_root/tests/cloud-adapter/Support.swift" "$task_package/Sources/CloudAdapter/Support.swift"
cp "$repo_root/tests/cloud-adapter/OneDriveClientTests.swift" "$task_package/Tests/CloudAdapterTests/OneDriveClientTests.swift"
cp "$repo_root/ios/OfflineTikTokPlayerTests/LibraryRefreshTests.swift" "$task_package/Tests/CloudAdapterTests/LibraryRefreshTests.swift"
PLAYER_CORE_PATH="$repo_root/ios/PlayerCore" "$swift_bin" test --package-path "$task_package" --scratch-path "$repo_root/artifacts/native-cloud-build"
