"""Build a bounded, verified streaming derivative; never edit the archived source."""
from dataclasses import dataclass
from fractions import Fraction
import json
import math
from pathlib import Path
import re
import subprocess
from tempfile import TemporaryDirectory


PROFILE_VERSION = 1
EQ = "bass=g=2.5:f=150:w=0.75,treble=g=1.75:f=3200:w=0.8"
TARGET = "loudnorm=I=-11:TP=-2:LRA=11"


@dataclass(frozen=True)
class Enhancement:
    path: Path | None
    audio_mastered: bool
    picture_upscaled: bool
    original_lufs: float | None
    output_lufs: float | None
    output_peak: float | None


def picture_dimensions(video):
    """Only reconstruct SDR 8-bit square-pixel video in its original orientation."""
    width, height = video.get("width", 0), video.get("height", 0)
    if (min(width, height) <= 0 or min(width, height) >= 1080 or max(width, height) >= 2160
            or video.get("pix_fmt") != "yuv420p" or video.get("sample_aspect_ratio") not in (None, "1:1", "0:1")
            or video.get("color_transfer") in ("smpte2084", "arib-std-b67", "reserved")
            or video.get("color_space") in ("reserved", "bt2020nc", "bt2020c")
            or video.get("color_primaries") == "bt2020"
            or video.get("field_order") not in (None, "unknown", "progressive")
            or any(side.get("rotation", 0) or "rotation" not in side for side in video.get("side_data_list", []))):
        return None
    gain = min(2, 1080 / min(width, height), 2160 / max(width, height))
    if gain < 1.08:  # Avoid a new encode for barely larger output.
        return None
    return (2 * round(width * gain / 2), 2 * round(height * gain / 2))


def _run(args):
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0) | getattr(subprocess, "BELOW_NORMAL_PRIORITY_CLASS", 0)
    call = subprocess.run(args, capture_output=True, encoding="utf-8", errors="replace", timeout=600, creationflags=flags)
    if call.returncode:
        raise ValueError("FFmpeg could not read or enhance this archived clip")
    return call


