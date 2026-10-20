# Media fixtures

The four test MP4s are color/tone inputs for playback and audio compatibility checks. The base video is one solid color with a 440 Hz tone; the slideshow uses two solid colors with a 660 Hz tone. The MP3 variant is derived from the slideshow, and its iPhone compatibility variant has ALAC audio. Each video contains 36 frames at 256 by 454 pixels, lasting about 1.2 seconds.

Historical FFmpeg commands for the base inputs and MP3 derivative were recovered during private review. Every decoded frame is spatially uniform. Container and stream tags contain ordinary encoder/format fields. These files contain no user photos, captions, speech or collection media. Native iOS behavior still needs its own validation.

`ios/OfflineTikTokPlayerTests/Fixtures/test-tone.mp3` is a standalone MP3 fixture losslessly demuxed from the existing public `test-slideshow-mp3.mp4` synthetic 660 Hz tone. It contains no video, user media, speech, credentials, or external third-party recording. No additional content license is introduced; its provenance is the same project-generated synthetic input. Its MP3 container timing and priming metadata are independent of the original MP4 edit list. The iPhone-compatible `test-slideshow-mp3.iphone.mp4` derivative contains ALAC and is identified as ALAC in native decoder tests.

The standalone file was made with one FFmpeg thread and stream copying, without decoding/re-encoding:

```powershell
ffmpeg -hide_banner -loglevel error -threads 1 -i ios/OfflineTikTokPlayerTests/test-slideshow-mp3.mp4 -map 0:a:0 -c:a copy -map_metadata -1 -id3v2_version 0 -write_id3v1 0 -write_xing 1 ios/OfflineTikTokPlayerTests/Fixtures/test-tone.mp3
```

The file is 30,719 bytes with SHA-256 `c1360da578e7878e64d6f73634cff9bf9f00a77278e6a16ad2d6f89f1f119101`. SHA-256 over the copied encoded audio packets is `7b5c46b6c23ff848a25b027402967cb56be6e9da29566286781b61394fad4bbd` for both source and derivative. FFprobe reports mono MP3 at 44.1 kHz, start 0.025057 seconds, and container duration 1.253878 seconds; native tests must use the new file's presentation metadata rather than assuming the MP4's 1.207007-second edit duration transferred.

Importer URL fixtures use consistent fixture_creator identities and short synthetic IDs. Token-like query values are redaction-test markers rather than account credentials. Runtime authenticated libraries, imported catalogs, cached media and session state stay outside source.

## Selected-video compositor fixtures

`Fixtures/test-selection-a.mp4` and `Fixtures/test-selection-b.mp4` are generated
entirely from FFmpeg color, overlay and sine sources by
`scripts/generate-selection-fixtures.py`, using one encoder worker at a time.
Both contain 30 seconds of 160 by 96 H.264 video at 24 fps and 48 kHz stereo AAC.
A is red with a 440 Hz tone; B is green with an 880 Hz tone. A blue 16 by 24 pixel
marker moves every eighth of a second, using a chroma-aligned ten-pixel X step
modulo 144 and advancing one 24-pixel Y row after each 72 steps. Its 240 distinct
two-dimensional positions do not repeat within the 30-second clip. Accepted
motion captures must fit within 29 seconds of wall, media and PCM time, with no
loop or ownership change. Actual decoded pixels verify every marker position.
These files contain no user recordings.
Native tests independently decode their tones and inspect actual Simulator
compositor screenshots for source color, poster exclusion, marker motion and a
restored paused frame's marker position. The tests do not encode media at runtime.

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| test-selection-a.mp4 | 394,956 | `2b9d994c23eb3337f3c2198fe65081e61abc73e2c21caa0351f0c6c6ace2c999` |
| test-selection-b.mp4 | 394,889 | `e616c8a5bf839697ccbb77d452480f90462a166afd0dbb85d04dec087b8ec6b5` |

The offset-preservation decoder test separately exports lossless PCM in MOV. It
asserts the nonempty edit's exact 0.1-second offset, the complete 0.35-second
presentation, all 4,800 leading quiet frames and all 16,800 converted frames.
An AAC export can quantize that composition's duration, so it is unsuitable as
an exact 16,800-frame reference for this lossless placement regression.
