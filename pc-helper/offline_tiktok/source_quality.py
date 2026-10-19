"""Choose actual post renditions and preserve their encoded tracks."""
from array import array
from dataclasses import dataclass
import math
from pathlib import Path
import subprocess


QUALITY_VERSION = 1


@dataclass
class Rendition:
    format: dict
    details: dict

    @property
    def has_picture(self):
        return self.format.get("vcodec") != "none" and bool(self.details.get("video_codec"))


def video_score(details):
    width, height = details.get("width", 0), details.get("height", 0)
    fps = details.get("fps", 0)
    # Treat fractional NTSC rates and their rounded labels as the same tier.
    fps = next((rate for rate in (24, 25, 30, 48, 50, 60, 90, 120) if abs(fps-rate) < .07), fps)
    return (min(width, height), width * height, fps, details.get("video_bitrate", 0))


def choose_video(renditions):
    candidates = [r for r in renditions if r.has_picture and r.details.get("width", 0) > 0
        and r.details.get("height", 0) > 0
        and "watermarked" not in (r.format.get("format_note") or "").lower()
        and ((r.details["video_codec"] == "h264" and r.details.get("pixel_format") == "yuv420p")
             or (r.details["video_codec"] == "hevc" and r.details.get("pixel_format") in ("yuv420p", "yuv420p10le")))]
    if not candidates:
        raise ValueError("TikTok supplied no verifiable clean picture stream")
    return max(candidates, key=lambda r: video_score(r.details))


def audio_candidates(renditions, picture):
    candidates = [r for r in renditions if r.has_picture and r.details.get("audio_codec")
        and r.details.get("duration", 0) >= picture.details["duration"] - 0.05
        and abs(r.details.get("audio_start", 0) - picture.details.get("audio_start", 0)) < 0.05]
    return sorted(candidates, key=lambda r: (
        r.details.get("audio_channels", 0),
        r.details["audio_codec"] in ("alac", "flac", "pcm_s16le", "pcm_s24le"),
        r.details.get("audio_bitrate", 0), r is picture), reverse=True)


def _run(command):
    result = subprocess.run(command, capture_output=True, timeout=120,
                            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    if result.returncode:
        raise ValueError("Source track verification failed")
    return result.stdout


def stream_digest(path, kind, *, ffmpeg="ffmpeg", duration=None):
    args = [ffmpeg, "-v", "error", "-i", str(path), "-map", "0:v:0" if kind == "video" else "0:a:0", "-c", "copy"]
    if duration is not None:
        args += ["-t", f"{duration:.9f}"]
    return _run(args + ["-f", "hash", "-"]).decode().strip()


def _samples(path, start, ffmpeg):
    data = _run([ffmpeg, "-v", "error", "-ss", f"{start:.6f}", "-i", str(path),
        "-map", "0:a:0", "-t", "0.75", "-ac", "1", "-ar", "8000", "-f", "f32le", "-"])
    values = array("f")
    values.frombytes(data)
    return values


def matching_audio(reference, donor, duration, *, ffmpeg="ffmpeg"):
    """Check three decoded windows; analysis resampling never touches output."""
    positions = sorted(set((min(0.2, max(0, duration - 0.8)), max(0, duration / 2 - 0.375), max(0, duration - 1))))
    correlations = []
    for position in positions:
        left, right = _samples(reference, position, ffmpeg), _samples(donor, position, ffmpeg)
        count = min(len(left), len(right))
        if count < 100:
            raise ValueError("Audio source is too short to verify alignment")
        left, right = left[:count], right[:count]
        lmean, rmean = math.fsum(left) / count, math.fsum(right) / count
        lenergy = math.fsum((v - lmean) ** 2 for v in left)
        renergy = math.fsum((v - rmean) ** 2 for v in right)
        if min(lenergy, renergy) < 1e-7:
            continue
        correlation = math.fsum((a - lmean) * (b - rmean) for a, b in zip(left, right)) / math.sqrt(lenergy * renergy)
        correlations.append(correlation)
    # Low-bitrate AAC can differ substantially even at the same sample timing.
    # All candidates are embedded tracks from this exact post, never music URLs.
    if not correlations or min(correlations) < 0.90:
        raise ValueError("The higher-bitrate post audio does not match or align with this video")
    return min(correlations)


def combine_tracks(picture, audio, output, tools, *, check=lambda: None):
    check()
    picture, output = Path(picture), Path(output)
    audio = Path(audio) if audio else None
    if output.resolve() in {picture.resolve(), audio.resolve() if audio else None}:
        raise ValueError("A replacement must not overwrite either source")
    details = tools.probe(picture)
    duration = details["duration"]
    correlation = None
    if audio and audio.resolve() != picture.resolve():
        sound = tools.probe(audio)
        if sound["duration"] < duration - 0.05:
            raise ValueError("Audio source duration is shorter than the picture")
        if details.get("audio_codec"):
            correlation = matching_audio(picture, audio, duration, ffmpeg=tools.ffmpeg)
    check()
    output.parent.mkdir(parents=True, exist_ok=True)
    partial = output.with_name(output.stem + ".part" + output.suffix)
    args = [tools.ffmpeg, "-v", "error", "-y", "-i", str(picture)]
    if audio:
        args += ["-i", str(audio), "-map", "0:v:0", "-map", "1:a:0"]
    else:
        args += ["-map", "0:v:0", "-map", "0:a:0?"]
    args += ["-c", "copy", "-t", f"{duration:.9f}"]
    if details["video_codec"] == "hevc":
        args += ["-tag:v", "hvc1"]
    tools._run(args + ["-movflags", "+faststart", str(partial)])
    check()
    fixed = tools.probe(partial)
    if (abs(fixed["duration"] - duration) > 0.12
            or (fixed["width"], fixed["height"]) != (details["width"], details["height"])
            or stream_digest(partial, "video", ffmpeg=tools.ffmpeg) != stream_digest(picture, "video", ffmpeg=tools.ffmpeg)):
        raise ValueError("Picture packets or duration changed during source assembly")
    if audio:
        expected = stream_digest(audio, "audio", ffmpeg=tools.ffmpeg, duration=duration)
        if stream_digest(partial, "audio", ffmpeg=tools.ffmpeg) != expected:
            raise ValueError("Audio packets changed during source assembly")
    check()
    partial.replace(output)
    return dict(audioCorrelation=correlation, videoPacketsUnchanged=True, audioPacketsUnchanged=True)
