from pathlib import Path
import pytest
from offline_tiktok.catalog import MediaItem


def test_low_disk_space_pauses_download_instead_of_losing_membership(tmp_path, monkeypatch):
    from offline_tiktok.media import MediaDownloader
    import shutil
    monkeypatch.setattr(shutil, "disk_usage", lambda path: type("Usage", (), {"free": 100})())
    monkeypatch.setattr(MediaDownloader, "_video", lambda *args: pytest.fail("Low storage must stop before contacting TikTok"))
    with pytest.raises(InterruptedError, match="storage"):
        MediaDownloader(tmp_path).acquire(MediaItem("123", "Video", source_url="https://www.tiktok.com/@fixture_creator_4/video/123", status="pending"))


def test_a_size_measurement_does_not_imply_a_downloaded_video(tmp_path):
    from offline_tiktok.archive import CachedDownloader
    from offline_tiktok.media import Acquisition
    item = MediaItem("123", "Video", status="pending")
    cache = tmp_path / "cache" / item.id
    cache.mkdir(parents=True)
    (cache / "original.mp4").write_bytes(b"partial")
    calls = []
    class Fallback:
        def acquire(self, item, cookies): calls.append(item.id); return "full download"
    downloader = CachedDownloader(Fallback(), tmp_path / "cache", {"media": {"123": {"status": "measured", "originalBytes": 100, "playbackBytes": 100}}})
    assert downloader.acquire(item, []) == "full download"
    assert calls == ["123"]


def test_complete_cached_original_is_reused_and_probed(tmp_path):
    import json
    import hashlib
    from offline_tiktok.archive import CachedDownloader
    item = MediaItem("123", "Video", status="pending")
    cache = tmp_path / "cache" / item.id
    cache.mkdir(parents=True)
    (cache / "source-quality-v1").mkdir()
    original = cache / "source-quality-v1" / "original.mp4"
    original.write_bytes(b"whole media")
    original.with_name("quality.json").write_text(json.dumps(dict(version=1, postID="123", byteSize=original.stat().st_size,
        sha256=hashlib.sha256(original.read_bytes()).hexdigest())))
    artwork = cache / "artwork.jpg"
    artwork.write_bytes(b"artwork")
    class Fallback:
        def acquire(self, item, cookies): raise AssertionError("A complete cached original must not redownload")
    class Tools:
        def probe(self, path): return {"duration": 30, "video_codec": "h264"}
        def compatible(self, path): return path
    count = len(b"whole media")
    downloader = CachedDownloader(Fallback(), tmp_path / "cache", {"media": {"123": {"status": "measured", "originalBytes": count, "playbackBytes": count}}}, tools=Tools())
    result = downloader.acquire(item, [])
    assert result.original == original
    assert result.playback == original
    assert result.duration == 30


def test_cached_legacy_photo_render_is_repaired_before_reuse(tmp_path):
    import shutil
    from offline_tiktok.archive import CachedDownloader
    from offline_tiktok.media import MediaTools
    if not shutil.which("ffmpeg"): pytest.skip("FFmpeg is required")
    item = MediaItem("123", "Photo", kind="slideshow", status="pending")
    cache = tmp_path / "cache" / item.id
    cache.mkdir(parents=True)
    original = cache / "original-photo.zip"
    original.write_bytes(b"retained original photos and audio")
    fixture = Path(__file__).resolve().parents[2] / "ios/OfflineTikTokPlayerTests/test-slideshow-mp3.mp4"
    playback = cache / "slideshow.mp4"
    shutil.copyfile(fixture, playback)
    (cache / "artwork.jpg").write_bytes(b"existing artwork")
    class Fallback:
        def acquire(self, item, cookies): raise AssertionError("Cached source must not redownload")
    measured = {"media": {item.id: dict(status="measured", originalBytes=original.stat().st_size, playbackBytes=playback.stat().st_size)}}
    result = CachedDownloader(Fallback(), tmp_path / "cache", measured).acquire(item, [])
    assert result.original == original
    assert result.playback != playback
    assert MediaTools().probe(result.playback)["audio_codec"] == "alac"
