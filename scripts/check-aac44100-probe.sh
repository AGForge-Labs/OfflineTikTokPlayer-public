#!/usr/bin/env bash
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p artifacts/native
export SWIFTC_MAXIMUM_DETERMINISM=1
echo 'AACNativeRateCapability scope=macOS-only rate=44100 channels=2 currentReader=native44.1-and48k expectedAdmission=true iOSAcceptance=false playbackAcceptance=false'
swiftc -parse-as-library -O -j1 scripts/probe-aac44100-file.swift \
  ios/OfflineTikTokPlayer/Playback/NativeAudioFileReader.swift \
  ios/PlayerCore/Sources/PlayerCore/AudioFilePresentation.swift -o artifacts/native/aac44100-probe
artifacts/native/aac44100-probe 2>&1 | tee artifacts/native/aac44100-probe.log
