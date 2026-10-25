# HTTP Playback Boundary Investigation Plan

> **For agentic workers:** Use superpowers:executing-plans inline in the existing gapless-integration worktree. Do not spawn implementer agents.

**Goal:** Exercise the actual network-to-temporary-cache playback path before changing audio transport to address silent boundaries.

**Architecture:** Serve only bundled synthetic MP4s from an ephemeral loopback HTTP range server owned by the XCTest. Use the real PlaybackService, PlaybackMediaCache, URLSession, AVPlayer and persistent PCM graph. Hold optional cache transfers until native HTTP playback advances; then verify warmed navigation and repeat without creating Saved copies.

**Tech Stack:** Swift, Network, AVFoundation, XCTest, existing unsigned Mac checks.

**Spec:** User requires seamless Next/Previous/repeat-one while streaming OneDrive without explicit phone downloads. Existing contracts and unresolved witnesses are recorded in docs/diagnostics/integration-status.md.

## Global Constraints

- Require an observed failing path and a specific mechanism before a production change. Task4 permits one documented blocking-API removal in the measured initial-preparation path; it does not establish that API as the cause of prior mixer silence.
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
- [x] Run the changed-source order experiment once on the same approved free unsigned workflow. Require actual early/default/late test-start order from raw evidence before interpreting the experiment.
- [x] Act on failing-window evidence; no clean retry acceptance, tolerance changes or production patch without an identified mechanism.

## Native34 result

- Run40201689817/sourcedd4abf6 completes failed without timeout. Build192161ms/core125/175products pass; tests494940ms return all77identities,75pass/2fail. Strict verifier rejects exactly the2failed cases; no torn-pass reconstruction issue. UI passes32.322s.
- Raw start order confirms early-accounted, original-default, then late-accounted. All3record633600frames, exact complete-reference match/maxdiff0, zero actual mixer zeros/underruns, stable control ticket2to2. Both accounted prefixes contain only1024deliberate paused frames after capture. Hashes bind each case to exact PCM; two cases share identical bytes and deduplicate naturally. This is nonrecurrence, not an audio repair or proof of the order hypothesis.
- Default navigation fails43.628s: prepared B video297.6155ms over250ms, two snapshot acquisition durations over5ms, PCM/wall skew, and actual returned-A zeros2008frames/41.833ms plus564frames/11.75ms. The8.2s393600-frame audit has2572stereo-zero frames and408/410correct tone blocks. No kernel underrun is counted.
- Natural-boundary case fails22.894s because its initial-preparation main-actor sampler has a2.298253333s gap (250ms guard). This is NOT a2.3s natural handoff: the actual later boundary preserves its1024baseline underruns with0added and reveals correctly moving B. Cached phase advances audioPrepare4toobservedCurrent7 while PCM reaches109056frames; the precise blocking SDK call is unproved.
- Local ffprobe verifies the default navigation fixture is stereo AAC48000, already eligible for the new reader. Do not attribute this failure to the mono fallback or expand reader admission without separate evidence.
- Artifact12602641751/75055585bytes/SHA491bc58521c60d303073465851e3e2ed6fb07aef24357d780f8a2bca837af324 verified1716ZIPentries. Exact native-log SHA3bac0876f64e3284b53c0be62361f90a1afaf33333142ea3b4c448b1fd271d67. Prior failed loop recordings remain open. No Release/TestFlight/phone acceptance.

### Task 4: Remove synchronous metadata loading from video composition creation

**Observed RED:** Native34's original initial-preparation coverage guard fails with a2.298s main-actor sampling gap; prepared B readiness also exceeds250ms. The interval does not identify one SDK call.

**Specific hazard and hypothesis:** makeVideoComposition is MainActor-isolated and invokes synchronous AVMutableVideoComposition(propertiesOf:). Apple documents that this constructor can synchronously load asset properties and provides an async equivalent to keep media apps responsive. Replace only that call, retaining all geometry, timing/color defaults and cancellation ownership. This is removal of a documented blocking hazard; a clean retry alone cannot establish it caused the mixer gaps.

