# Playback continuity and speaker validation

Baseline: public `112b1cc4cbf350a9bd914fa28b9b3f3d2b7b8564`.

## Behavior and review scope

- `PlaybackIntent` separates user intent, interruption state and successful session activation. Duplicate begins preserve resume intent. Pause cancels it. Automatic resumption requires a matching end with `shouldResume` and successful reactivation. Readiness, seek completion, end callbacks and stall recovery use the same permission gate. Foregrounding does not invent resume permission; explicit Play recovers a missing end notification.
- `PlaybackService` requests `.playback` with `.mixWithOthers`, retaining background-audio support. A competing exclusive camera/recording session can still stop audio. No retries attempt to seize that session. OS volume is unchanged.
- `PlaybackBuffer` keeps the persistent queue player and prepares full-duration successor items, including repeat-one duplicates. Natural advancement crosses the prepared boundary instead of waiting to restart with a zero seek. Explicit Next still skips repeat-one. One previous item is retained and rewound off-screen; a matching guarded rewind remains the fallback when preparation has not finished. Preparation is tied to current identity and generation; gestures defer natural advancement and the final queue item remains visible and paused. Local prepared files use immediate-start policy; HTTP items retain automatic stall recovery.
- Resource policy: normally two queued items plus one retained predecessor; repeat-one keeps a third full-duration loop replica prepared (four retained items including history). An eight-second preferred forward-buffer hint and the existing verified temporary-file cache capped at 256 MiB / eight files / two transfer reservations remain in place. Memory warnings discard queued preparation and history without deleting Saved media. AVFoundation manages its internal decoder buffers; these item/cache bounds are not a measurement of physical-device RSS.
- `SpeakerAudioController` retries a failed optional metadata preparation once the item is ready, instead of treating a missing mix as configured forever. Cold explicit selections cap optional EQ preparation at 100 ms instead of 500 ms; advance preparation retains its 500 ms budget. Route changes and Original sound invalidate pending work. Headphones, Bluetooth and AirPlay bypass enhancement.
- `SpeakerAudioProcessor` extends the bass shelf from 160 Hz / 4 dB to 220 Hz / 5 dB and raises maximum quiet-material makeup from 6 to 9 dB. Linked crest holding avoids flattening successive bass peaks. A 0.89 sample ceiling provides about 1 dB headroom. No samples are delayed, trimmed or re-encoded. This remains a sample-peak limiter, not a true-peak guarantee.

The change also updates focused core/native regressions, generated project references, and one-job validation scripts. The public workflow is restricted to this public repository and branch, uses a standard runner and no signing secrets, and uploads no artifacts or caches. Documentation-only pushes do not run it. The production archive draft remains inactive.

## Local evidence

The full local preflight passes: **204 Python, 69 Swift core and eight real cloud/refresh adapter tests**, generated Xcode references, native Swift parsing and workflow controls. The initial run with the system Python lacked helper dependencies and loopback permission; the complete rerun uses the existing equipped helper environment and passes without source changes to those unrelated tests.

Measured with production DSP at 44.1 and 48 kHz, using a quiet 0.04-amplitude tone:

| Measurement | Baseline | Updated |
| --- | ---: | ---: |
| 1 kHz gain | 6.036 dB | 9.025 dB |
| 180 Hz relative to 1 kHz | 1.530 dB | 3.406 dB |

The sustained 100 Hz / 0.65-amplitude test measures **0.0145% THD+N** after settling. Tests also cover finite/linked stereo peaks, transient recovery, Original-sound bypass, no sample delay, seek resets and independent clip state. These electrical/synthetic measurements do not establish iPhone speaker loudness, true peak, or parity with another app.

## Native and physical evidence

