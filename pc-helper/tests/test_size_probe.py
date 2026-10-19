from offline_tiktok.catalog import MediaItem
from offline_tiktok.media import Acquisition
from offline_tiktok.size_probe import MediaSizer, report


def test_native_video_storage_counts_original_and_playback_only_once(tmp_path):
    info = {"url": "https://media.example/video.mp4", "ext": "mp4", "title": "Real caption", "uploader_id": "creator"}
    probe = {"video_codec": "hevc", "audio_codec": "aac", "pixel_format": "yuv420p", "codec_tag": "hvc1", "duration": 59}
    sizer = MediaSizer(tmp_path, extract=lambda item: info, size=lambda url: 6173416,
                       probe=lambda url: probe, acquire=lambda item: (_ for _ in ()).throw(AssertionError("Native source needs no second copy")))
    result = sizer.measure(MediaItem("1", "Placeholder", source_url="https://www.tiktok.com/@fixture_creator_5/video/1", status="pending"))
    assert result["status"] == "measured"
    assert result["cloudBytes"] == 6173416
    assert result["originalBytes"] == result["playbackBytes"]
    assert result["title"] == "Real caption"
    assert "downloadURL" not in result
    assert result["qualityPending"] is True


def test_photo_storage_includes_its_retained_original_and_rendered_video(tmp_path):
    original = tmp_path / "original.zip"
    playback = tmp_path / "playback.mp4"
    original.write_bytes(b"x" * 100)
    playback.write_bytes(b"x" * 250)
    acquired = Acquisition(original, playback, tmp_path / "art.jpg", 40)
    sizer = MediaSizer(tmp_path, acquire=lambda item: acquired)
    result = sizer.measure(MediaItem("1", "Photo", kind="slideshow", status="pending"))
    assert result["cloudBytes"] == 350
    assert result["originalBytes"] == 100
    assert result["playbackBytes"] == 250


def test_unsupported_container_is_measured_after_compatibility_conversion(tmp_path):
    original = tmp_path / "original.mkv"
    playback = tmp_path / "playback.mp4"
    original.write_bytes(b"x" * 100)
    playback.write_bytes(b"x" * 150)
    sizer = MediaSizer(tmp_path, extract=lambda item: {"ext": "mkv"},
                       acquire=lambda item: Acquisition(original, playback, tmp_path / "art.jpg", 60))
    result = sizer.measure(MediaItem("1", "Video", status="pending"))
    assert result["cloudBytes"] == 250


def test_mp3_in_mp4_estimate_includes_its_compatible_playback_copy(tmp_path):
    original, playback = tmp_path / "original.mp4", tmp_path / "compatible.mp4"
    original.write_bytes(b"x" * 100)
    playback.write_bytes(b"x" * 250)
    sizer = MediaSizer(tmp_path, extract=lambda item: dict(url="https://media.example/old.mp4", ext="mp4"),
        probe=lambda url: dict(video_codec="h264", audio_codec="mp3", pixel_format="yuv420p", duration=10),
        size=lambda url: 100, acquire=lambda item: Acquisition(original, playback, tmp_path / "art.jpg", 10))
    result = sizer.measure(MediaItem("1", "Photo render", status="pending"))
    assert result["cloudBytes"] == 350


def test_legacy_measurement_is_refreshed_then_the_new_measurement_is_reused(tmp_path):
    import json
    original, playback = tmp_path / "original.zip", tmp_path / "compatible.mp4"
    original.write_bytes(b"x" * 100)
    playback.write_bytes(b"x" * 250)
    item = MediaItem("1", "Photo", kind="slideshow", source_url="https://www.tiktok.com/@fixture_creator_4/photo/1", status="pending")
    path = tmp_path / item.id / "measurement.json"
    path.parent.mkdir()
    path.write_text(json.dumps(dict(sourceURL=item.source_url, cloudBytes=100)))
    calls = []
    def acquire(item):
        calls.append(item.id)
        return Acquisition(original, playback, tmp_path / "art.jpg", 10)
    sizer = MediaSizer(tmp_path, acquire=acquire)
    assert sizer.measure(item)["cloudBytes"] == 350
    assert sizer.measure(item)["cloudBytes"] == 350
    assert calls == ["1"]


