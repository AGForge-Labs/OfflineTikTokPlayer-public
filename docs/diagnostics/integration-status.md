# PCM player integration candidate

This private candidate combines the continuous PCM experiment with the already-delivered
Library Audio only control and phone-requested TikTok refresh. It is not a delivered build.

The existing focused profile now requires 65 native results and one UI result, including
every original diagnostic case plus complete relevant service, presentation, library,
speaker and feed suites. All portable core tests still run. Missing, failed, skipped,
duplicate or unexpected case evidence remains a failure. The ordinary full-suite mode
is unchanged, including the long experimental A/B comparisons and their failed evidence.
This profile is partial evidence and does not claim complete release or phone acceptance.

OneDrive streaming and the bounded temporary cache remain the media path. Audio only
preserves the PCM owner, selected item and position, stops video/PiP presentation, persists
the preference and restores the saved queue paused. Player and the mini-player restore
video. iOS interruption permission still controls camera/call recovery.

Free local cloud tests first failed on missing import APIs, then all 16 passed after
the delivered adapter/repository implementation was restored. Swift parsing and project
references pass. The new native persistence and interruption tests require Apple SDK
execution; real OnTrac scanning/photos and real-phone gaplessness remain pending.

`gap-profile-snapshot.json` preserves the earlier isolated diagnostic import provenance;
it is not a checksum assertion for this subsequent integration. The Git commit and its
current native job receipt identify the integrated source.


The review's mandatory full-file dependency has a source correction pending native
validation. Ready Saved/verified cache files retain the PCM engine. Cache misses resolve
a fresh cloud URL immediately and use the existing AVPlayer for its audio and clock;
the local-file PCM reader is never fed an unsupported remote URL. The selected stream's
initial buffer precedes optional neighbour warming. A rejected optional cache transfer
does not reject the selected video or enlarge the 256MiB temporary-cache budget.

Native streaming ownership preserves Audio only without pausing its audio, detaches
the inline layer, and preserves seek, pause, queue and interruption rules. Speaker DSP
belongs to exactly one audible transport. Previously prepared remote items are retained
through handoff. Two native regressions exercise this path using original synthetic
files returned by a fake cloud resolver; they do not prove HTTP/network or phone behavior.

Five real-cache/source regressions first failed with the missing resolver and now pass;
all119 portable core tests passed. Fifteen focused evidence/launcher tests passed. Native
SDK compilation and actual output remain pending. Previous failed output witnesses,
the complete ordinary test mode and every existing64 profile identity are preserved;
the two new native cases bring the profile to66. Native streaming boundary gaplessness,
source-complete PCM performance and real-phone/OnTrac acceptance remain required.

Public integration run2 stopped at an NSObject/Observation initialization compile error;
run3 compiled the app but stopped at two test-only compile errors. All three were corrected
without changing output or pixel assertions. No runtime acceptance is inferred from them.

Public run4 on069bbe9 compiled both native targets and passed119core/55native/1UI,
but10native cases failed. The first camera test overlapped native owners between its
three arms and exceeded the unchanged3-second close deadline. Fail-closed admission
then blocked the remaining selection/stream tests, including the actual gap audit.
This run supplies no new gap measurement. Its full raw log/result bundle are retained.

The next test-only correction explicitly joins each camera/relaunch owner before
constructing another, stops the engine before cancelling its settling poll, cancels
the display monitor and awaits CPP video preparation as well as decoder closure.
Fixture acknowledgement additionally requires the engine stopped; no assertion,
case, close deadline or gap criterion is relaxed. Native execution is pending.

Public run5 on0c355db passed119core/63native/1UI;2native cases failed. Cleanup
acknowledgements now include stopped engine and joined video preparation; both PCM
Audio only persistence/interruption cases and all visible A/B/A/natural/paused cases
passed. The default returned-output audit captured384000frames/8seconds,400of400
tones, zero actual stereo-zero frames, quiet windows, timestamp errors, drops and
underruns. This is one simulator output window, not physical-phone/global acceptance.

