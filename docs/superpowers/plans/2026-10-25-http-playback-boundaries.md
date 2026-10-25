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

- [ ] If the network regression fails, classify whether HTTP/ATS, cache, transport ownership, preparation or repeat failed before modifying production code.
- [ ] If it passes, record the network coverage gained without claiming native-to-PCM sample continuity or phone acceptance.
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
