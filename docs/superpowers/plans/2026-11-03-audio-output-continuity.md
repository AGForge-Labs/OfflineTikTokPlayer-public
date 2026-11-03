# Audio output continuity implementation plan

> **For agentic workers:** Use superpowers:executing-plans to implement the following tasks inline.

**Goal:** Recover the current audio automatically after a transient output/session failure, preserving playback intent, position, looping and PiP.

**Architecture:** Keep the existing PCM renderer and prepared sources. Reactivate the audio session before restarting an output affected by a configuration/route change; retry transient failures with bounded frequency while the user still wants playback. Repair a genuinely stalled output without selecting another track. Continue to honor explicit Pause, interruption resume denial and disconnected headphones.

**Tech stack:** Swift, AVAudioSession, AVAudioEngine, AVKit, XCTest; standard public macOS runners only.

**Spec:** User report on November 3: TestFlight26.1 becomes silent during keyboard/other-app use, visible or tucked-away PiP, and repeated in-app looping. Video/progress continues. Pause/Play or Next/Previous restores sound.

## Constraints and evidence

- Base implementation on delivered public source30c1a5d36da393743cd3155ac991a2221eb7a7bc in the existing public linked checkout; preserve pre-existing private-workspace changes.
- Keep original media, queue/shuffle/history, source/visit ownership and the existing audio quality processing.
- Latest user steering: minimize Codex usage; fix audio only. Preserve current gaps/buffering and video playback; defer all gap optimization. Do not change the renderer, decoder, DSP, video clock, paging or PiP presentation implementation.
- No periodic restarts of healthy playback; no waveform-based restart on legitimate quiet passages.
- A running flag alone cannot establish that the output is healthy. Conversely, advancing PCM does not establish audible physical output.
- Configuration recovery currently omits session activation; an engine-start failure clears session permission, and the watchdog then refuses recovery. The media-reset handler explicitly clears user intent. Prove these branches before fixing them.
- The user's moving video/progress may represent an additional output/session failure. Request the existing on-device diagnostics report; do not claim those physical events were reproduced by simulator notification tests.
- Public source/free unsigned checks and existing protected owner-only TestFlight delivery are authorized. Add no credentials, testers, billing or security changes.

## Task 1: Reproduce and repair output recovery

Files: `ios/OfflineTikTokPlayerTests/AudioOutputContinuityTests.swift`, `ios/OfflineTikTokPlayer/Playback/PlaybackService.swift`; if needed, the existing continuous-audio player/graph.

- [x] Add native behavior tests requiring session reactivation before a stopped configured output restarts, automatic recovery after one engine-start failure, and preserved intent after media reset.
- [x] Add controls for explicit Pause, denied interruption resumption, current-source ownership and sustained real source-node output across many loops.
- [x] Run the failing tests against unchanged26.1 production source on one standard public Mac job. Validate actual named assertion failures; reject compile/fixture failures as reproduction.
- [ ] Implement one coalesced, throttled recovery path. Reactivate the session before starting the current output, retain demand after transient failure, and recheck ownership/intent after SDK calls.
- [ ] Keep the existing stopped-output watchdog; route its restart through guarded session recovery. Defer speculative running-graph rebuilding because advancing physical silence is not established by frozen PCM alone.
- [ ] Run 18 focused native controls, including existing next/previous/repeat, exact output samples, HD picture cadence and rapid reversals. Reuse the previously verified, byte-identical Coref9 proof; rerun its suite only if Core changes. Verify results strictly and retain any failures.
- [ ] Independently review the code and validation.

## Task 2: Deliver the verified candidate

- [ ] Verify exact app/core/source and the successful new native receipt with existing release safeguards.
- [ ] Check Apple's actual latest build and make one protected owner-only upload through the existing public workflow.
- [ ] Require actual VALID/INTERNAL_ONLY/onlyApprovedOwner/assigned receipt before saying ready.
- [ ] Record simulator/native and phone evidence separately. Keyboard, other-app, tucked PiP and long-loop acceptance require the phone; use the requested diagnostics to resolve any continuing silence.

## Validation ledger

- Baseline sourcef398e47f88c3deb215449e56878d4b76ba455931, native run41725470545/job126228976888: production App3a7a7c5/Coref9b2096 unchanged from26.1. Compilation succeeded. The three expected tests failed on session activation ordering, automatic retry after engine-start failure, and lost playback intent after media reset. The failures occurred after each test established actual PCM playback, with no initial fixture/compilation failure.
- Explicit Pause/resume-denial controls passed. Real AVAudioSourceNode output across1000 loops/100 seconds of offline-rendered media passed: minimum RMS0.101525833 and zero underruns. This does not prove audible phone output or reproduce typing/other-app arbitration.
- The scoped patch changes session/retry policy in PlaybackService and adds one read-only control-revision accessor in ContinuousAudioPlayer. Its renderer, decoder, DSP, frame scheduling, paging and PiP presentation code remain byte-identical. No running-graph rebuild heuristic or gap optimization is included.
- Local project-generation, workflow Bash/YAML/inline Python, all18 source identities, and valid/five invalid native-log controls pass. The existing strict case-verifier implementation is unchanged; its native-only API avoids adding unrelated UI tests.
