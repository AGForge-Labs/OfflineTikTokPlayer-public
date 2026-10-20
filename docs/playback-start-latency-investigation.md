# Playback start and transition latency

Investigation baseline: public main `08fba4fd9bc49fa62d268ccbd37d10ccc8074886`. The owner's installed build is unknown. The proposed 14.1 candidate has not uploaded, so this report cannot attribute the owner's current behavior to that candidate. Offered rollback 12.1 remains separate; failed 13.1 remains withdrawn.

## What the previous evidence establishes

The accepted source has exact PCM loop/transition tests, selected-asset checks, actual Simulator compositor pixels and zero added ring-starvation counters in prepared-return windows. Those checks wait for progress/readiness before taking their first screenshot. They do not measure request-to-first-frame time, hardware output silence, cold relaunch verification or the owner's iPhone.

`ContinuousPCMRenderer` initializes output with zeros. An unselected/paused source and an ended source without a usable successor can output zeros without incrementing the ring-starvation counter. Intentional queue completion uses the same EOF path. A zero underrun count therefore does not prove the absence of silence at an engine/output boundary.

## Current and shipped paths

| Phase | Current main | Shipped 12.1 comparison |
| --- | --- | --- |
| Cold Saved selection | Verify local file, load precise PCM metadata, decode a two-second prefix and up to 65,536 stream frames, then attach/observe video | Full-file verification also existed; optional speaker metadata was capped at 100 ms before video attachment |
| Cold uncached remote selection | Wait for complete verified cache transfer before PCM preparation | Audible AVQueuePlayer could begin streaming remotely |
| Prepared Next/Previous | Existing PCM entry selects at a render boundary; visual adoption separately clears readiness, prepares composition/output and may perform an exact seek | Item-owned audible playback incurred AVFoundation start/processing delay in prior Simulator measurements |
| Natural transition | PCM can join prepared samples in one callback; metadata/video adoption follows the 33 ms service poll | AVQueuePlayer owned the audible item boundary |
| Unprepared successor | EOF may emit silence before the service's poll enters preparation | Availability/platform playback preparation also limited the older route |
| Interruption return | Preserve prepared sources; reactivate session and restart only with permitted user intent | Both routes must respect iOS interruption and explicit Pause |
| Foreground return | Restore video separately; unresolved interruption waits for end or explicit Play | No permission to override an exclusive work-app session |

The decoder processes about 3.37 seconds of source PCM before initial publication; that is **not** a measured 3.37-second wall-clock delay. Precise timing has an unmeasured loading cost; inspection does not prove every format scans its whole file. A first lookup after relaunch does hash the entire Saved file. Fresh import fixtures have already populated the verification set and do not reproduce that relaunch cost. Verification and complete source timing must remain intact.

## Baseline measurement contract

Use public synthetic 30-second A/B movies with distinguishable moving pixels and 440/880 Hz audio. Begin timing before the service command. Read real main-mixer output samples with their host timestamps, classify the incoming tone independently and inspect continuous RMS windows for inserted silence; renderer counters remain supporting evidence. The test tap is bounded and stores no user audio. Mixer output still precedes physical speaker/headphone output and cannot certify the phone's audible behavior.

Measure cold A, prepared B and returned A separately. Prepared targets remain at most 100 ms to incoming engine-output tone and 250 ms to a fresh, ready custom video frame; a longer watchdog only permits diagnostic collection and cannot turn a missed target into success. Preserve selected asset/token checks, actual compositor movie identity, source-silence accounting and zero-new-underrun checks. Record exact native seek start/completion/drift so an unnecessary sample-accurate seek cannot hide inside a readiness wait.

The continuous-tone fixtures must contain zero detected 10 ms quiet windows; no source-silence allowance may conceal an inserted quiet interval. Captures must contain independent outgoing and incoming tone windows in timestamp order. Adjacent host timestamps must remain monotonic and continuous within half a sample frame, including across tap callbacks. A separate natural-boundary case plays the complete 30-second A presentation and captures its final half second through B's beginning. The RMS detector has 10 ms resolution and can miss shorter quiet runs; exact graph sample tests remain complementary. The 250 ms metric measures custom readiness, with actual compositor pixels checked afterward, rather than claiming a 250 ms compositor or physical-display measurement.

Apple documents that [sample-accurate zero-tolerance seeking can add decoding delay](https://developer.apple.com/documentation/avfoundation/avplayer/seek(to:tolerancebefore:toleranceafter:completionhandler:)). Its [preroll API](https://developer.apple.com/documentation/avfoundation/avplayer/preroll(atrate:completionhandler:)) requires a paused, ready player. These are constraints to evaluate against measurements, not grounds to relax exact paused-position/selection tests or launch another player.

Baseline portable check: 83 core tests passed serially with one Swift build job. No merge, release dispatch, signing, upload, environment variable or TestFlight assignment is authorized by this investigation.

The first unsigned instrumentation run, `39503258121` at `8f3a38695a06c53119cc1589a97d8c2d59d2236b`, failed compilation because the new optional injection parameter shadowed the stored audio player. It ran no playback measurement and is excluded from latency conclusions. The parameter was renamed in `ed11c712684aeb175d2d2b21eb22cc8257c48a7c` without changing playback behavior.

## Reproduced baseline and focused correction

[Unsigned baseline run 39503751284](https://github.com/AGForge-Labs/OfflineTikTokPlayer-public/actions/runs/39503751284), at that exact corrected instrumentation source, failed the two prepared custom-readiness assertions. It executed 91 native tests (two assertions failed in the new latency case) and one passing UI test. The canonical job log SHA-256 is `2bf762643621d903c200b2cd3f6f8196abe6f7ddf7dca58f9579335534c8136e`.

| Selection | Incoming 20 ms tone window end after command | Custom frame readiness | Detected 10 ms quiet windows | New PCM underruns |
| --- | ---: | ---: | ---: | ---: |
| Cold A | 150.88 ms | 301.24 ms | 0 | 0 |
| Prepared Next B | 42.33 ms | **379.12 ms** | 0 | 0 |
| Returned Previous A | 42.20 ms | **305.49 ms** | 0 | 0 |

All three captures had continuous host timestamps (maximum numerical residual about `4.3e-12` ms); both decoded reference sources had zero quiet windows. Later actual compositor captures showed the correct A/B/A movie identities. This reproduces prepared video delay, not a physical-output silent gap. A phone speaker/headphone measurement remains necessary.

The returned A path issued an exact seek while video was already playing at zero and PCM was only 0.208 ms ahead. Native completion took 280.93 ms. Next B's exact seek began 222.20 ms after the command and took 72.99 ms. These traces support preparing the existing file-local item composition before staging and preserving an already aligned prepared selection. Initial PCM starts before cold video normalization; source timing, full-file verification and every decoded source frame remain intact. Explicit seeks, loops, nonzero restores and drift beyond the existing 80 ms threshold retain their seek/frame-epoch behavior. No player or PCM slot is added.

The stricter capture also requires outgoing and incoming tone windows in order, and a new natural-boundary case plays all 30 seconds of A before B. These additions were not present in the baseline source; their results must be reported separately. Prepared output/readiness limits remain 100/250 ms. The log verifier also gains a fail-closed reconstruction for the exact adjacent two-line XCTest identity split observed when Apple's `LoudnessManager` diagnostic interleaved with a result. That parser repair cannot turn the actual failed latency assertions or `TEST FAILED` marker into a pass; malformed, orphan, duplicate, retried, skipped and failed evidence remains rejected.