**Primary references:** https://developer.apple.com/videos/play/wwdc2022/110379/ and https://developer.apple.com/documentation/avfoundation/avmutablevideocomposition/videocomposition(withpropertiesof:completionhandler:)

- [x] Replace the synchronous factory with try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset), then check cancellation before configuring instructions.
- [x] Keep every77prior profile identity and add3existing full-frame identity, portrait/mirror timing and cancellation cases (80total); create no duplicate tests. Preserve the verifier's original80-case bound; the remaining cadence/retirement tests stay in the full native gate.
- [x] Run local source/project/profile checks and bounded source review before publishing; leave audio renderer/core/buffers, workflow and timing/silence assertions unchanged. Full Swift parse, generated project and exact80-case profile pass; bounded review has no Critical/Important findings. Native SDK typechecking, cancellation latency and timing remain pending.
- [x] Run one changed-production-source native check, retain all failures, and distinguish blocking-API removal from actual recurrence/device acceptance. Native35/build passes; all80cases return,76pass/4fail. The3added composition cases pass; gaps and timing failures remain.

- Local profile validation caught an84-case selection exceeding the existing80-case bound. Narrowed only the added existing cases to identity, orientation/timing and cancellation (77+3); verifier bound and all preceding77cases remain unchanged. This was caught before any hosted run.

## Native35 failing-window correspondence

- Run40204029345/source9489d3b completes failed without timeout. Build239148ms/core125/175products pass; tests505309ms return80cases/76pass/4fail; strict verifier rejects exactly those4. UI passes28.162s.
- Early accounted loop retains1064inserted zero frames/22.166667ms at40256..41320; original default loop retains1044+1068zero frames; late accounted loop is exact633600/maxdiff0. Stable stored control authority2to2 in all3. This is no gap repair.
- For the early failed prefix, source callbacks88to89 request timestamps advance1576samples instead of512. The unrequested1064-frame raw-HAL interval11485501299..11486033299 equals the recorded tap-zero interval exactly at500ticks/frame, with no latency shift. Both surrounding calls copied512finite nonzero pairs and returned0; observed executions12.125/11.792microseconds. All1536source zeros are3final paused callbacks after the recorded endpoint. Original coverageClosed/formalRTJoin remainfalse. This establishes one observed timestamp correspondence, not why requests skipped, driver culpability, absence of earlier app/observer load, or physical output.
- Source phase45056precedes first57600-frame loop boundary. Re-extracted original ledger payload SHA256ccf62c204cd1fe4f7f2b77a6f4ab4bb4b7e52d3ae3f4198a7ae6917186b641f5 matches the verified artifact index and reformatted JSON; PCM/reference hashes match their case binding. Bounded independent review confirms interval arithmetic and scope; provenance was strengthened afterward by re-extracting this leaf.
- Default navigation fails on386.35/357.75ms video readiness and7.55ms snapshot acquisition; returned-A actual stereo audit is retained. Natural-boundary case has791.915ms initial-preparation sampling gap (audioPrepare4toaudioPrepared5) and a31.635s screenshot window exceeding29s. PCM baseline2048underruns remains2048. Do not interpret screenshot time as an audio handoff.
- Artifact12603401892/72117083bytes/SHA2561e44aef393c247f6c72e3f6798e2780a044986a5616df18ead216ce95a9ed064; native-log SHA256f29bdc09a4849233a8fe96ae9ff584b6dd57ca5f594870b86afe23ef3ce0445c. Prior failures, full Release and phone acceptance remain open; no TestFlight.

### Task 5: Capture one bounded startup stack trace using Native35 products

**Observed RED:** Native35's remaining791.915ms initial-preparation MainActor sampling gap occurs before audioPrepared. Recorded source-request gaps also remain, with no proved common cause. Stop guessing at another SDK call; inspect actual stacks in this startup flow.

