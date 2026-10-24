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


Run8 on898a16a reached the15-minute provider cap. All68 identities emitted results,
but the owned command/verifier did not complete: whole-run acceptance failed.
123core/65native/1UI passed; two native cases failed. Both actual8-second audio
windows recorded384000frames/400tones and zero stereo-zero/quiet/drop/underrun
results. Default B193.175ms and returnedA88.613ms pass; traced B392.476ms fails250ms;
rapid A/B/A initial preparation fails the original3s guard. Earlier zero-output
failures remain valid evidence. This is not a new TestFlight or phone result.

The next check keeps production Swift unchanged and the exact68-case profile.
App and PlayerCore retain-O/DEBUG; only test targets receive an appended-Onone
flag to avoid spending roughly184s optimizing test harnesses. Actual returned
compiler commands must verify that scope/order. Default modes do not request
the test-only override. The existing traced benchmark enables its already-defined
ordinary-clock observer bundle without additional SDK reads or a new case.
The original rapid case now prints existing load/preparation/worker state only
once its unchanged3s predicate fails. No startup-policy, source sample, silence,
progress, compositor or timeout criterion is relaxed. Public source/free unsigned
checks remain the only newly authorized hosted actions.

Run9 on14d93c4 completes within the cap (10m58total, owned command exit65/no timeout).
123core/65native/1UI pass. Both unchanged actual8-second audits capture384000frames,
400tones and zero stereo-zero/quiet/drop/timestamp errors/underruns. Default/traced
Bvideo125.771/146.668ms and returnedA111.089/90.308ms pass; rapid A/B/A now passes.
Same-source fresh-host passes do not repair the older intermittent failures.
Two original Library Audio only tests fail four5s playback-condition assertions:
camera/permission and persisted paused restore. Owned fixture close ACKs succeed.
The build remains failed; no new delivery or phone/full Release claim.

The next diagnostic labels the seven existing waits in those two tests and reports
original call-site failures, plus cached player/owned decoder state only after the
original5s condition fails. Its result is frozen before collecting evidence; no
late completion can turn it into a pass. One bounded1s evidence response is separate
from playback acceptance. Existing native APIs and Mutex transport are reused;
no production Swift or profile identity/threshold changes. Native syntax/project
and exact68-case manifest validation pass locally. No new startup policy is added.


Run10 on e5367af ends failure in12m57s:123core/66native/1UI pass, one traced Next
case fails video274.253ms and a10ms mono-RMS-zero interval4.069-14.069ms after Next.
The renderer reports zero new underruns. Exact stereo silence during that selection
is not measured by the separate clean returned-A8s stereo audits. Native9 Audio only
timeouts do not recur, so their cause remains unproven. No new release is qualified.

Before another check, the profile adds one bounded source/mixer diagnostic and keeps
all68 original identities. Four prepared Next/Previous transitions use the unchanged
measurement/assertion helper with the same3s setup,250ms video and zero-quiet limits.
Existing source-output counters and existing stereo tap audit cover each selection
window, including its120ms lead. They do not claim calibrated source-to-tap frame
identity. Default cases pass nil and retain their original callback behavior.

Before starting the engine, the sole manual render owner copies12000frames of the
actual prepared B head into a96KB buffer. After original playback assertions and
acknowledged shutdown, the existing complete30s native reference reader compares
that head sample-for-sample, with explicit codec trims and exact timeline coverage.
This closes the old0.5-0.75s tone-reference gap without changing media or trimming
source samples. Native compilation/results remain pending. The absent new identity
was rejected before implementation; local syntax/project/source-profile and launcher
checks pass. Production Swift is unchanged; manual standard-public unsigned15min
scope, Release qualification and phone acceptance remain separate.

Run11 on ed04e64 stopped at native test compilation: the optional-Float logging
expression used overloaded String.init references, which the Apple compiler could
not diagnose. No native playback/UI cases ran;123 portable core tests passed.
The exact expression independently fails local Swift type-checking as ambiguous.
Four explicit Float-to-string closures and named strings now type-check and execute
locally in Swift5 mode. This changes only failure logging, no player/source criteria.
The native boundary diagnostic and full69-case profile still require SDK execution.
