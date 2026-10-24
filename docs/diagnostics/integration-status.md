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


### Native12: exact prepared head and four measured boundaries

Public run40101087562/job120893198637 on806b5d8 completed in13m35s,
owned full-test exit65/no timeout. All69 selected identities returned:
123core,66native and1UI passed;2native cases failed. Original source/media and
all timing/output assertions remain intact. This is a focused profile, not full
Release or physical-phone acceptance.

The new2.032s boundary case compares all12000 prepared B head frames against a
complete1440000frame native reference: zero mismatched samples, zero source
stereo-zero frames or sliding quiet windows. Four actual prepared transitions
show zero source/tap stereo-zero frames, zero underruns, and readiness
213.610/125.727/116.052/106.605ms. Source-to-tap runtime clock/frame calibration
is still unverified; absence of the prior intermittent gap is inconclusive about
its cause. Both original ongoing output audits are clean again (8.1s/8s).

The traced benchmark fails an independent sampler gap316.688875ms against250ms;
maximum PCM/wall skew is8.360125ms with no output silence/underruns. Rapid A/B/A
fails its original3s initial-preparation guard: zero prepared sources, one pending
first read, no packets, responsive decoder worker. Native API stage was not
recorded, so an SDK wait is not established. Both Audio only cases and UI pass.

Raw SHA2562e2cda6d883beaea7ad1d9760b6d5d98b8630fb4e1d586f3db77c6d9f388d541.
Artifact12563580783/72340509bytes/SHA256
d358aa836d1c07f8d6922115786beec95e6ca89686c069c9dd6775bbf989bd30 downloaded
and checksum verified. No production repair or TestFlight release is inferred.

Next source diagnostic reuses the existing packed native-lane activity recorder
in the same rapid test. Failure-only before/after cached stage reads keep the
original3s guard and all playback assertions, with no additional test identity,
SDK getter, clock or runtime implementation change. No native13 run yet.


### Native13: earlier first-read failure prevents later instrumentation

Public run40102767694/job120898141094 on611d0af completed in12m40s,
owned full-test658958ms/exit65/no timeout.123core/63native/1UI passed.
The original natural-transition case fails its3s initial-preparation guard with
zero prepared sources, one pending first read/no packets and a responsive worker.
Its original3s owned close guard also fails. Synthetic media is retained and the
existing fail-closed admission correctly prevents four later owners, including
the rapid test that would have captured the native stage. These are not four new
audio/pixel measurements. The exact pending native API stage remains unknown.

The default uninstrumented benchmark still passes: B154.912ms/A157.865ms,
8seconds/384000frames/400correct tones, zero observed stereo-zero/quiet/drop/
timestamp-error/underrun frames. This clean window does not erase prior failures.
No causal production repair, Release build or physical-phone acceptance is proven.

Raw SHA2561af3affee37d4f5932c49a88990e161d8d734e92d2ab0d050c8456c49eb6faf7.
Artifact12564185627/66334018bytes/SHA256
e7a182bf0525cd7cb30961c1541a595e233fa03c56def47e00cdbc25eaba9b21 downloaded
and checksum verified (1626entries/no named images).

Next diagnostic moves existing cached initial-stage capture into that earlier
natural path. Native/worker packed records are observed at the existing100ms
cadence; failure-only endpoint observations now include their DispatchTime bounds.
A failed close may collect one additional bounded worker reply after canRemove
is already frozen false; this cannot turn late cleanup into a pass. App/core,
media, all69 identities and original3s/250ms/output assertions are unchanged.
Default stream tracing remains off; no SDK getter or clock is added to a native
or real-time callback. Local syntax/project/profile/diff checks pass. No native14
run or TestFlight delivery has been inferred from these source checks.

Coverage audit also finds that current service repeat-one tests observe visits
and underruns while exact decoded sample concatenation is tested in the offline
graph. Before whole-goal acceptance, live mixer output across repeated complete
service loops still needs direct comparison, separately from the phone's ten-loop
acceptance check. No existing loop test or source duration is weakened.


### Native14: real returned-A starvation captured

Public run40104440764/job120903091224 on0ac8f07 completed in12m49s,
owned full-test705121ms/exit65/no timeout.123core/67native/1UI passed.
Only the traced production-selection case fails (14assertions). The original
natural preparation/close and rapid cases pass this time, so their earlier
timeouts remain intermittent and unresolved; the new initial coverage records
411.329ms to prepared with5bounded samples and no dropped observations.

