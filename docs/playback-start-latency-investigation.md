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

Apple documents that [sample-accurate zero-tolerance seeking can add decoding delay](https://developer.apple.com/documentation/avfoundation/avplayer/seek(to:tolerancebefore:toleranceafter:completionhandler:)). Its [preroll API](https://developer.apple.com/documentation/avfoundation/avplayer/preroll(atrate:completionhandler:)) requires a paused, ready player. These are constraints to evaluate against measurements, not grounds to relax exact paused-position/selection tests or launch another player.

Baseline portable check: 83 core tests passed serially with one Swift build job. Native request-to-output/frame evidence is pending. No production playback behavior has changed at this stage; only a test dependency injection/readiness seam is added. No merge, release dispatch, signing, upload, environment variable or TestFlight assignment is authorized by this investigation.
