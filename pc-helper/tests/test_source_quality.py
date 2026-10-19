import hashlib
from pathlib import Path
import shutil
import subprocess
import pytest
from offline_tiktok.media import MediaTools


def rendition(name, width=960, height=720, video_rate=500000, audio_rate=128000, *, watermark=False, duration=4):
    from offline_tiktok.source_quality import Rendition
    return Rendition(dict(format_id=name, url="https://media.example/" + name,
        vcodec="h264" if width else "none", format_note="watermarked" if watermark else None),
        dict(width=width, height=height, video_codec="h264" if width else None,
             video_bitrate=video_rate, audio_codec="aac", audio_bitrate=audio_rate,
             audio_channels=2, audio_sample_rate=44100, pixel_format="yuv420p", fps=30, duration=duration, audio_start=0))


def test_picture_selection_uses_resolution_and_bitrate_before_codec_preference():
    from offline_tiktok.source_quality import choose_video
    compressed = rendition("hevc", video_rate=208800, audio_rate=32183)
    compressed.details["video_codec"] = "hevc"
    fuller = rendition("h264", video_rate=596314)
    assert choose_video([compressed, fuller]) is fuller
    higher = rendition("higher", width=1920, height=1080, video_rate=450000)
    assert choose_video([compressed, fuller, higher]) is higher


def test_audio_selection_uses_the_post_mix_and_keeps_clean_picture_separate():
    from offline_tiktok.source_quality import choose_video, audio_candidates
    picture = rendition("clean-hd", audio_rate=57099)
    downloadable = rendition("watermarked-post", width=768, height=576, audio_rate=128088, watermark=True)
    soundtrack = rendition("music", width=0, height=0, audio_rate=320000)
    truncated = rendition("short-post", audio_rate=256000, duration=1)
    assert choose_video([picture, downloadable, soundtrack]) is picture
    assert audio_candidates([picture, downloadable, soundtrack, truncated], picture) == [downloadable, picture]


def test_no_resolution_cap_and_silent_post_never_gets_a_standalone_song():
    from offline_tiktok.source_quality import choose_video, audio_candidates
    picture = rendition("4k", width=2160, height=3840, audio_rate=0)
    picture.details["audio_codec"] = None
    music = rendition("song", width=0, height=0)
    assert choose_video([picture, music]) is picture
    assert audio_candidates([picture, music], picture) == []


def test_more_bitrate_cannot_discard_the_posts_stereo_channels():
    from offline_tiktok.source_quality import audio_candidates
    from offline_tiktok.quality_repair import _audio_score
    stereo = rendition("stereo", audio_rate=64000)
    mono = rendition("mono", audio_rate=128000)
    mono.details["audio_channels"] = 1
    assert audio_candidates([stereo, mono], stereo)[0] is stereo
    assert _audio_score(stereo.details) > _audio_score(mono.details)