The traced returned-A8.1s output has35520 consecutive exact stereo-zero frames
(740ms), at retained frames353280-388800, and only368/405correct tone blocks.
The renderer reports real starvation: phase2baseline12800/final50688underruns,
113.633125ms maximum PCM/wall skew, and51200cumulative final underruns. The
selection window also has250ms quiet; a separate B sampler gap260.847ms fails
its unchanged250ms bound. These are distinct measurements, not one inferred gap.

The default benchmark stays clean (B168.533ms/A133.383ms,8s384000frames/400tones,
zero stereo-zero/quiet/drop/timestamp-error/underrun). Four prepared boundaries
are also clean; complete native B/reference head still match12000frames exactly.
Those passes do not erase the real traced starvation or earlier zero-output runs.
No production cause is established yet; do not increase buffers merely to hide
the finite8s audit or relax existing silence, sample-progress or deadline guards.

Raw SHA2565de2db7b0f9544b7b3dccbc594effe6439d27a5fe12e3aea2900692fe2250412.
Artifact12564656465/65269419bytes/SHA256
894a4ceed757d08859df84d212a06fb1a208bcd594a5d4c503e76fa0badb3e61 downloaded
and checksum verified (1652entries/no named images).

Next70-case candidate retains all69 cases and adds one live repeat-one test.
It uses the existing unmodified1.2s AAC fixture, a complete single prepared visit
as reference, and at least ten complete cycles through the same live mixer and
visible service. All retained mono-projection samples must match a cyclic source
reference within1e-6; no samples are trimmed. Native stereo-zero counts, sample
timestamps, visit progress, underruns and stable engine identity also remain
required. Independent AAC/SRC tests provide separate codec-reference proof.
Only this case requests a bounded16s tap arena; original cases keep12s and all
30s A/B fixtures are unchanged. The exact source comparator is locally calibrated
against shifted phase, encoded zeros, one-frame insertion/deletion/zero replacement,
nonfinite values and a silent reference. Missing-method RED preceded implementation;
local syntax/project/profile,17launcher and3focused evidence checks pass. Native
SDK compilation/execution and physical output are still unverified.

The exact failing clock-observer bundle now reuses the existing first-source-copy
failure recorder and packed worker/native-lane activity records. Its existing
100ms render sampler already has fields for these cached values; no extra sampler,
SDK getter, callback clock or new renderer site is added. Failure-only output after
cleanup identifies the original guard operands (including access/epoch/read/write)
and historical packed decoder stages. Default uninstrumented mode stays unchanged.
This is diagnostic source, not a causal audio repair. App/core implementation,
source media, original assertions, release scope and delivered build are unchanged.
No native15 or TestFlight delivery has been inferred from local checks.


### Native15: loop-test compile failure, no new audio result

Run40107069237/job120910858608 on87c966e ends in3m20s (job3m16s).
123core tests pass, but native/UI cases do not execute. The Apple compiler
rejects two new nested collection expressions in the live-loop test as too
expensive to type-check. The correction replaces only those expressions with
explicit Float and Int loops; exact replacements type-check and execute in
Swift5 mode locally with known mono and zero-count results. No sample, deadline,
assertion, existing case, profile, media, app/core or workflow changes.
Current syntax/project/70-case validation passes; native execution is pending.
Raw SHA2563de61530628b7460877cc52fded098da1ebb3c02d260c34bceb18f3d8fd06677.
Artifact12565635699/95245bytes/SHA256
ba9f4643dd8e86b0797bea9ab6907586b122ab92c3539bafac839e33d9ea301c
downloaded and verified (18entries). All earlier audio failures remain open.
No TestFlight or phone acceptance is implied by this compiler correction.


### Native16: full live-loop sample match, two remaining failed cases

Run40117015366/job120940281474 on publicc054acd completes in9m7s
(job9m3s), owned481949ms/exit65/no timeout.123core/67native/1UI pass;
all70 selected identities return. Two native cases fail, so the profile is
not accepted and no whole-goal or delivery claim follows.

