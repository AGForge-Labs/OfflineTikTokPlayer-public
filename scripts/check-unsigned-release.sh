#!/usr/bin/env bash
# Compile the frozen candidate for a real iPhone SDK. No signing or test launch.
set -euo pipefail
candidate=9489d3b3ae85cb41b5ef4f56633dcf41b36505af
test "$(git rev-parse HEAD)" = "$candidate"
test -z "$(git status --porcelain --untracked-files=no)"
test "$(git rev-parse HEAD:ios/OfflineTikTokPlayer)" = afe3a687be3ed2d905c5841950ee7877f218e647
test "$(git rev-parse HEAD:ios/PlayerCore)" = 859923fd7ca5fd3ea2689bf7b077e7f8af65fcb3
python3 scripts/generate-ios-project.py --check
mkdir -p artifacts/native
{
  printf 'UnsignedReleaseCompile schema=1 candidate=%s configuration=Release sdk=iphoneos testsRun=false signing=false upload=false runtimeAcceptance=false\n' "$candidate"
  git rev-parse HEAD HEAD:ios/OfflineTikTokPlayer HEAD:ios/PlayerCore
  xcodebuild -version
  xcrun --sdk iphoneos --show-sdk-version
} | tee artifacts/native/release-identity.log
python3 ../harness/scripts/run-owned-xcodebuild.py --phase release-build -- xcodebuild \
  -project ios/OfflineTikTokPlayer.xcodeproj -scheme OfflineTikTokPlayer \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath artifacts/UnsignedReleaseDerivedData -jobs 1 \
  -resultBundlePath artifacts/native/UnsignedRelease.xcresult \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build 2>&1 | tee artifacts/native/xcodebuild-release.log
test -f artifacts/UnsignedReleaseDerivedData/Build/Products/Release-iphoneos/OfflineTikTokPlayer.app/OfflineTikTokPlayer
file artifacts/UnsignedReleaseDerivedData/Build/Products/Release-iphoneos/OfflineTikTokPlayer.app/OfflineTikTokPlayer | tee artifacts/native/release-product.log
