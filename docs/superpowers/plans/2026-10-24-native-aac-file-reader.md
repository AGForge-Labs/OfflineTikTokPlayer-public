# Native AAC File Reader Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline in the existing isolated gapless-integration worktree. Steps use checkboxes. Do not start another review sweep or duplicate agents.

**Goal:** Remove the observed AVAssetReader sample-queue wait for conservatively eligible cached AAC files without changing their samples, timeline, rendering budget, cloud fallback or playback intent.

**Architecture:** Keep the persistent renderer and three lane/lease ownership model. An eligible native 48 kHz stereo AAC file can use AVAudioFile within its existing serial lane; all other descriptions retain NativeReader. Eligibility must prove a single uniform full audio segment and agree with the file packet table, native duration and processing format. No mid-stream reader substitution.

**Tech Stack:** Swift, AVFoundation/AVFAudio, AudioToolbox, existing C++ renderer and existing unsigned Mac workflow.

**Spec:** Existing 2026-10-24-gapless-playback-repair.md; user requires seamless next/previous/repeat-one and original media quality while preserving streaming, Audio only, background/PiP and private delivery.

## Global Constraints

- Original 3s preparation and 250ms first-visible-frame guards stay.
- Prefix96000/ring192000/3slots and renderer6912000bytes stay.
- No content trimming, sample padding to force agreement, tolerance relaxation or increased buffers.
- Source media and full playback-release evidence remain required; Mac API proof is not iOS/phone acceptance.
- Manual standard-public macos-26,15min unsigned jobs only; no signing/secret/billing changes.
- Preserve every existing profile identity and default/full release gate.
- Keep complete current/next/previous semantics, latest explicit Pause authority, cache/Saved distinction and fresh remote fallback.

## Review Focus

1. Movie edits and leading silence must retain the original presentation.
2. Native EOF or a truncated read must not fabricate frames or become a silent successful read.
3. Far seeks and retained Previous must preserve complete source samples and bounded decode work.
4. Readers/SDK objects must remain lane-owned through real close; no cross-thread cancellation or unacknowledged fixture removal.
5. Mono,44.1kHz,SRC,ALAC,MP3,multiple audio tracks and unsupported packet tables must retain their existing path.

### Task 1: Verify exact eligibility operands

**Files:** scripts/probe-audio-file.swift; docs/diagnostics/integration-status.md.

- [x] Preserve baseline native18 actual wait stack, original real silence and deadlines.
- [x] Diagnose the new comparison's extra-EOF-read defect with successful frame/position counts.
- [x] Compare full native48k stereo output: Mac22 all1440000frames, maximum sample difference0 in both modes.
- [x] Record original AVAssetTrack segment mapping and AudioFilePacketTableInfo valid/priming/remainder fields in the same bounded standalone Mac probe. Mac23 shows sourceStart1024/48000, uniform30s, targetStart0, valid1440000/priming1024/remainder768.
- [x] Require those fields to establish the same complete presentation; reject unknowns. Both complete stereo comparisons still have maximumDifference0.

### Task 2: Add a conservative lane-owned reader

**Files:** ios/OfflineTikTokPlayer/Playback/ContinuousPCMDecoder.swift; ios/OfflineTikTokPlayer/Playback/NativeAudioFileReader.swift; ios/PlayerCore/Sources/PlayerCore/AudioFilePresentation.swift; ios/PlayerCore/Tests/PlayerCoreTests/AudioFilePresentationTests.swift.

**Interfaces:** Private NativePCMReading exposes totalFrames:Int64, reachedEnd:Bool and read(into:AVAudioPCMBuffer,maximumFrames:Int)throws->Int. ReaderLane owns the selected implementation and its existing4096frame buffer. NativeReader continues unchanged behind that interface. Description carries only preloaded, validated timing eligibility.

- [x] Pin policy rejection for scaled/offset/trimmed/incomplete layouts and mismatched packet tables. Canonical RED observed; two focused tests and full125core pass. Metadata adapter separately rejects unknown/multiple/empty/non-AAC/non-native layouts.
- [x] Restrict initial admission to one enabled native48k stereo AAC track and one complete unscaled segment. Match segment source start to codec priming and the full valid-frame interval to declared native presentation.
- [x] Validate AudioFile packet table, file.length and exact requested Float32 processing format before choosing this path; otherwise use existing NativeReader.
- [x] Keep AVAudioFile ownership on ReaderLane; preserve debug copy-gate/stages. Source implementation complete; full iOS ownership/close validation remains Task3.
- [x] Bound each read by min(4096,maximumFrames,remainingDeclaredFrames); return0 only at the exact declared endpoint. Ordinary read errors, zero progress and unexpected position/count fail. Actual optimized component passes Mac24.
- [x] Runtime retains owned4096frame packets and all existing ring/prefix budgets; only synthetic reference tests hold complete PCM arrays.

Ruling: Put the small lane-owned SDK reader in its own source file behind NativePCMReading. This keeps its responsibility focused and permits compiling and exercising the exact component source in a small Mac probe before a full iOS build. AudioFilePresentation.matches(primingFrames:validFrames:presentationFrames:) is the pure policy. NativeAudioFileReader.open(url:totalFrames:readStartFrame:matchesPacketTable:) consumes the validated mapping and owns its file; ReaderLane still owns its lifetime. No broad decoder restructure.

### Task 3: Verify the actual candidate

**Files:** ContinuousPCMDecoderTests.swift; existing selection-video tests; tests/playback-acceptance.json; temporary public workflow.

- [ ] Reuse complete independent native48k sample comparison and distant seek/retained head regressions.
- [ ] Include the existing edited-offset test so leading presentation silence is exercised with the fallback.
- [ ] Restore the public workflow's original focused iOS command byte-for-byte from artifacts/gap-profile-before-audio-file-probe.yml after small API experiments.
- [ ] Run one changed-source native profile; preserve every prior case and original budgets.
- [ ] Preserve failures and distinguish app/runtime repair from simulator nonrecurrence or changed sampler history.
- [ ] Complete full Release/current-source gate and native build before any owner-only delivery.
- [ ] Full original HTTP/cache/background/PiP and owner's phone acceptance remain open. No goal completion based on a smaller green probe.