The new live repeat-one measurement captures633600frames of the original
57600frame/1.2s AAC source. At least ten complete loops and11actual visits
match every mono-projection sample at1e-6 (alignment4800, one candidate).
Zero actual stereo-zero frames, underrun delta, drops or timestamp errors;
one stable running engine, selected A and visible/advancing video. The case
still fails strict token equality3!=1: its post-reference cycleRepeat calls
prepareUpcoming on the empty queue, which clears the unselected preparation
window. The correction moves repeat configuration before preparing the
reference; finalState.token==entry.token stays unchanged and repeat-one is
explicitly asserted. No source samples or acceptance tolerance change.

The original natural boundary case times out its screenshot command after
31.644s (errorCode3). It also has real renderer starvation: runway baseline
3072, before-capture3072, after-capture901888, an added898816underrun frames.
These are counters, not a measured contiguous actual-stereo silence duration.
Its existing screenshot error remains a failure; no retry or deadline increase.
Do not dismiss this as only infrastructure or infer that screenshot and decoder
stalls have a common cause. First render-guard operands and cached native/worker
state were unavailable for this exact natural failure.

The existing natural case now asserts no new underruns after its seek runway
through the natural transition and visible motion check. On failure only, it
uses the existing bounded1s worker-state reply before close. The already enabled
natural activity recorder also retains the existing visit3 first-source failure,
dumped after the original owned cleanup. No extra sampler/SDK query/hot clock,
production code, native read policy, media,70-case membership or original assertion
is removed or relaxed. Known native16 counters provide the failing audio witness.

Default and traced returned-A8s outputs each match400/400tone blocks with zero
stereo-zero/quiet/drop/timestamp-error/underrun. Their B/A readiness is
118.117/110.710ms and138.970/109.385ms. Four prepared boundary windows have
zero source/tap stereo-zero/underrun; readiness129.210/113.943/43.741/113.866ms.
Earlier intermittent zero-output/preparation/close failures remain unresolved.
This non-recurrence is inconclusive; no causal production repair is claimed.

Raw SHA256b4e410789871b07dff341db858a8ed45b93f33ac0bc7b4a75494032b2b604d59.
Artifact12570326447/73581030bytes/SHA256
60583b75d7d469fe5e79d24233f1387cb76f388e170cf5e30e76ca4e10085715
downloaded/checksum verified (1744entries). Local syntax/project/70-case source
checks pass for the corrected test source. Native17, full Release/HTTP and
physical-phone acceptance remain pending. No new TestFlight or signing.


### Native17: strict live-loop pass and first-copy boundary localized

Run40118261949/job120944048832 on publica6a85c7 completes with job13m32s,
owned716159ms/exit65/no timeout.123core/64native/1UI pass; all70selected
identities return. Five native cases fail, so no complete-profile acceptance.

The corrected live repeat-one case now passes14.121s, retaining its strict token
equality. All633600frames match the complete57600frame AAC reference over at least
ten whole loops/11visits (alignment0, one candidate). Zero stereo-zero/underrun/
drop/timestamp faults, stable running engine and visible/advancing A. This is
mono-projection/1e-6 and simulator evidence, with independent codec proof separate.

Natural initial preparation fails the original3s guard before a source publishes.
The29existing cached observations cover3.006339s with no drops; native lane0 moves
from startReading to first copyEntered/sequence1. At the failed guard and around
a responsive~12ms worker reply, the word remains20 (copyEntered,sequence1).
One leased reader, no packets, one pending read/preparation, all source tokens0.
Owned close succeeds. This localizes an unreturned native read wrapper; it does
not yet establish internal SDK wait versus scheduling or an underlying cause.
The natural transition and its new final-underrun assertion are not reached.

Other real failures: default B progress has35.792709ms PCM/wall skew against
26.333333ms while renderer underruns stay0; actual B full-window stereo silence
is unmeasured. Prepared B first video is555.76275ms and traced B270.069542ms
against250ms. A/B/A preparation also misses3s. Both actual returned-A8s audits
stay clean384000frames/400tones/zero stereo-zero/quiet/drop/timestamp errors.
No earlier intermittent audio failure is erased or causally repaired.

Raw SHA25668c76c2d2c8053ea141489387d26f405115b5778573e10ff503e36d92297b691.
Artifact12569434325/70778884bytes/SHA256
79e7d8daa75fd7035540452c5f0598277e1cbe2a8f2589ec4606c465dcdfb835
downloaded/checksum verified (1622entries). Its temporary file reference expired
once before local download; refreshed through the same read-only artifact API.

