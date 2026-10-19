import hashlib
import shutil
import subprocess
import pytest
from offline_tiktok.media import MediaTools


pytestmark = pytest.mark.skipif(not shutil.which("ffmpeg") or not shutil.which("ffprobe"), reason="FFmpeg is required")


def run_ffmpeg(*args):
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *map(str, args)], check=True, capture_output=True)


def test_native_mp4_is_not_reencoded_and_original_bytes_survive(tmp_path):
    source = tmp_path / "source.mp4"
    run_ffmpeg("-f", "lavfi", "-i", "color=c=red:s=160x240:r=12:d=1", "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
               "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", source)
    before = hashlib.sha256(source.read_bytes()).hexdigest()
    assert MediaTools().compatible(source) == source
    assert hashlib.sha256(source.read_bytes()).hexdigest() == before


def test_mp3_in_mp4_gets_lossless_iphone_audio_without_reencoding_video(tmp_path):
    source = tmp_path / "mp3.mp4"
    run_ffmpeg("-f", "lavfi", "-i", "color=c=blue:s=160x240:r=12:d=1", "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
               "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "libmp3lame", "-shortest", source)
    before = source.read_bytes()
    copy = MediaTools().compatible(source)
    assert copy != source
    assert MediaTools().probe(copy)["audio_codec"] == "alac"
    def video_digest(path):
        return subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-map", "0:v:0", "-c", "copy", "-f", "hash", "-"],
                              check=True, capture_output=True).stdout
    assert video_digest(source) == video_digest(copy)
    assert source.read_bytes() == before


def test_mp3_photo_soundtrack_is_rendered_with_iphone_compatible_audio(tmp_path):
    from PIL import Image
    image = tmp_path / "image.png"
    Image.new("RGB", (160, 240), "green").save(image)
    audio = tmp_path / "song.mp3"
    run_ffmpeg("-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-c:a", "libmp3lame", audio)
    before = audio.read_bytes()
    output = MediaTools().slideshow([image], audio, tmp_path / "slideshow.mp4")
    assert MediaTools().probe(output)["audio_codec"] == "alac"
    assert abs(MediaTools().probe(output)["duration"] - 1) < 0.15
    assert audio.read_bytes() == before


def test_unsupported_video_gets_a_compatible_copy_without_destroying_original(tmp_path):
    source = tmp_path / "source.mkv"
    run_ffmpeg("-f", "lavfi", "-i", "color=c=blue:s=160x240:r=12:d=1", "-c:v", "ffv1", source)
    before = source.read_bytes()
    copy = MediaTools().compatible(source)
    assert copy != source
    assert MediaTools().probe(copy)["video_codec"] == "h264"
    assert MediaTools().probe(copy)["width"] == 160
    assert source.read_bytes() == before


def test_slideshow_contains_all_images_and_entire_soundtrack(tmp_path):
    from PIL import Image
    images = []
    for index, color in enumerate(("red", "blue")):
        image = tmp_path / f"{index}.png"
        Image.new("RGB", (160, 240), color).save(image)
        images.append(image)
    audio = tmp_path / "song.m4a"
    run_ffmpeg("-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-c:a", "aac", audio)
    output = MediaTools().slideshow(images, audio, tmp_path / "slideshow.mp4")
    details = MediaTools().probe(output)
    assert details["video_codec"] == "h264"
    assert details["audio_codec"] == "aac"
    assert abs(details["duration"] - 2) < 0.15
    for position, dominant in ((0.3, 0), (1.5, 2)):
        pixel = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-ss", str(position), "-i", str(output),
                                "-frames:v", "1", "-vf", "scale=1:1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                               check=True, capture_output=True).stdout
        assert pixel[dominant] > pixel[2 if dominant == 0 else 0] + 100


def test_silent_photo_post_has_a_bounded_playable_duration(tmp_path):
    from PIL import Image
    image = tmp_path / "image.png"
    Image.new("RGB", (160, 240), "red").save(image)
    output = MediaTools().slideshow([image], None, tmp_path / "silent.mp4")
    assert abs(MediaTools().probe(output)["duration"] - 5) < 0.15


def test_reserved_color_metadata_still_produces_artwork_without_changing_video(tmp_path):
    from PIL import Image
    source = tmp_path / "reserved.mp4"
    normal = tmp_path / "normal.mp4"
    run_ffmpeg("-f", "lavfi", "-i", "color=c=red:s=160x240:r=12:d=1", "-c:v", "libx264", normal)
    run_ffmpeg("-i", normal, "-c", "copy", "-bsf:v",
               "h264_metadata=matrix_coefficients=3:colour_primaries=3:transfer_characteristics=3", source)
    before = source.read_bytes()
    artwork = MediaTools().thumbnail(source, tmp_path / "artwork.jpg")
    with Image.open(artwork) as image:
        assert image.width == 320
        red, green, blue = image.convert("RGB").getpixel((100, 100))
        assert red > green + 100 and red > blue + 100
    assert source.read_bytes() == before