def test_playlist_cost_scope_excludes_other_collections_and_their_measurements():
    from offline_tiktok.size_probe import scope_ledger
    ledger = dict(advertisedCollectionCount=27, media={"shared": {}, "music": {}, "other": {}}, collections={
        "wanted": dict(id="wanted", name="Music", advertisedCount=2, itemIds=["shared", "music"], finished=True),
        "unselected": dict(id="unselected", name="Other", advertisedCount=2, itemIds=["shared", "other"], finished=False),
    })
    measurements = {key: dict(status="measured", cloudBytes=size, playbackBytes=size)
                    for key, size in (("shared", 100), ("music", 200), ("other", 10000))}
    selected = scope_ledger(ledger, ["wanted"])
    result = report(selected, measurements, 0.0184)
    assert result["cloudBytes"] == 300
    assert result["uniqueObservedPosts"] == result["measuredPosts"] == 2
    assert list(result["media"]) == ["shared", "music"]
    assert [value["id"] for value in result["collections"]] == ["wanted"]
    assert result["scope"] == dict(kind="selected-playlists", playlistIds=["wanted"])
    assert result["accountAdvertisedCollectionCount"] == 27
    assert result["advertisedCollectionCount"] == 1
    assert len(ledger["media"]) == 3  # The account membership remains intact.


def test_unknown_playlist_cost_scope_fails_instead_of_auditing_everything():
    import pytest
    from offline_tiktok.size_probe import scope_ledger
    with pytest.raises(ValueError, match="Unknown playlist"):
        scope_ledger(dict(advertisedCollectionCount=0, media={}, collections={}), ["missing"])


def test_a_fast_source_estimate_cannot_claim_complete_upgraded_quality_storage():
    ledger=dict(advertisedCollectionCount=1,media={"1":{}},collections={"p":dict(id="p",name="Music",advertisedCount=1,itemIds=["1"],finished=True)})
    measured={"1":dict(status="measured",cloudBytes=100,playbackBytes=100,qualityPending=True)}
    result=report(ledger,measured,.0184)
    assert not result["complete"] and result["totalsAreLowerBounds"]
    assert result["qualityPendingPosts"] == 1


def test_native_probe_reuses_the_confirmed_range_length(tmp_path):
    import io
    from urllib.request import Request, urlopen

    class Response(io.BytesIO):
        status = 206
        headers = {"Content-Length": "1", "Content-Range": "bytes 0-0/6173416", "Content-Type": "video/mp4"}

    class Downloader:
        def urlopen(self, request):
            return Response(b"x")

        def close(self):
            pass

    def probe(url):
        with urlopen(Request(url, headers={"Range": "bytes=0-0"})) as response:
            assert response.read() == b"x"
        return dict(video_codec="hevc", audio_codec="aac", pixel_format="yuv420p", codec_tag="hvc1", duration=59)

    sizer = MediaSizer(tmp_path, extract=lambda item: dict(url="https://media.example/video.mp4", ext="mp4"),
                       probe=probe, size=lambda url: (_ for _ in ()).throw(AssertionError("The native probe already confirmed the complete length")))
    sizer.downloader = Downloader()
    try:
        result = sizer.measure(MediaItem("1", "Music", status="pending"))
        assert result["cloudBytes"] == 6173416
    finally:
        sizer.close()


def test_missing_members_and_failed_measurements_are_explicitly_incomplete():
    ledger = dict(advertisedCollectionCount=1, media={"1": {}, "2": {}, "3": {}}, collections={
        "music": dict(id="music", name="Music", advertisedCount=5, itemIds=["1", "2", "3"], finished=False),
    })
    measurements = {"1": dict(status="measured", cloudBytes=100, playbackBytes=100),
                    "2": dict(status="unmeasured", reason="Source unavailable")}
    result = report(ledger, measurements, 0.0184)
    assert not result["complete"]
    assert result["totalsAreLowerBounds"]
    assert result["unobservedPlaylistEntries"] == 2
    assert result["failedObservedPosts"] == 1
    assert result["pendingObservedPosts"] == 1
    assert result["cloudBytes"] == 100
    collection = result["collections"][0]
    assert collection["unobservedCount"] == 2
    assert collection["unmeasuredCount"] == 2
    assert not collection["complete"]


def test_complete_cost_requires_both_full_membership_and_all_measurements():
    ledger = dict(advertisedCollectionCount=1, media={"1": {}}, collections={
        "music": dict(id="music", name="Music", advertisedCount=1, itemIds=["1"], finished=True),
    })
    measurements = {"1": dict(status="measured", cloudBytes=100, playbackBytes=100)}
    result = report(ledger, measurements, 0.0184)
    assert result["complete"]
    assert not result["totalsAreLowerBounds"]
    assert result["unobservedPlaylistEntries"] == result["failedObservedPosts"] == result["pendingObservedPosts"] == 0
    ledger["collections"]["music"]["advertisedCount"] = 2
    assert not report(ledger, measurements, 0.0184)["complete"]