Next71-case source retains every70identity and adds the already-existing native
own-thread calibration case. No new test method, profiler framework or app/core
change. The natural case reuses NativeReaderWaitObservation and its existing
before-copy own-thread context note. Only after the unchanged3s guard fails does
it query up to three exact recorded threads, at most16frames each, with cached
copy words before/after. Records label the real observation calibration=false,
best-effort/noncoherent stack, possible brief kernel get_state stop and no proven
SDK cause. No thread sampling during the measured preparation, no new sampler
task, AVFoundation getter, cancellation/retry or relaxed budget. Native context
publication itself is added instrumentation; no individual timing attribution.
Closure acknowledgements control probe-right cleanup; uncertain closes retain
their native owner rather than fabricating success.

Local exact-helper Swift5 type check, syntax/project/source71/diff and3focused
evidence tests (7.483s) pass. The broader release manifest still contains295native/
UI identities and is unchanged. Native18/Release/streaming/phone acceptance and
actual root-cause repair remain pending. No new TestFlight or signing.


### Native18: actual sample-reader wait; bounded alternative capability study

Native18 terminal failure13m1total/12m56job, owned696727ms/exit65/no timeout.
Source public060dafab978b3d62abe292d37e921c68c9aaa5d5;123core/64native/1UI pass,
six native cases fail, all71 selected identities return. One exact slow-preparation
pass is split by adjacent stdout/stderr; result metadata records the reconstruction,
and original raw bytes remain untouched. Strict live ten-loop case again matches
all633600mono-projection frames,11visits,zero stereo-zero/underrun/drop/time faults.
Known wait calibration passes0.258s with its controlled gate, separate from the real wait.

Actual failure-only own-thread sample now qualifies lane0/copy7: beforeWord=afterWord116,
runState3, matching context/register checks. Bounded best-effort stack is
__psynch_cvwait -> _pthread_cond_wait -> WaitOnCondition -> FigSemaphoreWaitRelative
-> assetReader_ExtractAndRetainNextSampleBuffer -> AVAssetReaderOutput/
AVAssetReaderTrackOutput.copyNextSampleBuffer -> native ReaderLane.read.
This establishes a waiting sample-reader location at observation, not its producer
or underlying cause. Stack coherence remains false; kernel get_state may briefly stop.
Worker replies before/after failed3s close, but read stays pending; no source publishes,
close is not acknowledged, fixtures retained. Four later owners are refused correctly
and are not new playback measurements. Natural boundary/final-underrun gate not reached.
Initial cached coverage maxGap333.609ms also exceeds250ms. Default B video357.202ms
fails250ms; actual returned-A8s384000frames/400tones/zero fault audit stays clean.

Raw18 SHA25600e969b84fd6d763f3b29531301176becf348517c98ad40bbefface71d5e0aed.
Artifact12570928233/71702787bytes/SHA25625d3e5ec0e167c0e8ef663673bb14193b668c5ec02dd849beeff2c51e4e20111
downloaded/checksum/ZIP verified1650entries. Saved result JSON and gap-public18-result.png.

Full source audit falsifies the tentative missing-autorelease-pool explanation:
ReaderLane.start/read/close already wrap native work in explicit pools, completions
run after draining, and native samples are deep-copied into owned Float arrays.
Do not add redundant pools or guessed buffer increases. The loadCurrent prepared
fast path also can promote a cached entry; do not claim streaming never promotes.
Native-only HTTP/PCM boundary fidelity remains unqualified.

Next limited capability comparison: one test opens the same complete30s native48k
stereo MP4 with AVAudioFile, reads fixed4096frame buffers through EOF, closes it
before independently decoding the full original via existing AVAssetReader reference,
and compares every stereo sample at1e-6 with exact length/no trimming. Original3s
prefix budget remains. No production reader change. Profile72 retains every71case;
source-validator missing-case RED observed before insertion. Native capability result
is pending; no speculative replacement or TikTok/phone equivalence claim. Existing
source app/core trees, media, workflows, release controls and authorization unchanged.


