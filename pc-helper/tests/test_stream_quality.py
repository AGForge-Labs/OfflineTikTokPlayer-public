import json
from pathlib import Path
import shutil
import subprocess

import pytest

from offline_tiktok.stream_quality import enhance, picture_dimensions


pytestmark = pytest.mark.skipif(not shutil.which("ffmpeg") or not shutil.which("ffprobe"),
                               reason="Needs FFmpeg and FFprobe")


def cli(*args):
    return subprocess.run(args, capture_output=True, text=True, check=True).stdout


def tracks(path):
    return json.loads(cli("ffprobe", "-v", "error", "-show_streams", "-of", "json", str(path)))["streams"]


def make_clip(path, *, size="270x480", sound="0.007*sin(2*PI*180*t)|0.010*sin(2*PI*330*t)", rate="30000/1001"):
    cli("ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
        f"testsrc2=size={size}:rate={rate}", "-f", "lavfi", "-i", f"aevalsrc={sound}:s=44100",
        "-t", "3.5", "-c:v", "libx264", "-preset", "ultrafast", "-threads", "2",
        "-c:a", "aac", "-movflags", "+faststart", str(path))


def test_quiet_video_is_upscaled_and_mastered_without_displacing_first_audio(tmp_path):
    source, output = tmp_path / "source.mp4", tmp_path / "enhanced.mp4"
    make_clip(source)
    original = source.read_bytes()
    result = enhance(source, output)
    assert result.audio_mastered and result.picture_upscaled
    assert result.original_lufs < -35
    assert -13 <= result.output_lufs <= -9.5
    assert result.output_peak <= -1
    v0, a0 = tracks(source)
    v1, a1 = tracks(output)
    assert (v1["width"], v1["height"], v1["display_aspect_ratio"]) == (540, 960, "9:16")
    assert v1["avg_frame_rate"] == v0["avg_frame_rate"] == "30000/1001"
    assert v1["nb_frames"] == v0["nb_frames"]
    assert (a1["channels"], a1["sample_rate"]) == (a0["channels"], a0["sample_rate"])
    assert abs(float(a1["start_time"]) - float(a0["start_time"])) < 0.024
    assert abs(float(a1["duration"]) - float(a0["duration"])) < 0.024
    assert source.read_bytes() == original
    assert output.read_bytes().find(b"moov") < output.read_bytes().find(b"mdat")


def test_clear_high_resolution_picture_is_stream_copied_and_loud_peaks_are_safe(tmp_path):
    source, output = tmp_path / "source.mp4", tmp_path / "enhanced.mp4"
    make_clip(source, size="1080x1080", sound="0.91*sin(2*PI*180*t)|0.92*sin(2*PI*330*t)", rate="10")
    result = enhance(source, output)
    assert not result.picture_upscaled and result.audio_mastered and result.output_peak <= -1
    def picture_hash(path: Path):
        return cli("ffmpeg", "-v", "error", "-i", str(path), "-map", "0:v:0", "-c", "copy", "-f", "hash", "-")
    assert picture_hash(output) == picture_hash(source)


def test_silence_does_not_turn_into_amplified_noise(tmp_path):
    source, output = tmp_path / "source.mp4", tmp_path / "enhanced.mp4"
    make_clip(source, sound="0|0")
    result = enhance(source, output)
    assert not result.audio_mastered and result.output_lufs is None
    assert result.picture_upscaled
    assert cli("ffmpeg", "-v", "error", "-i", str(source), "-map", "0:a:0", "-c", "copy", "-f", "hash", "-") == cli(
        "ffmpeg", "-v", "error", "-i", str(output), "-map", "0:a:0", "-c", "copy", "-f", "hash", "-")


def test_video_profile_bounds_upscaling_and_preserves_hdr_or_rotation():
    standard = dict(width=720, height=1280, pix_fmt="yuv420p")
    assert picture_dimensions(standard) == (1080, 1920)
    assert picture_dimensions(dict(standard, width=1800, height=900)) == (2160, 1080)
    assert picture_dimensions(dict(standard, pix_fmt="yuv420p10le", color_transfer="smpte2084")) is None
    assert picture_dimensions(dict(standard, side_data_list=[{"rotation": 90}])) is None
