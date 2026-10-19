import hashlib
import json
import os
from types import SimpleNamespace
from offline_tiktok.media import MediaDownloader


def test_retry_uses_verified_quality_source_without_selecting_a_newer_derived_copy(tmp_path, monkeypatch):
    import yt_dlp
    original = tmp_path / "original.webm"
    original.write_bytes(b"retained earlier source")
    derived = tmp_path / "original.iphone.mp4"
    derived.write_bytes(b"unfinished compatibility copy")
    quality = tmp_path / "source-quality-v1" / "original.mp4"
    quality.parent.mkdir()
    quality.write_bytes(b"verified source-quality post")
    quality.with_name("quality.json").write_text(json.dumps(dict(version=1, postID="123", byteSize=quality.stat().st_size,
        sha256=hashlib.sha256(quality.read_bytes()).hexdigest())))
    os.utime(quality, (100, 100))
    os.utime(derived, (200, 200))
    monkeypatch.setattr(yt_dlp, "YoutubeDL", lambda *args, **kwargs: (_ for _ in ()).throw(AssertionError("Verified completion must resume without a network request")))
    item = SimpleNamespace(id="123", source_url="https://www.tiktok.com/@fixture_creator_5/video/123")
    assert MediaDownloader(tmp_path)._video(item, tmp_path, ()) == quality
    assert original.read_bytes() == b"retained earlier source"
    assert derived.read_bytes() == b"unfinished compatibility copy"


def test_stream_cache_requires_a_matching_verified_receipt_before_reuse(tmp_path, monkeypatch):
    import yt_dlp
    from offline_tiktok.quality_download import TikTokSource, source_identity
    target = tmp_path / "picture.mp4"
    target.write_bytes(b"OLD")
    fmt = dict(format_id="post", url="https://media.example/video?secret=PRIVATE", filesize=3)
    details = dict(width=160, height=240, video_codec="h264", audio_codec="aac", duration=4, audio_bitrate=128000)
    source = TikTokSource.__new__(TikTokSource)
    source.item = SimpleNamespace(id="123", title="Post", source_url="https://www.tiktok.com/@fixture_creator_5/video/123")
    source.tools = SimpleNamespace(ffmpeg="ffmpeg", probe=lambda path: dict(details))
    source.downloader = SimpleNamespace(cookiejar=[])
    source.info = {}
    source.probes = {source_identity(fmt):details}
    source.progress = lambda message: None
    source.cancelled = lambda: False
    calls = []
    class Writer:
        def __init__(self, options): self.target = options["outtmpl"]; self.cookiejar = []
        def __enter__(self): return self
        def __exit__(self, *args): pass
        def process_ie_result(self, info, download):
            calls.append("download")
            if not target.exists(): target.write_bytes(b"NEW")
    monkeypatch.setattr(yt_dlp,"YoutubeDL",Writer)
    assert source.fetch(fmt,target) == target and target.read_bytes() == b"NEW"
    assert source.fetch(fmt,target) == target and calls == ["download"]
    assert "PRIVATE" not in target.with_suffix(".source.json").read_text()
    target.write_bytes(b"BAD")
    source.fetch(fmt,target)
    assert target.read_bytes() == b"NEW" and calls == ["download","download"]


def test_query_addressed_sources_do_not_share_a_cache_receipt():
    from offline_tiktok.quality_download import source_identity
    common = dict(format_id="post", filesize=100)
    assert source_identity(dict(common, url="https://api.example/play/?video_id=1")) != source_identity(dict(common, url="https://api.example/play/?video_id=2"))