Local exact-method Swift5 type-only check, Swift syntax, project/profile72 and Windows Git diff checks pass. WSL Git cannot resolve the Windows managed-worktree pointer; no Git repair attempted. The new comparison runs before the earlier decoder cases and changes reader warm history; neither a pass nor later nonrecurrence establishes causality. Existing native calibration and all71profile identities remain. Full source manifest now296; full release gate still requires all current cases. Native19 not yet launched. No new TestFlight.


### Native19: reject unqualified alternative; isolate API capability cheaply

Native19 terminal failure13m35total/13m31job; public60e55d2dc1ad40d18a0b87846514d49c227cccf0,
owned738648ms/exit65/no timeout.123core/67native/1UI pass, four native cases fail,
all72identities return. New AVAudioFile comparison fails0.769s with caught nilError
inside the pooled alternate-decode block, before any completed data/reference comparison.
Individual SDK phase is not recorded, so unsupported movie format is not proven and
the alternative is not adopted. Existing initial decoder ownership guard is intact.

Strict live ten-loop case passes again with633600matching mono-projection frames,
zero stereo-zero/underrun/drop/time faults. Natural boundary passes19.565s this time:
initial preparation2.581975s, coverage max109.239ms, final underruns remain70144 from
runway baseline (zero added; exact stereo silence unmeasured), original cleanup ack
passes. This nonrecurrence does not repair earlier3s native-copy waits or740ms silence.

Prepared B video272.565875ms and traced B276.685167ms exceed250ms; rapid A/B/A misses
its3s initial preparation. Two actual returned-A8s384000frame/400tone windows and four
prepared tap boundaries remain zero exact stereo-zero/underrun/drop/time faults.
Raw SHA256385f2240d52ddaf875f97053192e24c8584c0e9c7b6e12acc405fdd6d1973334.
Artifact12572183749/72009958bytes/SHA25621fe4cd80f5512282714a0d96764d6751bc2c680e77362ab6f41a1e0fb19fab4
downloaded/checksum/ZIP verified1660entries; result JSON and UI screenshot saved.

Next single-variable API investigation uses a small standalone macOS program instead
of rebuilding the full iOS app. Same original MP4, default versus configured-interleaved
AVAudioFile initializers, a generated exact stereo CAF control, bounded4096frame reads
to EOF, labelled open/format/buffer/read failure stage and exact frame count. It never
claims movie sample fidelity or iOS/physical playback acceptance. No production edit.
The temporary diagnostic-branch workflow executes only this named macOS capability
probe with no iOS tests; original profile72/full release gate remain intact and the
manual standard-public15min/no-secret controls stay. Restore its original focused-check
command after the probe; don't interpret this smaller experiment as a green full run.


### Native20: fast capability probe localizes failure to reads

Run40125063944/job120964613051, public354ffa74be1c733d0b81ffd21232f566b2b64619,
completes37s total/33s job, exit1. Program compiles and all four attempts execute.
Both original movie modes and both known-good generated stereo CAF controls throw
Foundation._GenericObjCError code0 at stage=read, so unsupported movie format is not
established. No sample-fidelity comparison or iOS/phone qualification. Artifact
12572074889/609bytes/SHA2566dcfb857d8a503e06f87eba6f043d32efe910c6b7e30328b003df63cc019b0e2
is downloaded/checksum/ZIP verified; log and UI receipt saved. No iOS app rebuild.

Next observation keeps the same read behavior and records successful-read/frame
counts, precise file positions before/after a failed call and its buffer frame count.
This will distinguish a first-read problem from a partial/extra EOF read; no EOF
error is ignored and no expected source length/sample threshold is changed. The
official read-count documentation requires matching processing format but supplies
no EOF guarantee. No production or test/profile/media/workflow change.

### Native21: complete data precedes an extra EOF-read error

Run40125365524/job120965525397 on publicd56160c records both movie modes have
already copied every1440000frame in352successful reads. Failing call starts and
ends at frame1440000==file.length with buffer.frameLength0; both known CAF controls
similarly complete4800frames/two reads before the extra call fails. Foundation
nilError therefore does not reject this decoder or its complete output. Artifact
12573585169/726bytes/SHA256b6513c2e43d81b51b9078cb6339053236788cc701321e1eccb8a72f5df08e208
downloaded/checksum/ZIP verified; raw log/result metadata saved. This is a defect
in the new comparison's EOF assumption, separate from the original playback wait.

