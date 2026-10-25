# HTTP Playback Boundary Investigation Plan

> **For agentic workers:** Use superpowers:executing-plans inline in the existing gapless-integration worktree. Do not spawn implementer agents.

**Goal:** Exercise the actual network-to-temporary-cache playback path before changing audio transport to address silent boundaries.

**Architecture:** Serve only bundled synthetic MP4s from an ephemeral loopback HTTP range server owned by the XCTest. Use the real PlaybackService, PlaybackMediaCache, URLSession, AVPlayer and persistent PCM graph. Hold optional cache transfers until native HTTP playback advances; then verify warmed navigation and repeat without creating Saved copies.

**Tech Stack:** Swift, Network, AVFoundation, XCTest, existing unsigned Mac checks.

**Spec:** User requires seamless Next/Previous/repeat-one while streaming OneDrive without explicit phone downloads. Existing contracts and unresolved witnesses are recorded in docs/diagnostics/integration-status.md.

## Global Constraints

- Keep production source unchanged until a failing behavior identifies a cause.
- Preserve prefix96000/ring192000/3slots, renderer6912000bytes, cache256MiB, original timing guards and every existing acceptance identity.
- No production ATS exception, private catalog/account/media, trimming, synthetic padding, weaker silence oracle, signing or paid checks.
- Cold native-to-PCM ownership is not a measurement of the audio crossing that boundary. Report its limits explicitly.
- Native30's2068 stereo-zero frames remain unresolved; clean Native31 recordings do not erase that failure.

## Review Focus

- A cold stream must play before optional full-file caching is released.
- Warming must preserve an advancing native stream and leave Saved empty.
- Warm Next and Previous must select the right prepared audio on one persistent graph.
- Repeat-one must advance the same token's visit rather than restart the graph.
- HTTP requests, fixture cleanup and cancellation must be bounded and owned by this test.

### Task 1: Add a real HTTP integration regression

**Files:** Create ios/OfflineTikTokPlayerTests/HTTPPlaybackFixtureServer.swift; modify NativeStreamingPlaybackTests.swift and generated project; extend tests/playback-acceptance.json by one case.

- [x] Add a loopback-only server serving a fixed dictionary of bundled MP4 bytes. Support GET/HEAD, single byte ranges, explicit lengths, bounded headers and owned connection close.
- [x] Add testHTTPPlaybackWarmsTemporaryFilesAndKeepsNavigationAndRepeatOnOneGraph. Assert actual remote item URL, advancing native playback before releasing cache, cache hash/size verification, zero Saved copies, prepared PCM navigation, persistent engine and repeat-one visit advancement.
- [x] Run local Swift parsing, project generation check and all existing profile validation before a Mac run. Source review verifies loopback binding and fixed-file access; SDK/HTTP execution remains pending.
- [x] Run the full focused profile with the new identity once on the approved free public standard runner; retain artifacts and original failures. Native32 returned all75 identities:71pass/4fail; strict gate failed.

### Task 2: Act on the observed result

**Files:** Only the component shown to fail, its focused regression, and docs/diagnostics/integration-status.md.

- [x] If the network regression fails, classify whether HTTP/ATS, cache, transport ownership, preparation or repeat failed before modifying production code. Native32's counter baseline was unqualified; Native33's corrected observation passes without a runtime change.
- [x] If it passes, record the network coverage gained without claiming native-to-PCM sample continuity or phone acceptance. Native33 passes actual HTTP/ranges, verified temporary cache, warmed navigation and natural repeat; cold native-to-PCM sample joining remains unmeasured.
- [ ] Retain complete loop recordings on any recurrence. Resolve Native30 from failing-window evidence rather than a clean retry.
- [ ] Keep full Release, TestFlight and phone acceptance open until actually run.

## Execution ledger

