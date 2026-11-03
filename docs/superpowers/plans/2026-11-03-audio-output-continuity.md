# Audio output continuity implementation plan

> **For agentic workers:** Use superpowers:executing-plans to implement the following tasks inline.

**Goal:** Recover the current audio automatically after a transient output/session failure, preserving playback intent, position, looping and PiP.

**Architecture:** Keep the existing PCM renderer and prepared sources. Reactivate the audio session before restarting an output affected by a configuration/route change; retry transient failures with bounded frequency while the user still wants playback. Repair a genuinely stalled output without selecting another track. Continue to honor explicit Pause, interruption resume denial and disconnected headphones.

**Tech stack:** Swift, AVAudioSession, AVAudioEngine, AVKit, XCTest; standard public macOS runners only.

**Spec:** User report on November 3: TestFlight26.1 becomes silent during keyboard/other-app use, visible or tucked-away PiP, and repeated in-app looping. Video/progress continues. Pause/Play or Next/Previous restores sound.

## Constraints and evidence

- Base implementation on delivered public source30c1a5d36da393743cd3155ac991a2221eb7a7bc in the existing public linked checkout; preserve pre-existing private-workspace changes.
- Keep original media, queue/shuffle/history, source/visit ownership and the existing audio quality processing.
- No periodic restarts of healthy playback; no waveform-based restart on legitimate quiet passages.
- A running flag alone cannot establish that the output is healthy. Conversely, advancing PCM does not establish audible physical output.
- Configuration recovery currently omits session activation; an engine-start failure clears session permission, and the watchdog then refuses recovery. The media-reset handler explicitly clears user intent. Prove these branches before fixing them.
- The user's moving video/progress may represent an additional output/session failure. Request the existing on-device diagnostics report; do not claim those physical events were reproduced by simulator notification tests.
- Public source/free unsigned checks and existing protected owner-only TestFlight delivery are authorized. Add no credentials, testers, billing or security changes.

## Task 1: Reproduce and repair output recovery

Files: `ios/OfflineTikTokPlayerTests/AudioOutputContinuityTests.swift`, `ios/OfflineTikTokPlayer/Playback/PlaybackService.swift`; if needed, the existing continuous-audio player/graph.

- [ ] Add native behavior tests requiring session reactivation before a stopped configured output restarts, automatic recovery after one engine-start failure, and preserved intent after media reset.
- [ ] Add controls for explicit Pause, denied interruption resumption, current-source ownership and sustained real source-node output across many loops.
- [ ] Run the failing tests against unchanged26.1 production source on one standard public Mac job. Validate actual named assertion failures; reject compile/fixture failures as reproduction.
- [ ] Implement one coalesced, throttled recovery path. Reactivate the session before starting the current output, retain demand after transient failure, and recheck ownership/intent after SDK calls.
- [ ] Recover stale output progress with the same renderer/selection; keep decoder starvation separate from a dead output and preserve genuine paused/ended states.
- [ ] Run the new controls plus relevant existing interruption/PiP/presentation/graph tests and the full portable core suite on one standard public Mac job. Verify native results strictly and retain any failures.
- [ ] Independently review the code and validation.

## Task 2: Deliver the verified candidate

- [ ] Verify exact app/core/source and the successful new native receipt with existing release safeguards.
- [ ] Check Apple's actual latest build and make one protected owner-only upload through the existing public workflow.
- [ ] Require actual VALID/INTERNAL_ONLY/onlyApprovedOwner/assigned receipt before saying ready.
- [ ] Record simulator/native and phone evidence separately. Keyboard, other-app, tucked PiP and long-loop acceptance require the phone; use the requested diagnostics to resolve any continuing silence.