Read only through the API's precise file length and require actual positive reads;
an early or ordinary read error still fails. Original expected length, every
stereo sample and1e-6 tolerance remain. Same correction in the unaccepted iOS
capability case; profile72 retains all identities. Standalone Mac probe additionally
compares both movie modes with a complete independent native48k AVAssetReader
reference, rejects unexpected trim/gaps/format/layout/length and compares every
stereo sample without padding or trimming. Exact CAF controls remain. This is
macOS API/sample fidelity only; no iOS/phone acceptance or production decoder change.

### Native22: complete native48k stereo equality, macOS API proof only

Run40125724752/job120966589326 on public3d50c6d succeeds31s total/26s job.
Both default and configured AVAudioFile modes decode all1440000frames in352reads,
complete against an independent AVAssetReader native reference, maximum sample
difference0/no mismatch/nonfinite. Read times1084.261ms and1358.060ms for the entire
30s; exact stereo CAF controls pass. No source trim/padding or tolerance relaxation.
Artifact12573700766/746bytes/SHA256d572e9a89a19f80bb627dffb218d4d20e95669315586700f46f7c81763f8ba0e
downloaded/checksum/ZIP verified. Saved raw/result JSON/UI screenshot. This is not
iOS, live graph, cold HTTP, physical output, whole profile or release acceptance.

Before the production candidate, retain the precise original track segment mapping
and AudioFilePacketTableInfo priming/valid/remainder fields in the same small probe.
This read-only metadata measurement establishes a conservative eligibility check
rather than assuming AVAudioFile applies every possible movie edit. Full sample
comparison/controls/read bounds remain identical. Candidate scope is initially
simple native48k stereo AAC only, with other layouts/edits/codecs preserving the
existing native reader. Original whole-goal scope remains; this is not its completion.

### Candidate: conservative native AAC file-reader path

Mac23 run40126190417/job120968010697 on ef41840 succeeds. Complete sample equality
remains maxDifference0; one audio segment has sourceStart1024/48000, source/target
duration30,targetStart0. CoreAudio packetTable status0, valid1440000/priming1024/
remainder768. Artifact12573241910/885bytes/
b1e94470f3c40c9e21386e8173c8277372ab5d4b37715c6e746026c67ebef5c7 verified.

AudioFilePresentation canonical RED observed with always-rejecting API scaffold;
nine edit/offset/incomplete cases already reject. Implemented exact native-frame/
codec-priming/valid-frame agreement, focused2tests and complete125core pass locally
(1.403s test runtime). This is source/policy evidence, not Apple graph qualification.

New NativeAudioFileReader.swift owns only a native48k stereo AAC file in the same
ReaderLane. Exact one-track/single-format/unscaled/nonempty/native-grid metadata,
packet-table agreement, precise complete endpoint and exact processing format are
required. Unknown/edited/other-format sources retain NativeReader unchanged.
Open/seek/read/release stay lane-owned; no reader or borrowed buffer crosses it.
Read count is bounded4096/remaining, positive progress/position checked, zero only
at declaredEOF, no sample padding/trimming. Existing C++prefix/ring/leases and
owned packet budgets unchanged. Debug read gate/stages are preserved with closures
that retain only existing record/gate/scalar values, never a lane/reader cycle.
No cloud/Saved/cache, playback intent, queue, DSP, background or PiP policy changes.

Ruling: separate the actual SDK reader source so the small Mac probe compiles and
exercises that exact component plus the real pure policy, optimized without DEBUG,
before the full iOS check. Probe compares complete1440000frames plus distant28s/7s
seeks with original2s preroll, <=192read work, exactEOF and1e-6 samples. Metadata
adapter/full app/DEBUG hooks are not proven by this smaller component check.

Local Swift syntax, generated project and profile73 checks pass. Every prior72case
remains, plus the existing edited-offset/4800leading-silence regression. Full native
manifest remains296, with125portable tests. App runtime is now a candidate change,
not a causal-fix or TestFlight claim. Original waits,740ms silence,250ms video/3s
preparation failures and full release/HTTP/phone acceptance remain open until checked.

### Native24: actual optimized reader component passes before iOS run