**Scope:** Reuse the exact Native35 compiled products and checkout9489d3b; preserve its complete80-case acceptance profile. A separate diagnostic profile selects the existing natural-boundary test plus the required UI smoke case. A short built-in macOS sample begins only after the playback case's exact NativeRuntimeHost event and stops after2seconds. This is a profiling observation, not the full acceptance run or a timing comparison with Native35. No third-party tracing framework, app/test-method change, signing, Saved files or private media. The existing profile verifier requires both native and UI identities; preserve that rule.

**Attribution limit:** RuntimeHost output may be buffered and process attestation takes time. Case liveness does not prove initial preparation remains active. Export phaseQualified=false/startupCaptureProved=false, name the file native-case.sample.txt, and draw conclusions only from actual named stacks. Check original app/dSYM UUID agreement before profiling; inspect real symbolication afterward.

- [x] Add a bounded host-event/process attestation watcher and local rejection tests. Sample only the matching app executable in the exact synthetic Simulator and only once; stop owned children and preserve explicit missed/failed outcomes. Four local rejection groups pass; phase/freshness remain explicitly unproved.
- [x] Prepare a manual-only standard public macos-26 job with15minute limit. Read only Native35's checksum/source/SDK-verified product artifact. Keep secrets/signing absent, main unchanged, all80acceptance identities intact and original deadlines/assertions unchanged. Native36 ran once without rebuilding.
- [x] Run local syntax/profile/harness checks and bounded source review before one dispatch. Mark playback-plus-UI results as diagnostic-only; preserve native failures and profiler limitations. Source review's Important startup-attribution finding was corrected with explicit unqualified fields and neutral output names; re-review has no Critical/Important findings. Local175-product checksum and relocatable test paths verify; native app/dSYM UUID agreement will be checked before profiling.
- [x] Inspect and retain the stack attempt's actual output. Require named stacks before a call-path finding; an unsymbolicated, missed or clean trace does not explain the gaps. Native36 sampler times out and produces no stack file, so no SDK call is attributed.
- [x] Restore the original80-case manual workflow byte-for-byte after retaining the trace; no diagnostic-only run becomes acceptance.

## Native36 result: profiling unavailable on this attempt

- Run40207026014/harnessfe6f551 reuses exact candidate9489d3b/Native35 artifact12602932379; original175file checksums, source, Xcode26.6/17F113, SDK26.5 and arm64 identity verify before execution. No build or native method changes.
- App and dSYM UUID70EB15C1-D46F-372F-AB5F-D751AAAC8755 match. Process/executable/Simulator ownership attests, but attestation takes5.455s after the observed RuntimeHost event; phase and event freshness remain unproved.
- The requested2s sampler exceeds its20s process bound and is killed/reaped; captured=false, startupCaptureProved=false. No native-case.sample.txt exists in the artifact. There is no stack to interpret; do not raise the bound or retry unchanged to manufacture evidence.
- Existing natural-boundary case fails26.653s on actual selected-AVPlayerItem clock advancement. UI smoke passes94.093s. Owned test417244ms/exit65/no timeout. Strict two-identity diagnostic verification fails; Native35's80-case acceptance also remains failed.
- Artifact12603964852/61510908bytes/SHA25632bb906f467a913cb6add25ec67abaa22d38730ff53d03b191eee2c0ffcb7248 verifies1434entries. Exact native log25460bytes/SHA256aa08cde31b964468256f81fedd7c8f8979e66a08b181849859c3449fe45673d3, receipt9940229b0a590fda87cf73b65657a1e5778f9c31b38bb280fbc5624b375e5a07. Prior witnesses remain; no physical output or TestFlight acceptance.

### Task 6: Check the actual Release app without signing

**Purpose:** Close the untested Release-configuration compilation path while preserving all failed runtime evidence. This is preparation for eventual device validation, not a waiver of the silent-gap or readiness failures.

- [ ] Prepare a manual-only standard public macos-26/15minute compile of immutable candidate9489d3b with Release/iphoneos/CODE_SIGNING_ALLOWED=NO. Reuse the existing owned build launcher; no tests, secrets, archive, signing or upload to Apple.
- [ ] Retain exact source/SDK/build outcome and restore the normal workflow afterward. A successful build proves compilation only, not gap-free playback, device behavior or release readiness.