- Base private24241c3/publica78105c; both production app/core trees unchanged since Native30.
- Local independent Native31 analysis decoded retained Zstandard attachments with the existing libzstd library. Both633600-frame recordings match the57600-frame reference exactly (maximumDifference0); all512 source-zero pairs are the final deliberate paused callback. coverageClosed=false/formalRTJoin=false remain. Scope is only these clean windows, not Native30 causality.
- Local full Swift parse, generated project and75-case source identities pass. The actual cache gate's blocked-cancellation and normal-release paths execute successfully under Swift on WSL; this is not Apple/URLSession ownership proof.
- Bounded source review found and corrected early-failure gate cleanup and missing post-warm native progression checks. Follow-up review has no remaining Critical/Important findings. SDK/ATS/HTTP and native fixture teardown remain pending.
- Native32 completed: actual HTTP playback, range delivery, verified cache, ownership and fixture close work. The post-seek underrun comparison fails; the test baseline accepted the target command before any PCM progress. Require cursor advancement beyond the exact target and log seek/loop counters, retaining the zero-added-underruns assertion.
- Native32 also retains an actual failing loop recording:996 inserted zero samples/20.75ms, first mismatch58688, source phase5888, no source-reference silence, exact samples before and after the insertion. Original recording/oracle are unchanged. CoreAudio overload is correlated; root cause remains unproved.
- Compositor A/B/A and traced production selection also fail. The latter has964 actual stereo-zero frames and clock skew27.122667ms over its26.333333ms guard. Do not claim an otherwise-green suite.
- Next diagnostic selects the existing accounting-on loop arm with all75 preceding identities, retains existing cached journals after owned close, and enables the already-implemented callback execution clocks only in that accounting-on arm. The default strict arm keeps accounting disabled. Raw execution stamps do not establish a source/mixer clock join. No new runtime probes, SDK reads, test methods, buffers or deadlines. Profile76/native result pending.
- The HTTP seek baseline now requires the expected B token, a consumed selection version newer than the pre-seek snapshot, one retained command/visit identity and actual PCM cursor advancement beyond the exact target. The qualifying snapshot itself supplies beforeLoop; the natural-loop zero-added-underruns assertion is unchanged. Local full Swift parse, generated project and76-case identity checks pass after this correction; SDK execution remains pending.
- Bounded source re-review accepts the command/visit correction and reports no remaining Critical/Important findings. Published private161850b/publicd1fbcde; app/core/workflow hashes unchanged. Native33/run40199336854 dispatched once on the approved manual free unsigned workflow. Buildjob121186961844 succeeds with125core tests and175compiled products; testjob121188153397 verifies those exact-source products and is in progress. No new TestFlight.
- Native33 completes failed, with no owned timeout: build223333ms/test550994ms. Raw console has76 completions/74pass/2fail; strict verifier also rejects two passing lines prefixed by interleaved LoudnessManager text. It remains failed, with no reconstructed pass acceptance.
- HTTP case passes1.657s. Seek baseline1404512 follows exact target1404000 with1024seek underruns; the natural loop adds0. Native44100 complete SRC/production-buffer case passes7.597s. Default selection passes25.854s; traced selection fails25.724s, including1572actual stereo-zero frames/32.75ms and timing guards.
- Both loop PCM payloads and the common complete reference are checksum-verified. Default633600-frame recording has1056/22ms zeros at142656..143712 and560/11.667ms at244576..245136. Every original nonzero segment matches exactly after accounting only for inserted time. Original data/oracle are untouched. Its cached journal records no pause/interruption/route event during either gap.
- Later accounting arm is clean633600/maxdiff0; all2560source zeros are its last5deliberate paused callbacks after the measured window.1252source/132tap callbacks, no copied-source zeros/underruns, no sample-stamp discontinuity. Callback timings describe only this clean arm; no causal transfer to the failing default case, RT join or closure is established.
- Artifact12601952554/73334192bytes/SHA41437e9678e47c756c9d40a3723b4cd49b0fa46d7dfb9437e716fba04ee8b458 verified1704ZIPentries. Exact native-log SHA22cf1005850da1fd368fe6f90ac075fffc064ceee5d48fb1e9f54f64729d430d. All prior failures remain open.

### Task 3: Test the execution-order confound with the same loop helper

**Hypothesis:** The first live-loop position in the full profile differs from the late accounting arm. Moving an otherwise identical accounted observation to the first loop position may capture the failure with callback evidence. A clean observation alone does not prove or fix this hypothesis.

**Bound:** One early wrapper identity calling the existing helper, all76prior identities retained, default accounting still nil, unchanged assertions/runtime/workflow/deadlines. Use existing stored control-ticket reads before and after capture to detect unlogged internal play/suspend commands without RT or SDK probes. Bind captured metadata to its XCTest identity.

- [x] Review the order hypothesis and stored-ticket observation against current source. Bounded review recommends this single order experiment; stable authority narrows control calls but cannot identify SDK/HAL behavior.
- [x] Add the early accounted wrapper and source identity metadata; retain the original default and late accounted identities. Raw PCM hashes are computed after owned close and retained with XCTest identity, enabling exact attachment binding.
- [x] Verify local syntax, project references, exact77-case profile and unchanged production/workflow trees. Local syntax/project/profile checks pass; native SDK execution remains pending.
- [ ] Run the changed-source order experiment once on the same approved free unsigned workflow. Require actual early/default/late test-start order from raw evidence before interpreting the experiment.
- [ ] Act on failing-window evidence; no clean retry acceptance, tolerance changes or production patch without an identified mechanism.