Run40127633775/job120972364243 on publicb240b5b86d5d3309ace0e7615f8fb16101b9d505
succeeds. It compiles the exact NativeAudioFileReader.swift and real core
AudioFilePresentation.swift with-O, without DEBUG, in the small Mac program.
The actual reader opens through all strict gates and compares every1440000frame
against the complete independent source,352reads,maximumDifference0,no nonfinite
or mismatch,EOFread0/reachedEndtrue. Forward28s and backward7s targets each compare
512frames after the original2s preroll,24reads apiece,zero sample difference,correct
cursor and no falseEOF. CAF controls and direct file modes remain exact. No trimming,
padding,tolerance/buffer/deadline change or whole-source runtime array was introduced.

Artifact12572679324/1037bytes/SHA256
7c2f7c769526f11952113ee7eb0fe5294d55b7871f9c8182455f29b75e0503cb
downloaded/checksum/ZIP verified. Raw log/resultJSON saved. Full app, DEBUG hooks,
metadata adapter, pipeline/HTTP/background/PiP, Release app and phone acceptance
remain unqualified by this smaller component check. Earlier real failures remain.

Restore the original manual standard-public15min unsigned focused iOS workflow
byte-for-byte from its preserved pre-capability backup. Next native profile73 keeps
all72earlier cases and adds the existing edited-offset case. Core125local already
passes; full current-source native manifest296 is retained. No signing/new TestFlight.

### Native25: iOS decoder proof and bounded-check exhaustion

Public3de1b5c/run40128027553/job120973541645 is cancelled at the15min job limit.
The provider reports17m8total/17m3job including orphan cleanup after cancellation.
Core125passes. The app's optimized DEBUG source and metadata adapter compile;
60native cases finish57pass/3fail, with13of73 lacking completion and UI not begun.
Complete native48k AVAudioFile comparison passes2.313s, all1440000stereo frames,
maximumDifference0; distant28s/7s pipeline seeks each use26copies, exact512frames,
full endpoint and unchanged memory. Leading4800frame presentation silence and
retained-source regressions pass. Strict ten full short-AAC live loops again match
all633600frames, zero added underruns/exact stereo-zero frames, same engine.

Unresolved: defaultB video317.093625ms>250; natural3s initial both-source guard
misses readiness with2345.760167ms sampler gap, no later pending read/SDK wait
established and real decoder close acknowledged; compositor capture rejected3.
One8s returned-A audit and four prepared tap boundaries show no exact stereo
silence, but the traced production case is interrupted and has no terminal result.
The original740ms silence witness, other formats, full source296/Release, trueHTTP
and phone acceptance remain open. No new TestFlight or all-gap repair claim.

Artifact12574132062/353921bytes/SHA256
3f0e47825670ca48d1a848fb340c636a78eadfb684e8979c51c3d79b3035d02c,
ZIP144entries verified. Raw job log SHA256
ffc9d74de14ebc6820e3a704eb90c4df49f2b615500b1f1cacbec8ca8a6b21cc.

Pre-test build and startup consumed about10min. Final build Touch20:09:42.793,
first native case20:14:30.952; compile/build was about5m23 and later startup4m48.
Split the next manual unsigned
check into one build-for-testing job and one test-without-building job, each
standard-public/macOS26/15min. Carry exact-source compiled products in a one-day
artifact; verify source, Xcode/SDK/architecture, profile and every binary checksum
before extracting. Original73cases/assertions and per-case120s limits remain;
new owned profile-build/profile-test phases each720s leave room for evidence.
The old full/default/release command and original phase budgets stay unchanged.
This changes check orchestration only, not playback, and cannot excuse failures.

### Native26: build succeeds; new CLI handoff error reproduced and corrected

Run40130132409/source88414a1: buildjob120979889642 succeeds4m48, owned build
198625ms, exit0/no timeout,125core pass. Exact compiled-product bundle174files
archives successfully. Testjob120980991483 fails19s before native execution:
main() passed --products/--archive in the wrong order to unpack(). Its guard
message referred to the wrong argument; this does not establish a stale folder.
An actual CLI round-trip regression reproduces RED locally, then all8transport
methods pass0.389s after explicit pack/unpack dispatch fixes the argument order.
Identity/checksum/overwrite protections stay; app/core and73case manifest unchanged.

