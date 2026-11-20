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


def test_measured_photo_zip_rebuilds_using_official_timing_even_without_cached_video(tmp_path):
    import zipfile
    from io import BytesIO
    from PIL import Image
    from offline_tiktok.archive import CachedDownloader
    from offline_tiktok.media import MediaTools
    from offline_tiktok.photo import PHOTO_RENDER
    item = MediaItem("123", "Photo", kind="slideshow", status="pending")
    cache = tmp_path / "cache" / item.id
    cache.mkdir(parents=True)
    original = cache / "original-photo.zip"
    with zipfile.ZipFile(original, "w") as archive:
        for index, color in enumerate(("red", "blue")):
            image = BytesIO()
            Image.new("RGB", (64, 64), color).save(image, format="PNG")
            archive.writestr(f"image-{index:06}.png", image.getvalue())
    before = original.read_bytes()
    class Fallback:
        def acquire(self, item, cookies): raise AssertionError("The complete ZIP is available")
    measured = {"media": {item.id: dict(status="measured", originalBytes=len(before), playbackBytes=999)}}
    result = CachedDownloader(Fallback(), tmp_path / "cache", measured).acquire(item, [])
    assert result.playback.name == PHOTO_RENDER
    assert abs(MediaTools().probe(result.playback)["duration"] - 6.6) < .05
    assert original.read_bytes() == before


def test_photo_link_that_resolves_to_authored_video_preserves_its_source_timeline(tmp_path, monkeypatch):
    from offline_tiktok.media import MediaDownloader
    from types import SimpleNamespace
    import sys
    job = SimpleNamespace(run=lambda: None, exception=None, data_urls=["https://example.test/linear.mp4"],
        data_meta=[dict(type="video", post_type="video", id="123")], data_post=[dict(id="123", post_type="video")])
    config = SimpleNamespace(set=lambda *args: None)
    monkeypatch.setitem(sys.modules, "gallery_dl", SimpleNamespace(config=config))
    monkeypatch.setitem(sys.modules, "gallery_dl.config", config)
    monkeypatch.setitem(sys.modules, "gallery_dl.job", SimpleNamespace(DataJob=lambda *a, **k: job))
    class LinearTools:
        def compatible(self, path): return path
        def thumbnail(self, path, dest): return dest
        def probe(self, path): return {"duration": 12.7}
        def slideshow(self, *args): raise AssertionError("A linear post already has a timeline")
    def linear(item, directory, cookies):
        assert item.source_url == "https://www.tiktok.com/@fixture/video/123" and item.id == "123"
        path = directory / "original.mp4"
        path.write_bytes(b"authored timeline")
        return path
    downloader = MediaDownloader(tmp_path, tools=LinearTools())
    monkeypatch.setattr(downloader, "_video", linear)
    item = MediaItem("123", "Photo link", source_url="https://www.tiktok.com/@fixture/photo/123",
                     kind="slideshow", status="pending")
    result = downloader.acquire(item)
    assert result.playback.read_bytes() == b"authored timeline"
    assert result.original == result.playback and result.duration == 12.7 and item.kind == "video"


def test_new_photo_import_verifies_order_and_reuses_originals_after_an_interrupted_render(tmp_path, monkeypatch):
    from io import BytesIO
    from types import SimpleNamespace
    import sys
    import zipfile
    import httpx
    from PIL import Image
    from offline_tiktok.media import MediaDownloader
    from offline_tiktok.photo import PHOTO_RENDER

    urls = [f"https://fixture.example/{n}.png" for n in (1, 2)]
    assets = {}
    for url, color in zip(urls, ("green", "blue")):
        data = BytesIO()
        Image.new("RGB", (40, 40), color).save(data, format="PNG")
        assets[url] = data.getvalue()
    images = [{"imageURL": {"urlList": [url]}, "imageWidth": 40, "imageHeight": 40} for url in urls]
    item = MediaItem("321", "Photo", kind="slideshow", source_url="https://www.tiktok.com/@fixture/photo/321",
                     status="pending")
    post = dict(id=item.id, post_type="image", imagePost={"images": images}, video={"duration": 0})
    job = SimpleNamespace(run=lambda: None, exception=None, data_urls=list(reversed(urls)), data_post=[post],
                          data_meta=[dict(id=item.id, type="image", num=n, extension="png") for n in (2, 1)])
    config = SimpleNamespace(set=lambda *args: None)
    api = SimpleNamespace(DataJob=lambda *a, **k: job)
    monkeypatch.setitem(sys.modules, "gallery_dl", SimpleNamespace(config=config))
    monkeypatch.setitem(sys.modules, "gallery_dl.config", config)
    monkeypatch.setitem(sys.modules, "gallery_dl.job", api)
    client = httpx.Client
    transport = httpx.MockTransport(lambda r: httpx.Response(200, content=assets[str(r.url)]))
    monkeypatch.setattr(httpx, "Client", lambda **kwargs: client(transport=transport, **kwargs))
    downloader = MediaDownloader(tmp_path)
    with pytest.raises(ValueError, match="image order"):
        downloader.acquire(item)
    assert not (tmp_path / item.id / "original-photo.zip").exists()
    job.data_meta.reverse()
    job.data_urls.reverse()
    result = downloader.acquire(item)
    assert result.playback.name == PHOTO_RENDER and abs(result.duration - 6.6) < .05
    with zipfile.ZipFile(result.original) as archive:
        assert [archive.read(name) for name in archive.namelist()] == list(assets.values())
    old_checksum = result.original.read_bytes()
    result.playback.unlink()
    api.DataJob = lambda *a, **k: pytest.fail("A retained complete ZIP must resume offline")
    assert downloader.acquire(item).playback.is_file()
    assert result.original.read_bytes() == old_checksum