def _probe(path, ffprobe):
    value = json.loads(_run([ffprobe, "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)]).stdout)
    video = next((s for s in value["streams"] if s["codec_type"] == "video" and not s.get("disposition", {}).get("attached_pic")), None)
    audio = next((s for s in value["streams"] if s["codec_type"] == "audio"), None)
    duration = float(value["format"]["duration"])
    if not video or not math.isfinite(duration) or duration <= 0:
        raise ValueError("Archived clip is missing a playable picture or duration")
    return video, audio, duration


def _measure(path, ffmpeg, filters):
    run = _run([ffmpeg, "-hide_banner", "-nostdin", "-nostats", "-threads", "2", "-filter_threads", "1", "-i", str(path),
                "-map", "0:a:0", "-vn", "-af", filters + TARGET + ":print_format=json", "-f", "null", "-"])
    report, _ = json.JSONDecoder().raw_decode(run.stderr[run.stderr.rfind("{"):])
    fields = ("input_i", "input_tp", "input_lra", "input_thresh", "target_offset")
    result = [float(report[field]) for field in fields]
    return result if all(math.isfinite(n) for n in result) and result[0] > -60 else None


def _verify_audio(path, ffmpeg):
    run = _run([ffmpeg, "-hide_banner", "-nostdin", "-nostats", "-threads", "2", "-filter_threads", "1", "-i", str(path),
                "-map", "0:a:0", "-vn", "-af", "ebur128=peak=true:framelog=verbose", "-f", "null", "-"])
    summary = run.stderr.rsplit("Summary:", 1)[-1]
    integrated = re.search(r"\bI:\s+([\d.-]+) LUFS", summary)
    peak = re.search(r"\bPeak:\s+([\d.-]+) dBFS", summary)
    return (float(integrated[1]), float(peak[1])) if integrated and peak else None


def _audio_filter(stats, correction=0):
    integrated, peak, lra, threshold, offset = stats
    if integrated < -2 and peak + (-11 - integrated) <= -2:
        # A fixed gain preserves dynamics and does not ramp in at the start.
        normalize = f"volume={-11 - integrated + correction:+.4f}dB"
    else:
        measured_lra = max(0, min(99, lra))
        normalize = (f"{TARGET}:linear=true:measured_I={integrated}:measured_TP={peak}:measured_LRA={measured_lra}"
                     f":measured_thresh={threshold}:offset={max(-10, min(10, offset))}")
        if correction:
            normalize += f",volume={correction:+.4f}dB"
    return EQ + "," + normalize


def _encode(src, dst, video, audio, dimensions, stats, ffmpeg, correction=0):
    args = [ffmpeg, "-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-threads", "2", "-filter_threads", "2",
            "-copyts", "-start_at_zero", "-i", str(src), "-map", f"0:{video['index']}"]
    if audio:
        args += ["-map", f"0:{audio['index']}"]
    if dimensions:
        width, height = dimensions
        # Preserve phone hardware decode, source cadence and the source DAR.
        bitrate = min(3500, max(650, int(video.get("bit_rate") or 0) * 3 // 1000))
        args += ["-vf", f"scale={width}:{height}:flags=lanczos,unsharp=3:3:0.28:3:3:0",
                 "-fps_mode", "passthrough", "-c:v", "libx264", "-preset", "veryfast", "-crf", "17",
                 "-maxrate", f"{bitrate}k", "-bufsize", f"{bitrate * 2}k", "-threads:v", "2", "-pix_fmt", "yuv420p"]
    else:
        args += ["-c:v", "copy"]
        if video.get("codec_name") == "hevc":
            args += ["-tag:v", "hvc1"]
    if stats:
        # Keep the source sample rate/channels. AAC-LC at a high bitrate keeps
        # the extra audio traffic small even for a very low original bitrate.
        channels = audio["channels"]
        rate = int(audio["sample_rate"])
        filters = _audio_filter(stats, correction) + f",aresample={rate}"
        # Dynamic loudnorm can emit a padded terminal analysis block. Keep the
        # original audio length (within a sample), rather than adding a loop gap.
        if (audio_duration := _time(audio, "duration")) is not None and audio_duration > 0:
            filters += f",atrim=end_sample={round(audio_duration * rate)}"
        filters += ",asetpts=N/SR/TB+STARTPTS"
        args += ["-af", filters, "-ar", str(rate), "-c:a", "aac",
                 "-b:a", f"{min(384, 112 * channels)}k"]
    else:
        args += ["-c:a", "copy"]
    _run(args + ["-movflags", "+faststart", str(dst)])


def _time(track, key):
    try:
        return float(track[key])
    except (ValueError, KeyError, TypeError):
        return None


def _relative_rate(source, result):
    try:
        return abs(float(Fraction(source) / Fraction(result)) - 1)
    except (ValueError, ZeroDivisionError, TypeError):
        return 0  # Some source files do not report a rate.


def _validate(source, processed, dimensions):
    video, audio, duration = source
    picture, sound, length = processed
    if abs(duration - length) > 0.065 or bool(sound) != bool(audio):
        raise ValueError("Enhancement changed the track set or media duration")
    expected = dimensions or (video["width"], video["height"])
    if (picture["width"], picture["height"]) != expected or (dimensions and picture.get("codec_name") != "h264"):
        raise ValueError("Enhancement did not produce the expected picture")
    if video.get("nb_frames") and picture.get("nb_frames") and video["nb_frames"] != picture["nb_frames"]:
        raise ValueError("Enhancement changed the number of video frames")
    if _relative_rate(video.get("avg_frame_rate"), picture.get("avg_frame_rate")) > 0.005:
        raise ValueError("Enhancement changed the video cadence")
    if sound:
        if (audio["channels"], audio["sample_rate"]) != (sound["channels"], sound["sample_rate"]):
            raise ValueError("Enhancement changed the audio channel count or sample rate")
        trim = max(0.026, 1024 / int(audio["sample_rate"]) + 0.002)
        for key in ("start_time", "duration"):
            a, b = _time(audio, key), _time(sound, key)
            if a is not None and b is not None and abs(a - b) > trim:
                raise ValueError("Enhancement shifted or truncated the audio")


def enhance(source, output, *, ffmpeg="ffmpeg", ffprobe="ffprobe", allow_upscale=True):
    source, output = Path(source), Path(output)
    if source.resolve() == output.resolve():
        raise ValueError("Never write enhanced playback over the archive")
    original = _probe(source, ffprobe)
    video, audio, _ = original
    dimensions = picture_dimensions(video) if allow_upscale else None
    stats = _measure(source, ffmpeg, EQ + ",") if audio else None
    if not dimensions and not stats:
        return Enhancement(None, False, False, None, None, None)
    output.parent.mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory(dir=output.parent, prefix="stream-quality-") as tmp:
        temp = Path(tmp) / "enhanced.mp4"
        _encode(source, temp, video, audio, dimensions, stats, ffmpeg)
        _validate(original, _probe(temp, ffprobe), dimensions)
        measured = _verify_audio(temp, ffmpeg) if stats else None
        if measured and measured[1] > -1:
            _encode(source, temp, video, audio, dimensions, stats, ffmpeg, correction=-1.8 - measured[1])
            _validate(original, _probe(temp, ffprobe), dimensions)
            measured = _verify_audio(temp, ffmpeg)
        if measured and measured[1] > -1:
            # AAC can overshoot by different amounts after an input level
            # change. A conservative last pass is better than a clipped copy.
            _encode(source, temp, video, audio, dimensions, stats, ffmpeg, correction=-3)
            _validate(original, _probe(temp, ffprobe), dimensions)
            measured = _verify_audio(temp, ffmpeg)
        if stats and (not measured or measured[1] > -1 or (stats[0] < -14 and measured[0] < stats[0] + 1)):
            raise ValueError("Enhanced audio failed the loudness or peak check")
        temp.replace(output)
    return Enhancement(output, bool(stats), bool(dimensions), stats[0] if stats else None,
                       measured[0] if measured else None, measured[1] if measured else None)