Remaining failures: prepared B became video-ready at330.931833ms against250ms, while
its incoming tone started at26.990542ms without underruns. The new native streaming
Pause case reported rate1 after video/foreground restoration while intent stayed paused.
A local source candidate now enforces latest native playback permission on late rate
changes, with an actual frozen-clock assertion added to the same regression. The rate
observer exists only during native streaming. Syntax passes; native execution is pending.
The prepared-B latency cause is still under investigation; no threshold was relaxed.


The next67-case profile retains all66 prior identities and adds the existing traced
production-selection benchmark. The normal default benchmark still requires the same
250ms ready limit and exact audio/identity assertions. The existing bounded startup
recorder is enabled only for the diagnostic case; normal/default tracing stays off.
This reuses existing boundary evidence to locate prepared-B delay before proposing a
start-policy change. No current-time shortcut, source trim or threshold change is made.
The native Pause permission candidate and frozen-position regression require execution.


Public run6 on edc45d0 is terminal failure:119core/63native/1UI passed;
three native cases failed (eight assertions). The streamed explicit Pause case now
passes with frozen native position. The default uninstrumented benchmark passes
26.538s with next-B165.230ms/returned-A124.695ms video readiness. Both default and
traced8-second output audits contain384000frames,400of400tones and no stereo-zero,
quiet windows, timestamp errors or dropped frames. The traced benchmark still
fails B progress:50.267ms less PCM than wall time, maximum skew46.929ms against
26.333ms. The prior330.932ms video delay did not recur; no cause/fix is claimed.

Natural-boundary setup stalls on its explicit28-second seek. Worker evidence shows
zero ready ring frames while reconstructing output from frame zero, only892928
generated frames toward the requested1344000 after its unchanged10-second runway.
Separately, two actual compositor captures take13.27s+21.65s, outlasting the30-second
fixture and exposing end-of-source underruns. All failures and capture/window,
progress, full-source, latency and zero-silence criteria remain unchanged.

The next candidate bounds only distant native48kHz read work: begin two seconds
before the requested seek, while retaining the complete precise endpoint. Initial
playback, ordinary retained two-second heads and every sample-rate conversion
retain their zero-based history. Apple documents configuring AVAssetReader.timeRange
before reading: https://developer.apple.com/documentation/avfoundation/avassetreader/timerange
This is a candidate, not native acceptance. Four new portable policy tests were
observed RED while the policy was absent; all123core tests now pass. Native syntax
and Xcode references pass. A new actual AAC regression compares sought samples
bit-for-bit with an independent full-source decode, checks native copy work and
unchanged endpoint/memory, then explicitly awaits reader closure. It requires SDK
execution. The68-case profile retains all67 prior identities, including all three
failed cases. No compositor fixture, threshold, test timeout or full-suite mode
is changed. No new TestFlight delivery or phone acceptance is claimed.


Public run7 on0554d09 is terminal failure10m49s:123core/64native/1UI pass,
three native cases/13assertions fail. The distant AAC seek regression passes4.203s,
with bit-identical compared samples at28s/7s and15/14 native reads, unchanged complete
endpoint/storage. The original natural-boundary case now passes17.463s; actual
A/B/A compositor pixels pass12.758s. Native streaming Pause/navigation remain green.
Default and traced returned-A audits fail again: actual stereo-zero runs2764frames
(57.583ms) and2104/780/732frames (43.833/16.250/15.250ms),398of400tones in each.
Both report zero renderer underruns, with clock-progress lag. Default prepared B
video-ready273.178ms also exceeds250ms; rapid A/B/A fails its original setup bound.
Every failure and all thresholds remain preserved; no new release is qualified.

Actual compiler commands show PlayerCore and app both compiled with-Onone/DEBUG.
Shipping Release is configured with-O. The next explicit optimized comparison runs
the same68-case manifest with SWIFT_OPTIMIZATION_LEVEL=-O, retaining DEBUG hooks,
serial compilation, cleanup, verification and all original assertions. Default full
and unoptimized profile modes remain unchanged. Actual SDK compiler flags must be
read back before treating a result as optimized; a clean comparison would not prove
causality or replace full Release/device acceptance. App/media code is unchanged.
Apple performance guidance: https://developer.apple.com/documentation/xcode/writing-and-running-performance-tests
