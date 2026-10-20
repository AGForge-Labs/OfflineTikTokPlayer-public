# Continuous PCM validation

This candidate replaces item-owned audio with a persistent AVAudioEngine and
AVAudioSourceNode. It is a draft, not a device acceptance or release claim.

**Device acceptance failed for build 13.1.** Selected videos did not reliably
appear or match the playing source on the owner's iPhone. The historical passing
run below did not cover those visible-frame regressions and does not establish
release readiness. The selected-video repair is undergoing full unsigned
validation; no repaired signed build has been accepted.

The repair preserves a cold selection on preparation failure and stops the old
audio source before waiting. It publishes deselection acknowledgement, scopes
video synchronization to its selection generation, re-arms first-frame readiness
after seeks and updates paused/restored display time. Host-clock video scheduling
always disables automatic stall waiting, as required by Apple's `setRate` API.
It does not change the PCM timeline, source samples or three-slot allocation.

Pre-fix runs [39384290017](https://github.com/AGForge-Labs/OfflineTikTokPlayer-public/actions/runs/39384290017)
and [39386077449](https://github.com/AGForge-Labs/OfflineTikTokPlayer-public/actions/runs/39386077449)
reproduced cold selection skipping, stale audio and invalid external-clock waiting.
The latter also showed actual compositor images containing only the opaque poster
after restored and natural positive-offset selections; baseline A/B/A movie pixels
and independently decoded tones worked. Failed runtime fixture setup is separate
from that evidence. Fixed synthetic moving/tone resources now avoid runtime encoding.

Run [39389451153](https://github.com/AGForge-Labs/OfflineTikTokPlayer-public/actions/runs/39389451153)
reported success, but its log contains a macOS Bash 3 empty-array expansion error
before `xcodebuild`. Only its 81 core tests and Apple buffer harness ran. It is
**not native validation**. The launcher now uses safe positional arguments and
explicitly preserves exit status during helper cleanup. Isolated launcher tests
check full/focused native arguments, failure propagation and helper termination.

The actual full run [39390046275](https://github.com/AGForge-Labs/OfflineTikTokPlayer-public/actions/runs/39390046275)
at `a8eec0d50e9660f5740f7c6eebd427f5894fb7c0` passed 81 core tests and one UI
test, but reported three failures across two of 88 native tests. Cold-selection
retry/pause, waiting policy, A/B/A, rewound video, rapid final-selection
acknowledgement and foreground restoration passed. Actual compositor movie-color
fractions were about 0.898 with zero magenta poster coverage; independent AAC
tones had RMS about 0.141 and the correct 440/880 Hz energy.
The paused restored B frame still showed time zero. Natural-boundary setup timed
out before video assertions while waiting to observe A's final 250 ms; that log
cannot distinguish a missed window from cold far-seek refill time. This is a
failed candidate.

The next repair refreshes a paused requested frame through the existing service
poll while audio selection remains unacknowledged, re-synchronizes after late
output attachment and resets the display epoch after completed native seeks.
Its regression also checks short backward and coalesced paused seeks without
starting audio; completion converges on the latest requested PCM-frame target.
Natural-boundary setup observes real progress with two seconds of runway or an
already-rendered B, then retains strict identity/positive-offset/moving-pixel
checks. Cold far-seek setup is not a prepared-transition latency measurement.
Full acceptance now requires exactly all 88 native and one UI identities plus
`TEST SUCCEEDED`, independently of job status. Five launcher and eleven evidence
guard regressions cover missing UI, partial/skipped/failed/retried results, first
error propagation, stale-log clearing and cleanup. Native acceptance is pending.

## Reviewed scope

Base: `5ae95b42d89cbdbd5a6b93ef3202f9ed57603881`.
Source candidate: `dfc18938bac2d6f75d6de2fdc886035acfddcae0`.
Source tree: `be9d7a859f52950036de508baa62d97fce9e8411`.
The reviewed source diff has **25 files, 4,316 additions and 222 deletions**,
including a 30,719-byte public synthetic MP3 fixture (binary bytes are outside
the line counts). This report is additional prose.
Changes cover the
PCM renderer/decoder, audio service, muted video and custom PiP controls, local
diagnostics, settings, regression tests, project references, the public-only
unsigned validation workflow and its design plan. No signing/release workflow,
private media, credentials, downloaded library or private history is included.

Three fixed PCM slots own **6,912,000 bytes**: each has a two-second starting
prefix and four-second streaming ring, at 48 kHz stereo Float32. Decoder packets,
scratch space, framework decoder resources and video surfaces are additional;
this number is not an iPhone resident-memory measurement. One serial worker
replenishes the current source before speculative neighbours.

The decoder requests and verifies precise asset timing, reads the complete finite
asset/track presentation at native rate, and explicitly drains AVAudioConverter
at EOF. It intersects straddling decoder packets with that declared presentation
after codec trims; raw decoder postroll cannot change the loop length.
Presentation time is quantized to the nearest 48 kHz frame. If that final frame
falls inside the source duration but the converter rounds down, bounded native
end support lets the converter calculate it. This adds no output frames beyond
the original quantized timeline and does not replace missing decoded audio with
zeros. The regression requires an unchanged earlier sample sequence and a nonzero
computed final frame.
Only declared codec trims and presentation timestamps control placement; source
amplitude never removes frames. Reopening reproduces conversion history from the
beginning with bounded storage. A distant seek discards at most eight converted
buffers per worker visit before yielding, so retained old work cannot monopolize
refill of the new current source. Distant uncached seeks can still take preparation
time; bounded memory does not make arbitrary decoding instantaneous.

The renderer copies the last outgoing and first incoming frames in one render
request. Prepared Next/Previous commands apply at the next render boundary.
Speaker processing keeps its state across ordinary source boundaries; Original
bypasses it. There is no silence threshold trim, crossfade, early end seek, or
video-readiness dependency in the audible path.

## Verification record

Final unsigned Apple run [39373935851](https://github.com/AGForge-Labs/OfflineTikTokPlayer-public/actions/runs/39373935851)
succeeded at the exact source candidate above: **81 core tests, 77 native tests
and one UI test, all with zero failures**. It used Xcode 26.6, the iPhone 17 Pro
Max simulator with iOS 26.5, `-jobs 1 -parallel-testing-enabled NO` and
`CODE_SIGNING_ALLOWED=NO`. The project check and Apple buffer harness also passed.
The native log ends with `TEST SUCCEEDED` at 2026-10-20 05:23:11 UTC.

Selected final decoded-output measurements:

| Fixture | Full output frames at 48 kHz | Converted peak | Evidence |
| --- | ---: | ---: | --- |
| Generated AAC | 12,345 | 0.219673 | No extra codec padding in the presentation |
| AAC video | 57,600 | 0.130452 | Full 1.2-second presentation |
| ALAC compatibility video | 58,992 | 0.197710 | Full 1.229-second presentation |
| Standalone MP3 | 60,186 | 0.197726 | Precise full presentation stable across repeated readers/preparations |
| 9,801 native frames at 44.1 kHz | 10,668 | 0.223614 | Earlier 10,667 frames unchanged; computed final frame nonzero |

The MP3 reader still exposed 529 native frames outside its precise presentation
in this run. They are reported separately; they cannot extend the loop. This
uses packet timing and the declared interval, not a fixed 529-frame trim. Every
compressed fixture now requires nonzero audio, so matching silent arrays cannot
satisfy the audible-fixture tests.

The earlier runs below record diagnosis and failed intermediate candidates:

- Red/green portable tests establish exact samples, 2,000 loops, 1,000 reversal
  pairs, full tails/real zeros, stream wrap/restart/seek epochs, pause, EOF,
  starvation accounting, safe retirement and bounded storage.
- All **81 PlayerCore tests** passed on Linux Swift 6.2.3 with `--jobs 1`.
  Twelve exercise the continuous PCM kernel. All 81 also passed in public Apple
  run `39371235012`.
- Generated-project consistency, Swift syntax parsing and whitespace checks pass.
- First Apple job: core passed; app compilation found a duplicate diagnostic code.
  Corrected in `1fe8a1f`.
- Second Apple job: core passed; app compilation found a shadowed entry lookup.
  Corrected in `9843db4`.
- Apple run `39369007128` at `a40f69154ee30f68eafed138493cd769f8919d57`
  compiled the app and tests, passed the actual SourceNode Original/Speaker
  boundary test, all 17 playback-service tests, five custom PiP tests, nine
  presentation-policy tests, four journal tests, and the UI shell test.
  It failed seven assertions in four decoder tests; it is not an acceptance run.
- Packet diagnostics showed the independent AVAssetReaderAudioMixOutput reference
  itself returning 51 fewer 48 kHz frames than the declared converted timeline,
  with contiguous packet timestamps and no trim attachments. Replacing missing
  decoded content with zeros is not accepted. The conversion path now uses
  native-rate decoding and explicit end-of-stream converter draining.
- Apple run `39371235012` at `e425aca9d4c85187939d73572427ad0405bada28`
  compiled the app and tests and passed 81 core tests and the UI shell test.
  Of 75 native tests, two decoder cases failed six assertions because 9,801
  native 44.1 kHz frames converted to 10,667 frames instead of the quantized
  10,668-frame presentation. This is a failed intermediate run. The other decoder
  cases, including true standalone MP3 loops/reversals, passed. The current bounded
  end-support fix retains the strict full-length assertion instead of rounding
  down the content or padding the output with a silent sample.
- Review found and fixed command acknowledgement races involving paused seeks,
  natural boundaries, superseded selections and delayed decoder failure. Exact
  render-command versions now govern acknowledgement and queue adoption. Unknown
  retired decoder callbacks cannot clear the current source's prepared loop.
- Apple run `39372695784` at `8eb3fd2943b6a41f5f7165f6967e8c621377dec1`
  passed 81 core tests and the UI shell test. Of 76 native tests, one MP3 count
  assertion failed; all fractional-frame, streamed resampling, audio-service,
  PiP, policy and journal tests passed. The independent unbounded MP3 reader
  returned a packet ending 529 native frames beyond the declared presentation,
  while preparation reported the declared 60,186 output frames. This remains a
  failed intermediate run. The precise, finite presentation-range repair and
  repeated nonzero-output regressions passed independent review; no fixed
  529-frame or amplitude-based trim is applied.
- Final validation of these repairs is the successful run recorded above.
- Full unsigned Apple validation includes the real SourceNode graph, AAC/ALAC/MP3
  samples, 44.1 kHz converter drain and streamed history, full presentation
  offsets/source zeros, prepared reversals, retained far-seek scheduling,
  explicit Pause, interruption/activation, queue completion, memory pressure
  and PiP pixel/control fixtures.

The sample-output measurement is the number and value of frames at the boundary:
prepared joins must have **zero inserted, repeated or omitted frames** and zero
underrun frames. Native compressed tests exercise three complete MP3 loops,
a natural next boundary and eight Previous/Next reversal pairs in the actual
SourceNode graph. A separate running-service test exercises ten reversal pairs
while muted video pauses, with at most three prepared audio sources. These are
controlled continuity checks, not a wall-clock measurement of button-to-speaker
latency on the owner's phone. Legacy AVQueuePlayer clock metrics in the test log
exercise the retained video buffer; they do not measure this candidate's audible
PCM path.

Public review: https://github.com/AGForge-Labs/OfflineTikTokPlayer-public/pull/2

Apple validation runs:

- https://github.com/AGForge-Labs/OfflineTikTokPlayer-public/actions/runs/39366726230
- https://github.com/AGForge-Labs/OfflineTikTokPlayer-public/actions/runs/39367013671
- https://github.com/AGForge-Labs/OfflineTikTokPlayer-public/actions/runs/39367350156
- https://github.com/AGForge-Labs/OfflineTikTokPlayer-public/actions/runs/39369007128
- https://github.com/AGForge-Labs/OfflineTikTokPlayer-public/actions/runs/39371235012
- https://github.com/AGForge-Labs/OfflineTikTokPlayer-public/actions/runs/39372695784
- https://github.com/AGForge-Labs/OfflineTikTokPlayer-public/actions/runs/39373935851

## Diagnostics and limits

The local journal retains 128 numeric/enum events. An explicit Settings action
exports a report capped at 256 KiB. It records audio intent/permission, interruption
reason/options/suspension, route/configuration, PiP state, engine state and renderer
underruns. Complete initial decodes also report source head/tail frames below
−60 dBFS, independently of underrun frames. This diagnostic threshold never edits
PCM. Partial decodes and seeks do not invent a full-source silence measurement.
Reports contain no media IDs, filenames, URLs, titles, account/device identifiers,
error descriptions, microphone audio or automatic uploads.

Prepared continuity and cold preparation are different contracts. The PCM path
requires a Saved file or verified local playback-cache file. The encoded cache
retains its existing 256 MiB budget; larger media needs a Saved local copy. Cold
or unavailable remote media cannot promise immediate output. Real source silence
and a genuine discontinuity between source end/start remain part of the content.
Precise timing can also add cold parsing time for formats without complete timing
summaries; approximate timing is rejected instead of being used to shorten content.
Sample continuity is not a zero-latency hardware guarantee.

Video/PiP suspension has no authority to pause audio. Supported custom PiP Play,
Pause and Skip commands reach the audio owner explicitly. Backgrounding gives
automatic PiP time to start; confirmed suspension/loss supports audio-only fallback
and safe inline restoration. The app cannot detect another app opening its camera.
It keeps playback/default/mixWithOthers and cannot override an exclusive session.
An interruption still requires shouldResume, preserved user intent and successful
activation before automatic resume. No microphone/camera permission was added.

## Device and release gates

The owner's iPhone must verify physical speaker output, actual A/V sync and latency,
long-clip resident memory/CPU, headphones/Bluetooth/AirPlay, PiP Play/Pause/Skip,
background/lock/foreground, and camera use in the external work app. Collect the
local report around camera open/close to distinguish PiP suspension from an audio
session interruption. Offline rendering cannot establish another app's session
policy or prove uninterrupted physical output.

For the approved device candidate, use Saved media so download preparation does
not confound the result. Exercise repeat-one, queue completion and repeated
Next/Previous in Original and Speaker modes. Compare known synthetic boundary
tones and real source silence with the local underrun counter; a source's own
silence or end/start waveform discontinuity is not proof of an inserted gap.
Video readiness and physical A/V synchronization require their own observation.

Open and close the work-app camera first with PiP, then with Audio only selected.
Compare PiP suspension/loss events with interruption-began/ended, engine state
and route events. A PiP-only loss should leave audio moving. A genuine interruption
may stop it; automatic resume requires shouldResume and successful activation.
Repeat while explicitly paused, pause during the interruption, and foreground
the player afterward: none may override the user's Pause. If the camera takes
an exclusive session, record that limitation rather than claiming to defeat it.

Build 13.1 was withdrawn from the owner testing offer after device acceptance
failed. The private source was reverted normally to the shipped 12.1 tree while
the failed source was preserved separately. No repaired signed build, archive,
upload or TestFlight distribution has run. A separate release approval is
required before another signed candidate/device test build.

## Apple references

- [Audio interruptions](https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/HandlingAudioInterruptions/HandlingAudioInterruptions.html)
- [Source nodes and real-time rendering](https://developer.apple.com/videos/play/wwdc2019/510/)
- [Offline engine processing](https://developer.apple.com/documentation/avfaudio/performing-offline-audio-processing)
- [Sample-rate conversion, TN3136](https://developer.apple.com/documentation/technotes/tn3136-avaudioconverter-performing-sample-rate-conversions)
- [Declared codec priming/remainder, QA1636](https://developer.apple.com/library/archive/qa/qa1636/_index.html)
- [Asset-reader presentation range](https://developer.apple.com/documentation/avfoundation/avassetreader/timerange)
- [Precise media timing](https://developer.apple.com/documentation/avfoundation/avurlassetpreferprecisedurationandtimingkey)
- [Host-clock scheduling and automatic waiting](https://developer.apple.com/documentation/avfoundation/avplayer/setrate(_:time:athosttime:))
- [Sample-buffer PiP playback commands](https://developer.apple.com/documentation/avkit/avpictureinpicturesamplebufferplaybackdelegate/pictureinpicturecontroller(_:setplaying:))