[Initial native run](https://github.com/AGForge-Labs/OfflineTikTokPlayer-public/actions/runs/39312183144), source `a7a99c7`, passed 69 Mac core, 28 native and one UI test on Xcode 26.6 / iOS 26.5 Simulator. Its real audio tap preserved 52,920 source samples while increasing the quiet tone fixture by 9.250 dB (RMS 0.08836 to 0.25632). Cold/queued clock timing was 0.427/0.374 seconds, with the next item not ready before handoff. Full 1.2-second loop items finished at 1.2009, 1.2028 and 1.2024 seconds; raw callback offsets were 0.0046, 0.0924 and 0.0709 seconds. Those include incoming-item progress and notification delivery time; they are not measured silence. Decoded-source leading/trailing intervals below -60 dB were 0.001/0 seconds. Final instrumentation subtracts the arriving item's playback position and logs both quantities; a third full-duration replica also keeps the following loop boundary prepared.

The compiler also reports existing Swift 6 migration warnings in notification captures, PiP conformance, frame-monitor deinit and download-record captures; this project uses Swift 5 mode. The simulator reports unavailable hardware loudness support, reinforcing that PCM checks do not establish speaker performance. The pinned checkout action is forced onto Node 24 by GitHub with a deprecation warning; checkout and validation still passed.

[Second native run](https://github.com/AGForge-Labs/OfflineTikTokPlayer-public/actions/runs/39314211481), source `450cc26`, passed 69 core, 30 native and one UI test. Cold/queued clock timing was 0.407/0.395 seconds; the retained-previous fixture was 0.397 seconds including its foreground rewind versus 0.225 seconds cold. This was not a demonstrated previous-startup improvement. It motivated rewinding the one retained ready history item during preparation, with cancellation on eviction and a guarded foreground fallback. Raw loop callback offsets remained roughly 5/85/68 ms with the original two-item preparation; these do not establish audible gaps.

The public unsigned simulator check runs the existing suites plus interruption/readiness gating, activation failure, foreground handling, complete-source loops, automatic advancement, explicit repeat skip, queue exhaustion, rapid forward/backward reuse, stale preparation, speaker fallback recovery and retained-item bounds.

Timing logs separate cold/queued/retained-previous **playback-clock** advancement from natural loop scheduling. Loop clock-gap estimates subtract the arriving item's already-advanced playback position from the raw callback offset; raw offsets and arriving positions are also retained for inspection. The loop test decodes the entire synthetic source and reports leading/trailing samples below -60 dB separately from those clock estimates. It never trims that silence. These tests do not measure speaker-output latency or audible gaps.

Physical iPhone acceptance remains required:

1. Play a Saved clip, then stream a clip. Switch to a work app and repeatedly open its scan/photo camera, take photos, dismiss it and return. Record whether iOS allows mixing, delivers begin/end and `shouldResume`, and whether playback resumes from the interrupted position. Repeat after an explicit pause during interruption; it must remain paused. Test activation refusal, a missing end and explicit Play recovery.
2. Compare complete source audio with at least ten repeat boundaries. Measure encoded leading/trailing silence and listen for added player silence or omitted tail content. Do not remove real source content to hide a gap.
3. Compare cold open, prepared Next and prepared Previous after several seconds of playback, then make 100 reversals and shuffle/repeat changes. Only the selected clip may play. Include offline handoffs, queue exhaustion, low memory, background/foreground, lock screen and PiP. Measure audible/first-frame latency and process footprint on the actual phone.
4. Compare identical sources and system volume with Speaker sound on/off, including quiet music, bass-heavy loud music and already clipped sources. Listen for distortion and pumping. Repeat through loop/queue boundaries and interruptions. Connect/disconnect headphones and Bluetooth during preparation and playback: enhancement must bypass those routes and return only on the built-in speaker.

No signed build, TestFlight assignment, account change or release is part of this change.

References: [Apple interruption guidance](https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/HandlingAudioInterruptions/HandlingAudioInterruptions.html), [Apple mixing/background configuration](https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/AudioSessionBasics/AudioSessionBasics.html), [AVQueuePlayer](https://developer.apple.com/documentation/avfoundation/avqueueplayer), [Apple loop replicas and full-duration ranges](https://developer.apple.com/documentation/avfoundation/avplayerlooper/init(player:templateitem:timerange:)), [GitHub standard public runner billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions).
