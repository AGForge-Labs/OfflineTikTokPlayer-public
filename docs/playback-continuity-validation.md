# Playback continuity and speaker validation

Baseline: public `112b1cc4cbf350a9bd914fa28b9b3f3d2b7b8564`.

## Independent review follow-up

Read-only independent review found three concrete defects: a user scrub could supersede the paused startup seek without inheriting its resume intent; the controller evicted the retained Previous item's mix bookkeeping; and coalesced queue callbacks could miss the loop reserve. The follow-up shares one generation/timeline/intent-guarded seek completion, supplies all bounded retained items to the audio controller, and reconciles the actual current or drained prepared item. Review also caught the two-item replenishment window and the distinction between draining prepared items and exhausting the metadata playlist. Recovery now continues a longer playlist only with playback permission and preserves explicit Pause/interruption across deferred continuation. A final focused static review found no further concrete regression.

Reviewed production source `2dc6625a332980aabdf2c88c9c8b1fe32ffa46c0` passes [native run 39326804950](https://github.com/AGForge-Labs/OfflineTikTokPlayer-public/actions/runs/39326804950): **69 Mac core, 40 native and one UI test**, plus the actual Apple-framework previous/coalesced-boundary check. The coalesced-boundary reproduction first failed on unchanged production code in [run 39324775936](https://github.com/AGForge-Labs/OfflineTikTokPlayer-public/actions/runs/39324775936), then passed after correction. The new longer-queue integration regression covers normal continuation, interrupted continuation with resume permission, and explicit Pause followed by Play.

**Final validated head:** `f82492795c100cfc27e2faa0c1444a53d6f36c5f`, [native run 39327742516](https://github.com/AGForge-Labs/OfflineTikTokPlayer-public/actions/runs/39327742516). Production source is identical to `2dc6625`; the test-only follow-up adds a counterbalanced Original/speaker comparison. The Apple-framework checks, **69 core, 40 native and one UI test pass** on Xcode 26.6 / iOS 26.5 Simulator.

The original Previous timing fixture bypassed the service/session/controller and waited for 100 ms of clock progress, while the original Next fixture waited for 50 ms and marked its local URL remote. Those historical values are not a controlled comparison. The final service benchmark uses three serial trials **per mode** of the same Saved source, built-in-speaker policy, session activation and 50 ms threshold for cold/Next/Previous. Mode order alternates; mix identity and per-item track-load counts are recorded across reversal. A two-second fixture watchdog detects a stall; passing it does **not** accept immediate playback performance.

| Final production-service clock timing | Speaker sound median (range) | Original median (range) |
| --- | ---: | ---: |
| Cold, until 50 ms progress | 506 ms (498–660) | 299 ms (283–321) |
| Prepared Next, same threshold | 571 ms (524–583) | 390 ms (328–410) |
| Retained Previous, same threshold | 533 ms (502–721) | 325 ms (308–357) |

Speaker processing adds roughly 180–210 ms to these median **simulator clock** results. This comparison isolates the presence of the processing mix; it does not isolate DSP CPU cost from AVFoundation's processing/output path, and it does not establish hardware audible latency. Original sound also retains startup delay. No consistent immediate manual transition is demonstrated, and this issue remains open. No automatic preference change hides the tradeoff.

Across the final manual transitions, session activation takes 0.15–3.28 ms, prepared-item adoption 1.94–8.67 ms, and first-frame callbacks 96–177 ms. The clock threshold arrives substantially later. Previous reuses the same mix in all enhanced trials, with exactly one track load for that retained item; Original uses no mix or track load. Each measured handoff retains two items; the separate stress/loop regressions enforce the four-item maximum. These phases narrow the remaining question to the platform playback/output path rather than repeated URL lookup or mix construction. A phone trace is the next evidence needed before changing the audio architecture.

Final complete 1.2-second loop ends are 1.2010/1.2018/1.2015 seconds, with corrected clock-gap estimates +0.024/-6.106/+3.859 ms. The decoded source still has 1 ms leading below -60 dB and no measured trailing interval. All source content is retained; this is not a physical audible-gap measurement.

## Instrumented device plan and remaining acceptance

The service emits fixed OS signpost phase names for Instruments: subsystem `OfflineTikTokPlayer`, category `Playback`. Events include `start`, `next`, `previous`, activation request/completion/failure, load request, cold audio prepared, prepared adoption, item ready, seek request/completion, first frame, playing/waiting, clock reaching 50 ms, and interruption begin/end permission. Only generation and retained-item count are logged; no media identifiers, URLs, titles, cookies or credentials. There is no persistent event array or new access permission. The native benchmark additionally collects bounded, numerical per-trial phase traces in its test result.

These are callback observations, not hardware output timestamps. A playing event or clock progress does not prove the first PCM sample reached the speaker. A restored/nonzero seek can already exceed 50 ms; use that milestone only for the zero-start trials. Do not interpret delayed observer delivery as silence or subtract 50 ms and call the result audible startup.

The next useful experiment requires an actual iPhone and an authorized device candidate; Windows and the unsigned simulator cannot exercise a competing camera app's session or measure phone speaker output. No signing or candidate release is performed here. Minimal handoff: coordinate the validated commit through the existing device build process, then run one Saved-clip sequence (cold, Next, Previous, ten loops) and a competing scan/photo interruption. Record iPhone model/iOS version, route, Speaker sound choice and source privately.

For a developer-assisted measurement, capture those OS signposts plus Time Profiler/Allocations on that phone while recording the screen/touch and physical speaker with an external recorder. Align action and frame timestamps to the trace; compare the captured waveform with a decoded copy of the exact source, reporting its leading/trailing silence separately. Report action-to-first-frame, action-to-first-audible-source, added loop silence, interruption position/resume and memory before/after 100 reversals. Repeat with Original sound and headphones/Bluetooth. Keep source media and work-app screen data private. Physical output, route effects, RSS and immediate-transition acceptance remain open until this evidence exists.

## Earlier validated implementation and historical measurements

**Validated implementation:** `12dcdf45d830984d07b6b379bf06b59ef75c019d`, [public native run 39321683428](https://github.com/AGForge-Labs/OfflineTikTokPlayer-public/actions/runs/39321683428). The real Apple-framework previous-preparation check, **69 Mac core, 35 native and one UI test all pass** on Xcode 26.6 / iOS 26.5 Simulator. The final Saved-copy automatic-handoff integration regression passes. Local Python/adapter/project/syntax/workflow evidence is below. No private signing or release occurred.

| Final synthetic measurement | Result | Interpretation |
| --- | ---: | --- |
| Cold / queued Next clock advancement | 854 / 379 ms | One local-fixture run; earlier runs vary, so no universal speedup claim |
| Cold / retained Previous clock advancement | 189 / 241 ms | Previous was rewound before handoff; no demonstrated Previous speedup |
| Cold optional speaker setup | 102 ms | 100 ms deadline, instead of the former 500 ms allowance |
| Corrected loop clock-gap estimates | +0.016 / -6.083 / +3.839 ms | Clock/notification estimates, not audible-gap measurements |
| Completed 1.2-second item times | 1.2011 / 1.2009 / 1.2006 s | Source ends retained |
| Source intervals below -60 dB, leading / trailing | 1 / 0 ms | Preserved, never automatically trimmed |
| Native speaker tap gain / sample count | +9.250 dB / 52,920 unchanged | Real PCM processing of a quiet fixture, not physical speaker loudness |

The queued item still reports not-ready before explicit handoff in this simulator fixture. Data/metadata preparation, off-screen rewind and the shortened cold setup are verified. Remaining delay occurs during AVFoundation handoff; activation/decoder/output startup is a plausible explanation, not a device-profiled diagnosis. Real-library first-audio/first-frame timing and physical-device profiling are required before claiming the reported manual latency problem is resolved. Source is ready for independent review; device performance acceptance and private candidate/release coordination remain separate.

## Behavior and review scope

- `PlaybackIntent` separates user intent, interruption state and successful session activation. Duplicate begins preserve resume intent. Pause cancels it. Automatic resumption requires a matching end with `shouldResume` and successful reactivation. Readiness, seek completion, end callbacks and stall recovery use the same permission gate. Foregrounding does not invent resume permission; explicit Play recovers a missing end notification.
- `PlaybackService` requests `.playback` with `.mixWithOthers`, retaining background-audio support. A competing exclusive camera/recording session can still stop audio. No retries attempt to seize that session. OS volume is unchanged.
- `PlaybackBuffer` keeps the persistent queue player and prepares full-duration successor items, including repeat-one duplicates. Natural advancement crosses the prepared boundary instead of waiting to restart with a zero seek. Explicit Next still skips repeat-one. One previous item is retained and rewound off-screen; a matching guarded rewind remains the fallback when preparation has not finished. Preparation is tied to current identity and generation; gestures defer natural advancement and the final queue item remains visible and paused. Local prepared files use immediate-start policy; HTTP items retain automatic stall recovery. Automatic handoff applies the same Saved/offline eligibility rule as manual handoff.
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

[Third native run](https://github.com/AGForge-Labs/OfflineTikTokPlayer-public/actions/runs/39316383570), source `55237bb`, passed 69 core, 33 native and one UI test. The bounded three-item loop queue retained complete 1.2-second source items and logged raw callback offsets of 7.51/7.34/6.40 ms. Explicit skip, the four-item maximum including history, and independent speaker mixes passed. Cold/queued timing was 0.405/0.418 seconds, and cold/retained-previous timing was 0.197/0.228 seconds. These local-fixture values do not establish a consistent manual-transition speedup; final source moves previous rewind off-screen and shortens cold optional speaker setup instead of claiming otherwise.

[Fourth native run](https://github.com/AGForge-Labs/OfflineTikTokPlayer-public/actions/runs/39318347442), source `33f65a7`, passed the real Apple-framework previous-preparation gate, 69 core, 34 native and one UI test. The retained ready item moved silently from 0.4 to 0 seconds before handoff on macOS, and iOS also confirmed `rewindPreparedBeforeHandoff=true`. The cold optional speaker deadline returned in 102 ms. Corrected loop-clock gap estimates were +0.062/-6.091/+3.838 ms with full item ends at 1.2029/1.2041/1.2023 seconds. Negative estimates reflect clock/notification uncertainty, not measured negative silence. The source retains its 1 ms leading interval below -60 dB and no measured trailing interval; no trimming occurs. Cold/queued clock timings were 0.418/0.385 seconds, and cold/retained-previous timings were 0.221/0.242 seconds. The small local fixture still does not establish a consistent manual-transition speedup or physical audible latency.

Final review also applies Saved/offline eligibility to automatic handoff, matching the existing manual handoff rule. Its integration regression emulates a remote stage resolved before the Saved copy became available and verifies that the service loads the verified Saved URL. An intermediate follow-up run on `8fd843a` stopped at compilation because an optional injected-buffer parameter shadowed the stored property; the stored-property reference was corrected before rerunning the full check.

The public unsigned simulator check runs the existing suites plus interruption/readiness gating, activation failure, foreground handling, complete-source loops, automatic advancement, explicit repeat skip, queue exhaustion, rapid forward/backward reuse, stale preparation, speaker fallback recovery and retained-item bounds.

Timing logs separate cold/queued/retained-previous **playback-clock** advancement from natural loop scheduling. Loop clock-gap estimates subtract the arriving item's already-advanced playback position from the raw callback offset; raw offsets and arriving positions are also retained for inspection. The loop test decodes the entire synthetic source and reports leading/trailing samples below -60 dB separately from those clock estimates. It never trims that silence. These tests do not measure speaker-output latency or audible gaps.

Physical iPhone acceptance remains required:

1. Play a Saved clip, then stream a clip. Switch to a work app and repeatedly open its scan/photo camera, take photos, dismiss it and return. Record whether iOS allows mixing, delivers begin/end and `shouldResume`, and whether playback resumes from the interrupted position. Repeat after an explicit pause during interruption; it must remain paused. Test activation refusal, a missing end and explicit Play recovery.
2. Compare complete source audio with at least ten repeat boundaries. Measure encoded leading/trailing silence and listen for added player silence or omitted tail content. Do not remove real source content to hide a gap.
3. Compare cold open, prepared Next and prepared Previous after several seconds of playback, then make 100 reversals and shuffle/repeat changes. Only the selected clip may play. Include offline handoffs, queue exhaustion, low memory, background/foreground, lock screen and PiP. Measure audible/first-frame latency and process footprint on the actual phone.
4. Compare identical sources and system volume with Speaker sound on/off, including quiet music, bass-heavy loud music and already clipped sources. Listen for distortion and pumping. Repeat through loop/queue boundaries and interruptions. Connect/disconnect headphones and Bluetooth during preparation and playback: enhancement must bypass those routes and return only on the built-in speaker.

No signed build, TestFlight assignment, account change or release is part of this change.

References: [Apple interruption guidance](https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/HandlingAudioInterruptions/HandlingAudioInterruptions.html), [Apple mixing/background configuration](https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/AudioSessionBasics/AudioSessionBasics.html), [AVQueuePlayer](https://developer.apple.com/documentation/avfoundation/avqueueplayer), [Apple loop replicas and full-duration ranges](https://developer.apple.com/documentation/avfoundation/avplayerlooper/init(player:templateitem:timerange:)), [GitHub standard public runner billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions).
