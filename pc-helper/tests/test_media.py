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


@pytest.mark.parametrize("sound_length,expected_length", [(2, 6.6), (9, 9)])
def test_photo_carousel_timing_and_forward_wrap_are_independent_of_music(tmp_path, sound_length, expected_length):
    from PIL import Image
    images = []
    for index, color in enumerate(("red", "blue")):
        image = tmp_path / f"{index}.png"
        Image.new("RGB", (160, 240), color).save(image)
        images.append(image)
    audio = tmp_path / "song.m4a"
    run_ffmpeg("-f", "lavfi", "-i", f"sine=frequency=440:duration={sound_length}", "-c:a", "aac", audio)
    output = MediaTools().slideshow(images, audio, tmp_path / "slideshow.mp4")
    details = MediaTools().probe(output)
    assert details["video_codec"] == "h264"
    assert details["audio_codec"] in ("aac", "alac")
    assert abs(details["duration"] - expected_length) < .09
    frames = subprocess.run(["ffmpeg", "-v", "error", "-i", str(output), "-vf", "scale=8:2",
                             "-pix_fmt", "rgb24", "-f", "rawvideo", "-"], check=True, capture_output=True).stdout
    def colors(seconds):
        start = round(seconds * 30) * 48
        row = frames[start:start + 24]
        return tuple("R" if row[i] > row[i + 2] else "B" for i in (0, 21))
    assert colors(2.4) == ("R", "R")
    assert colors(2.8) == ("R", "B")
    assert colors(3.4) == ("B", "B")
    assert colors(5.7) == ("B", "B")
    assert colors(6.1) == ("B", "R")
    if sound_length == 9:
        assert colors(7.8) == ("R", "R")
    # A short soundtrack continues through the last photo's hold.
    samples = subprocess.run(["ffmpeg", "-v", "error", "-ss", "5.4", "-i", str(output), "-t", "0.2",
                              "-map", "0:a", "-ac", "1", "-ar", "8000", "-f", "s16le", "-"],
                             capture_output=True, check=True).stdout
    assert len(samples) >= 3000 and any(samples)


def test_silent_photo_post_has_a_bounded_playable_duration(tmp_path):
    from PIL import Image
    image = tmp_path / "image.png"
    Image.new("RGB", (160, 240), "red").save(image)
    output = MediaTools().slideshow([image], None, tmp_path / "silent.mp4")
    assert abs(MediaTools().probe(output)["duration"] - 5) < 0.15


def test_native_photo_rendition_keeps_authored_video_packets_and_its_separate_soundtrack(tmp_path):
    from PIL import Image
    import zipfile
    from offline_tiktok.photo import render_archive
    native = tmp_path / "native.mp4"
    audio = tmp_path / "audio.m4a"
    run_ffmpeg("-f", "lavfi", "-i", "testsrc2=s=96x96:r=12:d=1.5", "-c:v", "libx264", native)
    run_ffmpeg("-f", "lavfi", "-i", "sine=frequency=440:duration=0.6", "-c:a", "aac", audio)
    image = tmp_path / "frame.png"
    Image.new("RGB", (32, 32), "red").save(image)
    original = tmp_path / "photo.zip"
    with zipfile.ZipFile(original, "w") as archive:
        archive.write(image, "image-000000.png")
        archive.write(image, "image-000001.png")
        archive.write(native, "native-video.mp4")
        archive.write(audio, "audio.m4a")
    source_digest = hashlib.sha256(original.read_bytes()).hexdigest()
    result = render_archive(MediaTools(), original, tmp_path / "play.mp4")
    info = MediaTools().probe(result)
    assert info["audio_codec"] and abs(info["duration"] - 1.5) < .08
    def video_packets(path):
        return subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_packets",
                               "-show_data_hash", "sha256", "-show_entries", "packet=pts_time,duration_time,data_hash",
                               "-of", "csv", str(path)], capture_output=True, check=True).stdout
    assert video_packets(native) == video_packets(result)
    assert hashlib.sha256(original.read_bytes()).hexdigest() == source_digest


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