All three artifacts downloaded/SHA/ZIP verified. Products12573834828/36219673bytes/
083771874d406826830b5959b7da4c8de73c711742c3cc0f93176e9ee0556f83;
build evidence12574114524/37619bytes/530d450a2dee63bc201884d7941850638b883c41d6c70e6bcdc29ad148aa6b83;
empty native evidence12574757595/154bytes/96fed3f27968455d88f5d4fea77bec9e78e5de45653e40f9292f557a978e5552.
Raw logs/result/screenshot/context retained. Actual xctestrun test/host paths use
__TESTROOT__/__TESTHOST__, preserving product portability. No native acceptance,
video/preparation repair, full Release or delivery claim from this failed handoff.

### Native27: full focused check completes with remaining picture failures

Run40130855404/source106f28c completes failure17m57total. Build6m36/core125pass;
testjob11m13, owned297818ms build/620371ms test, no timeout. Same-run174compiled
files pass exact-source/SDK/profile/checksum verification. Native console contains
69native passes/2fails/1UIpass plus one manual nativepass1.649s whose class name is
interleaved with two SDK messages. Keep that manual tier separate: strict verifier
still rejects it along with the two real failed cases and failed-run marker.
Expected73identities accounted for, whole run red. No parser tolerance change.

Two compositorcaptures reject3. Prepared B302.191125ms exceeds250ms; default B
237.667584ms and traced B153.035292ms pass. Cold default picture1616.294542ms is
within its3s guard and is not an instant-picture result. Both returned-A8s audits
have384000frames/400tones/zero exact stereo silence or underruns; four prepared
tap boundaries are also clean. Strict633600frame ten-loop comparison matches.
Natural baseline/final underruns1536/1536, no added underruns; exact stereo silence
there is unmeasured. Whole native48k1440000frame reference and two26-copy distant
seeks remain exact. Earlier real silence witnesses, full296/Release/trueHTTP and
phone acceptance remain open. No TestFlight delivery.

Evidence12575197291/71035985bytes/SHA256
b5303d6a1a71e9a572e063bb7bc3bb9be468a9303e3e5964ff27d8ae194b0da4,
1650ZIPentries verified. RawjobSHA256
20bbb2bae1024e6dbfdb8ed79fdfa39eb19fdd2ad04e827de94c8cff2b1383e2.

Next: small native44.1k stereo AAC API proof. The actual reader still admits only
48k; no broader-format repair claim is supported by that restriction. Synthetic
FFmpeg AAC video and Apple AAC audio exercise full native samples and codec
priming/mapping. Current component rejection is the expected pre-implementation
RED, while complete independent SDK references establish any viable extension.
No runtime change yet. Temporary manual/public15min API-only workflow clearly
excludes iOS acceptance; preserve/restore the full split-check workflow afterwards.
All73profile identities and full296source methods stay in source unchanged.

### Native28: complete native44.1k API references establish the extension

Run40132783759/job120987876956/source dc381716 is the pre-implementation RED.
Both synthetic inputs decode all1323000native stereo frames with maximumDifference0
in both AVAudioFile modes against complete independent AVAssetReader references.
FFmpeg AAC maps sourceStart1024/44100,valid1323000/remainder8; Apple AAC maps
2112/44100,valid1323000/remainder968. Both target the complete30s presentation at0.
CAF controls pass. The actual48k-only component rejects both, as expected; no iOS
or playback acceptance from this macOS API-only check. Artifact12575543240/1183bytes/
SHAf44d39b890b26f7169fd3b8b7ed31a06afaf2aea0e660640e24d80ff16af1910 verified.

Candidate extension: accept explicit44100 or48000stereo AAC native processing
format and complete native-frame endpoint. Resampled readers must start0; the
existing native48k seek preroll stays. Metadata mappings use the selected native
grid and require an exact whole endpoint before packet-table matching. Renderer
endpoint stays48k; existing explicit converter/history/flush,4096-frame packets,
ring/prefix/lease bounds, streaming/cache intent and lane-owned close stay unchanged.
No content trim, fabricated agreement padding, weaker tolerance or deadline.
One new iOS regression admits the representative stereo AAC, compares complete
post-SRC output through two graph loops and rewind, and acknowledges decoder close.
Every previous73profile identity remains; new profile74/full source297. Local
Swift parsing, generatedproject and profile checks pass; SDK component GREEN and
iOS SRC/graph/Release/HTTP/phone acceptance remain pending. Prior picture failures
and exact-silence witnesses remain open, with no new TestFlight.