def make_video(path, *, audio_rate="128k", sound="313", size="160x240", duration=4):
    command = ["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", f"testsrc2=s={size}:r=12:d={duration}",
        "-f", "lavfi", "-i", f"aevalsrc=0.12*sin(2*PI*{sound}*t)+0.08*sin(2*PI*727*t)+0.05*sin(2*PI*1103*t):s=44100:d={duration}",
        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", audio_rate, "-shortest", str(path)]
    subprocess.run(command, check=True, capture_output=True)


@pytest.mark.skipif(not shutil.which("ffmpeg"), reason="FFmpeg is required")
def test_copy_combines_matching_post_tracks_without_reencoding_either_or_changing_originals(tmp_path):
    from offline_tiktok.source_quality import combine_tracks, stream_digest
    picture, audio, output = [tmp_path / name for name in ("picture.mp4", "audio.mp4", "best.mp4")]
    make_video(picture, audio_rate="32k")
    make_video(audio, audio_rate="128k", size="120x160")
    original_hashes = [hashlib.sha256(p.read_bytes()).hexdigest() for p in (picture, audio)]
    combine_tracks(picture, audio, output, MediaTools())
    assert stream_digest(output, "video") == stream_digest(picture, "video")
    assert stream_digest(output, "audio") == stream_digest(audio, "audio")
    assert [hashlib.sha256(p.read_bytes()).hexdigest() for p in (picture, audio)] == original_hashes
    assert abs(MediaTools().probe(output)["duration"] - 4) < 0.1


@pytest.mark.skipif(not shutil.which("ffmpeg"), reason="FFmpeg is required")
def test_different_music_with_identical_duration_is_rejected_before_replacement(tmp_path):
    from offline_tiktok.source_quality import combine_tracks
    picture, wrong, output = [tmp_path / name for name in ("picture.mp4", "wrong.mp4", "best.mp4")]
    make_video(picture, sound="313")
    make_video(wrong, sound="661")
    with pytest.raises(ValueError, match="match|align"):
        combine_tracks(picture, wrong, output, MediaTools())
    assert not output.exists()


@pytest.mark.skipif(not shutil.which("ffmpeg"), reason="FFmpeg is required")
def test_shorter_audio_cannot_silently_truncate_the_post(tmp_path):
    from offline_tiktok.source_quality import combine_tracks
    picture, short, output = [tmp_path / name for name in ("picture.mp4", "short.mp4", "best.mp4")]
    make_video(picture)
    make_video(short, duration=1)
    with pytest.raises(ValueError, match="duration|short"):
        combine_tracks(picture, short, output, MediaTools())
    assert not output.exists()


@pytest.mark.skipif(not shutil.which("ffmpeg"), reason="FFmpeg is required")
def test_downloader_uses_verified_post_components_and_resumes_without_exporting_urls(tmp_path):
    import json
    from offline_tiktok.quality_download import QualityDownloader
    from offline_tiktok.catalog import MediaItem
    picture, audio = tmp_path / "hd.mp4", tmp_path / "sd.mp4"
    make_video(picture, audio_rate="32k")
    make_video(audio, audio_rate="128k", size="120x160")
    calls = []
    class Provider:
        def __init__(self, *args, **kwargs): calls.append("provider")
        def __enter__(self):
            self.info = dict(id="123", formats=[
                dict(format_id="hd-0", vcodec="h264", url="https://media.example/hd?token=PRIVATE"),
                dict(format_id="sd-0", vcodec="h264", format_note="watermarked", url="https://media.example/sd?token=PRIVATE"),
                dict(format_id="audio", vcodec="none", url="https://media.example/song?token=PRIVATE")])
            return self
        def __exit__(self, *args): pass
        def probe(self, fmt): return MediaTools().probe(picture if fmt["format_id"].startswith("hd") else audio)
        def fetch(self, fmt, target):
            calls.append(fmt["format_id"])
            shutil.copyfile(picture if fmt["format_id"].startswith("hd") else audio, target)
            return target
    downloader = QualityDownloader(MediaTools(), provider=Provider)
    item = MediaItem("123", "Post", source_url="https://www.tiktok.com/@fixture_creator_4/video/123")
    output = downloader.acquire(item, tmp_path / "download", [])
    assert calls == ["provider", "hd-0", "sd-0"]
    before = list(calls)
    assert downloader.acquire(item, tmp_path / "download", []) == output
    assert calls == before
    proof = json.loads(output.with_name("quality.json").read_text())
    assert proof["video"]["formatID"] == "hd-0" and proof["audio"]["formatID"] == "sd-0"
    assert proof["sha256"] == hashlib.sha256(output.read_bytes()).hexdigest()
    assert "PRIVATE" not in output.with_name("quality.json").read_text()
    output.write_bytes(b"changed")
    with pytest.raises(ValueError, match="changed|verification"):
        downloader.acquire(item, tmp_path / "download", [])


def test_future_video_import_uses_the_verified_quality_path_instead_of_legacy_format_defaults(tmp_path, monkeypatch):
    from types import SimpleNamespace
    from offline_tiktok.catalog import MediaItem
    from offline_tiktok.media import MediaDownloader
    import offline_tiktok.quality_download
    import yt_dlp
    calls = []
    selected = tmp_path / "quality.mp4"
    def acquire(item, directory, cookies):
        calls.append((item.id, Path(directory), cookies))
        return selected
    monkeypatch.setattr(offline_tiktok.quality_download, "QualityDownloader", lambda *args, **kwargs: SimpleNamespace(acquire=acquire))
    monkeypatch.setattr(yt_dlp, "YoutubeDL", lambda *args, **kwargs: pytest.fail("Legacy codec-first download must not run"))
    item = MediaItem("123", "Post", source_url="https://www.tiktok.com/@fixture_creator_4/video/123")
    downloader = MediaDownloader(tmp_path)
    assert downloader._video(item, tmp_path, []) == selected
    assert calls == [("123", tmp_path / "source-quality-v1", [])]


def test_a_measured_legacy_file_cannot_bypass_the_quality_upgrade(tmp_path):
    from types import SimpleNamespace
    from offline_tiktok.archive import CachedDownloader
    from offline_tiktok.catalog import MediaItem
    original = tmp_path / "123" / "original.mp4"
    original.parent.mkdir()
    original.write_bytes(b"complete but low-bitrate original")
    original.with_name("artwork.jpg").write_bytes(b"art")
    details = dict(status="measured", originalBytes=original.stat().st_size, playbackBytes=original.stat().st_size)
    tools = SimpleNamespace(probe=lambda path: dict(video_codec="h264", duration=4), compatible=lambda path: path)
    fallback = SimpleNamespace(acquire=lambda *args: "verified quality download")
    assert CachedDownloader(fallback, tmp_path, {"media":{"123":details}}, tools=tools).acquire(MediaItem("123","Post"), []) == "verified quality download"


def test_an_unsupported_picture_must_not_win_then_be_lossily_transcoded_for_iphone():
    from offline_tiktok.source_quality import choose_video
    native = rendition("native")
    unsupported = rendition("unsupported", width=3840, height=2160)
    unsupported.details["video_codec"] = "vp9"
    assert choose_video([native, unsupported]) is native
    unsupported.details.update(video_codec="h264", pixel_format="yuv444p")
    assert choose_video([native, unsupported]) is native


@pytest.mark.skipif(not shutil.which("ffmpeg"), reason="FFmpeg is required")
def test_rejected_donor_does_not_poison_the_next_candidates_download_target(tmp_path):
    import json
    from offline_tiktok.quality_download import QualityDownloader
    from offline_tiktok.catalog import MediaItem
    paths = {name:tmp_path/(name+".mp4") for name in ("picture","wrong","right")}
    make_video(paths["picture"], audio_rate="32k")
    make_video(paths["wrong"], audio_rate="128k", sound="661", size="120x160")
    make_video(paths["right"], audio_rate="96k", size="120x160")
    class Provider:
        def __init__(self, *args, **kwargs): pass
        def __enter__(self):
            self.info = dict(id="123", formats=[dict(format_id=name, vcodec="h264", format_note=None if name == "picture" else "watermarked") for name in paths])
            return self
        def __exit__(self, *args): pass
        def probe(self, fmt): return MediaTools().probe(paths[fmt["format_id"]])
        def fetch(self, fmt, target):
            # Match yt-dlp's completed-file behavior: an existing path is reused.
            if not target.exists(): shutil.copyfile(paths[fmt["format_id"]], target)
            return target
    output=QualityDownloader(MediaTools(),provider=Provider).acquire(MediaItem("123","Post"),tmp_path/"result")
    proof=json.loads(output.with_name("quality.json").read_text())
    assert proof["audio"]["formatID"] == "right"


@pytest.mark.skipif(not shutil.which("ffmpeg"), reason="FFmpeg is required")
def test_pause_at_end_of_fetch_does_not_promote_a_quality_copy(tmp_path):
    from offline_tiktok.quality_download import QualityDownloader
    from offline_tiktok.catalog import MediaItem
    source, donor=tmp_path/"source.mp4",tmp_path/"donor.mp4"
    make_video(source,audio_rate="32k")
    make_video(donor,audio_rate="128k",size="120x160")
    cancelled=[False]
    class Provider:
        def __init__(self, *args, **kwargs): pass
        def __enter__(self):
            self.info=dict(id="123",formats=[dict(format_id="post",vcodec="h264"),dict(format_id="donor",vcodec="h264",format_note="watermarked")])
            return self
        def __exit__(self,*args): pass
        def probe(self,fmt): return MediaTools().probe(source if fmt["format_id"]=="post" else donor)
        def fetch(self,fmt,target):
            shutil.copyfile(source if fmt["format_id"]=="post" else donor,target)
            if fmt["format_id"]=="donor": cancelled[0]=True
            return target
    with pytest.raises(InterruptedError):
        QualityDownloader(MediaTools(),cancelled=lambda:cancelled[0],provider=Provider).acquire(MediaItem("123","Post"),tmp_path/"result")
    assert not (tmp_path/"result"/"quality.json").exists()


@pytest.mark.skipif(not shutil.which("ffmpeg"), reason="FFmpeg is required")
def test_transient_high_quality_audio_failure_remains_retryable_instead_of_certifying_lower_quality(tmp_path):
    from offline_tiktok.quality_download import QualityDownloader
    from offline_tiktok.catalog import MediaItem
    picture, donor = tmp_path/"picture.mp4", tmp_path/"donor.mp4"
    make_video(picture, audio_rate="32k")
    make_video(donor, audio_rate="128k", size="120x160")
    class Provider:
        def __init__(self, *args, **kwargs): pass
        def __enter__(self):
            self.info=dict(id="123",formats=[dict(format_id="picture",vcodec="h264"),dict(format_id="donor",vcodec="h264",format_note="watermarked")])
            return self
        def __exit__(self,*args): pass
        def probe(self,fmt): return MediaTools().probe(picture if fmt["format_id"]=="picture" else donor)
        def fetch(self,fmt,target):
            if fmt["format_id"]=="donor": raise RuntimeError("temporary download failure")
            shutil.copyfile(picture,target)
            return target
    with pytest.raises(RuntimeError, match="temporary"):
        QualityDownloader(MediaTools(),provider=Provider).acquire(MediaItem("123","Post"),tmp_path/"result")
    assert not (tmp_path/"result"/"quality.json").exists()
