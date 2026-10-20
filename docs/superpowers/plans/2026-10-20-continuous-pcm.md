# Continuous PCM playback: design and implementation plan

12.1 is a preserved release, not an accepted gapless implementation. Its AVQueuePlayer
handoffs measured hundreds of milliseconds to progress; all six measured successors
were not ready before handoff. Item clocks did not measure the audio sample stream.
The owner still hears gaps and reports that OnTrac camera pauses PiP, then playback
resumes on camera close. This does not establish that the camera takes an exclusive
audio session. Existing PiP delegates do not explicitly pause playback.

## Contract

Use one persistent AVAudioEngine/AVAudioSourceNode with predecoded PCM. A prepared
boundary copies outgoing and incoming frames in the same render request. Preserve
the full presentation timeline, including real silence; no threshold trimming or
hidden crossfade. Keep one Speaker processor across boundaries. The muted video
surface follows the audio clock; video/PiP suspension cannot itself pause audio.

Own three fixed slots, each with a two-second starting prefix and four-second
streaming ring at 48 kHz stereo Float32 (about 6.6 MiB PCM total). A single serial
worker decodes and replenishes them. The render callback cannot decode, allocate,
lock, dispatch, log, or access files. Atomic epochs protect stream resets and fixed
slot leases protect reuse. Prepared means decoded samples exist. Starvation is
counted explicitly and fails continuity tests. A cold unavailable source cannot
promise immediate output; preserve that distinction in measurements.

Keep playback intent independent of presentation state. Explicit Pause wins over
late preparation, route changes, foregrounding and interruption completion. Audio
session interruption still requires shouldResume and successful activation. Keep
playback/default/mixWithOthers. No microphone permissions or attempts to override
another app's exclusive session. Public PiP and lifecycle callbacks can support
audio-only fallback; no API identifies another app opening its camera.

## Implementation order

1. Add failing sample-output tests for the production render kernel: boundaries
   inside blocks, genuine zero samples, repeated reversals/loops, EOF, pause,
   stream epochs and bounded memory. Implement the fixed-slot kernel.
2. Add one serial AVAssetReader worker and native compressed-fixture tests. Use
   presentation timestamps and decoded valid samples; do not infer trims from
   amplitude or catalog metadata.
3. Connect SourceNode to the persistent engine. Mute video, prepare adjacent local
   sources, drive video/UI from audio visits and host-time anchors, and retain
   explicit intent/interruption/seek guards. Keep cache/Saved privacy boundaries.
4. Add capped, local-only diagnostics and presentation policy tests for PiP loss,
   app state, interruption reason/options, route/configuration and activation.
5. Run one-job portable checks, then standard free public Apple validation. Test
   actual SourceNode manual-render output in Original and Speaker modes with
   compressed fixtures. Review the complete diff before any release coordination.

## Acceptance and device gates

No inserted, omitted, repeated or stale frames in prepared sample-output tests;
zero underruns in those cases; exact source zeros and full end frame retained;
bounded allocations across repeated next/previous and long streaming sources.
Native tests cover the real engine graph, not just AVPlayer clocks. Route, seek,
background, interruption and explicit pause races must preserve intent.

Physical speaker output, hardware latency, A/V sync, Bluetooth/AirPlay, PiP controls,
and OnTrac camera behavior require the owner's iPhone. Diagnostics distinguish
presentation suspension from session interruption; offline tests cannot establish
another app's policy or guarantee physical output. No new private signed build or
upload is authorized by this implementation plan; 12.1 remains available.

## Primary references

- https://developer.apple.com/videos/play/wwdc2019/510/
- https://developer.apple.com/documentation/avfaudio/avaudiosourcenode
- https://developer.apple.com/documentation/avfaudio/performing-offline-audio-processing
- https://developer.apple.com/documentation/avfoundation/avplayer/setrate(_:time:athosttime:)
- https://developer.apple.com/library/archive/qa/qa1636/_index.html
- https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/HandlingAudioInterruptions/HandlingAudioInterruptions.html
