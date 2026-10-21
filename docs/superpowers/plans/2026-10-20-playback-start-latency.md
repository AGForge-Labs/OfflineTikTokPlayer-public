# Playback start and transition latency investigation

**Goal:** Investigate the reported continuing silence/loading delay without assuming the owner's installed build; 14.1 has not uploaded.
**Baseline:** Public main `08fba4fd9bc49fa62d268ccbd37d10ccc8074886`; shipped rollback 12.1 tree `01664b0f0bb49a9eeead83586542fb2fc942d636` remains read-only.
**Approach:** Measure cold load, prepared selection/return, natural boundaries and presentation recovery separately. Use independently identifiable synthetic tones, actual engine-output samples and actual video pixels. Prior zero PCM-underrun evidence does not establish output or visual latency.
**Constraints:** One serial low-resource worker; public fixtures only; no merge, signing, upload, release dispatch or environment change. Preserve all source frames/silence and private user data.

- [x] Read current instructions, prior acceptance evidence and relevant current/shipped paths.
- [x] Run the portable baseline: 83 tests pass with one Swift job.
- [x] Add native request-to-output/first-frame measurements and reproduce a failure before changing production behavior.
- [x] Isolate the redundant aligned-seek path and implement that demonstrated correction.
- [ ] Isolate recurrent producer starvation in the exact positive-offset natural-transition capture before another production fix.
- [ ] Verify regression identity, pixels, output continuity, intent, queue endings and resource bounds without relaxing thresholds.
- [ ] Obtain independent review and publish exact before/after evidence and remaining physical-device limits.

Initial supported paths: current cold selection does not attach the video item until precise PCM preparation finishes. Prepared video selection also performs composition/output setup on selection and a forced exact seek on its first audio-render visit; that seek removes the displayed frame and blocks pulls. These are hypotheses about measured latency, not a diagnosis of the unknown installed build.

Measured baseline `ed11c712684aeb175d2d2b21eb22cc8257c48a7c`, run `39503751284`: prepared Next/Previous readiness 379.12/305.49 ms failed unchanged 250 ms targets; independent engine tone windows ended 42.33/42.20 ms after commands, with no detected 10 ms silence or host-timeline holes. Previous performed a 280.93 ms exact seek despite only 0.208 ms drift. The focused correction prepares the existing local composition before staging and avoids that redundant aligned selection seek. Cold/relaunch file verification and actual phone output remain outside these fixture measurements.

First corrected source `68ee696`, run `39507305343`, still failed the unchanged limits (Next306.67ms, Previous623.12ms, natural286.18ms); no silence/timestamp holes appeared in the captured output. It is not accepted. Next experiment: avoid an unnecessary compositor only for verified ordinary identity geometry; preserve transformed/aperture/pixel-aspect normalization, and require current-epoch PTS in timing checks. A separate simulator screenshot timeout also remains a hard failure.

The authorized 2026-10-21 follow-up targets `natural-B-positive-offset-motion-start`: explicit audio injection and a bounded full-capture producer trace on the original failing case, plus fresh matched natural-handoff arms with/without capture and with/without native tracing. All arms retain the original far seek, conditional main-actor stall and natural-advance policy. The independent sampler is common to the four arms; native tracing controls its write overhead. Keep the existing first-eight-second coverage/progress contract, add a 24-second shared observation, and retain up to 45 seconds/512 numeric records for a long capture's later tail. Record snapshot acquisition times and per-slot accepted frames. No production playback decision changes precede a supported cause; use one unsigned standard Mac validation worker.

The first targeted run `39521161328` failed. Its fourth arm never completed A's cold far-seek setup and therefore cannot measure a B transition. Abort the helper on that failed guard. Coherent phase-5 records narrowed the incomplete seek to the native reader-copy scope but cannot distinguish an SDK wait from descheduling. Next collect at most two one-second, exact-app native-worker stack samples on CI, triggered only after that failed setup or a new underrun in the exact natural observation. Preserve every existing acceptance assertion and separate timing before and after profiling. A missing/protected host sampler is an explicit diagnostic limitation, not grounds to infer a cause or relax coverage.

The failure-trigger run `39523799825` wrote no request: capture arms failed an earlier three-second preparation guard, while no-capture arms had no new underruns. Extend the same bounded request to that failed guard and keep the failed fixture alive for a seven-second diagnostic grace. Preserve its failure and unconditional abort. Give each decoder an opaque UUID queue label and require that exact label in the request/filter, preventing attribution to a retained earlier fixture. Rerun the full unsigned validation; no production playback policy change precedes a supported cause.
