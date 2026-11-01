import json
import math
from pathlib import Path
import struct
import wave

import pytest

from offline_tiktok.catalog import Catalog, MediaItem
from offline_tiktok.media import MediaTools


MEASUREMENT = {"version": 1, "assetSHA256": "a" * 64,
               "integratedLUFS": -26.27, "truePeakDBTP": -11.36}


def media_wire():
    return dict(id="quiet", title="Quiet music", duration=4, kind="video", status="ready",
        asset=dict(driveId="drive", itemId="asset", fileName="video.mp4", byteSize=100,
                   sha256="a" * 64, contentType="video/mp4"), audioLoudness=dict(MEASUREMENT))


def test_optional_loudness_survives_catalog_and_store_round_trip(tmp_path):
    from offline_tiktok.store import LibraryStore
    item = MediaItem.decode(media_wire())
    store = LibraryStore(tmp_path / "library.sqlite")
    try:
        store.save_remote(item)
        decoded = Catalog.from_json(store.catalog().to_json()).media[0]
        assert decoded.wire().get("audioLoudness") == MEASUREMENT
    finally:
        store.close()


@pytest.mark.parametrize("field,value", [("integratedLUFS", float("nan")),
    ("integratedLUFS", -150), ("truePeakDBTP", float("inf")), ("version", 2),
    ("version", True), ("assetSHA256", "bad")])
def test_invalid_measurements_cannot_enter_a_published_catalog(field, value):
    wire = media_wire()
    wire["audioLoudness"][field] = value
    with pytest.raises(ValueError):
        Catalog("library", media=[MediaItem.decode(wire)]).to_json()


def test_older_catalog_remains_playable_without_measurement():
    wire = media_wire()
    wire.pop("audioLoudness")
    catalog = Catalog.from_json(Catalog("library", media=[MediaItem.decode(wire)]).to_json())
    assert catalog.media[0].asset.sha256 == "a" * 64
    assert catalog.media[0].wire().get("audioLoudness") is None


def tone(path: Path, amplitude: float):
    with wave.open(str(path), "wb") as stream:
        stream.setnchannels(1)
        stream.setsampwidth(2)
        stream.setframerate(48000)
        stream.writeframes(b"".join(struct.pack("<h", round(amplitude * 32767 * math.sin(2 * math.pi * 1000 * n / 48000)))
                                  for n in range(48000 * 4)))


def test_real_audio_measurement_finds_twelve_db_quiet_difference_and_source_hash(tmp_path):
    tools = MediaTools()
    analyzer = getattr(tools, "loudness", None)
    assert callable(analyzer), "MediaTools must measure loudness before new media is published"
    quiet, loud = tmp_path / "quiet.wav", tmp_path / "loud.wav"
    tone(quiet, 0.02)
    tone(loud, 0.08)
    low, high = analyzer(quiet), analyzer(loud)
    from offline_tiktok.store import checksum
    assert low.asset_sha256 == checksum(quiet)
    assert high.asset_sha256 == checksum(loud)
    assert high.integrated_lufs - low.integrated_lufs == pytest.approx(12.04, abs=0.15)
    assert high.true_peak_dbtp - low.true_peak_dbtp == pytest.approx(12.04, abs=0.15)
    assert low.integrated_lufs < -30


def test_digital_silence_has_no_boost_measurement(tmp_path):
    analyzer = getattr(MediaTools(), "loudness", None)
    assert callable(analyzer), "Silence must be analyzed without manufacturing infinite gain"
    path = tmp_path / "silence.wav"
    tone(path, 0)
    assert analyzer(path) is None


def test_new_import_carries_measured_gain_for_its_uploaded_playback_asset(tmp_path):
    from types import SimpleNamespace
    from test_pipeline import Browser, Downloader, Cloud
    from offline_tiktok.browser import Collection
    from offline_tiktok.catalog import AudioLoudness
    from offline_tiktok.pipeline import ImportPipeline
    from offline_tiktok.store import LibraryStore, checksum
    downloader = Downloader(tmp_path)
    downloader.tools = SimpleNamespace(loudness=lambda path: AudioLoudness(checksum(path), -26.27, -11.36))
    store, cloud = LibraryStore(tmp_path / "library.sqlite"), Cloud()
    try:
        pipeline = ImportPipeline(store, Browser(), downloader, cloud)
        pipeline.prepare([Collection("a", "Music", "url")])
        pipeline.sync(["a"])
        published = json.loads(cloud.published)["media"]
        assert len(published) == 2
        for item in published:
            assert item.get("audioLoudness", {}).get("assetSHA256") == item["asset"]["sha256"]
            assert item["audioLoudness"]["integratedLUFS"] == -26.27
    finally:
        store.close()


def test_failed_analysis_keeps_import_playable_and_reports_missing_measurement(tmp_path):
    from types import SimpleNamespace
    from test_pipeline import Browser, Downloader, Cloud
    from offline_tiktok.browser import Collection
    from offline_tiktok.pipeline import ImportPipeline
    from offline_tiktok.store import LibraryStore
    def failed(path):
        raise ValueError("Native analysis unavailable")
    downloader = Downloader(tmp_path)
    downloader.tools = SimpleNamespace(loudness=failed)
    store, cloud, messages = LibraryStore(tmp_path / "library.sqlite"), Cloud(), []
    try:
        pipeline = ImportPipeline(store, Browser(), downloader, cloud, progress=messages.append)
        pipeline.prepare([Collection("a", "Music", "url")])
        pipeline.sync(["a"])
        assert all(item.status == "ready" for item in store.catalog().media)
        assert any("loudness" in message.lower() for message in messages)
        assert all(item.wire().get("audioLoudness") is None for item in store.catalog().media)
    finally:
        store.close()


def test_audit_merge_changes_only_matching_measurements_in_the_fresh_catalog():
    from offline_tiktok import audio_analysis
    from offline_tiktok.catalog import Playlist
    merger = getattr(audio_analysis, "merge_loudness", None)
    assert callable(merger), "The archived-library audit needs a checksum-bound additive merge"
    first = media_wire()
    first.pop("audioLoudness")
    second = media_wire()
    second["id"] = "changed"
    second["asset"]["sha256"] = "b" * 64
    second.pop("audioLoudness")
    third = MediaItem("new", "New import", status="pending")
    catalog = Catalog("original-library", [MediaItem.decode(first), MediaItem.decode(second), third],
                      [Playlist("music", "Renamed collection", ["new", "quiet", "changed"])])
    original = catalog.to_json()
    reports = {key: dict(id=key, status="measured", sha256="a" * 64, integratedLUFS=-26.27, truePeakDBTP=-11.36)
               for key in ("quiet", "changed")}
    updated, changed = merger(catalog, {"version": 1, "items": reports})
    assert changed == ["quiet"]
    assert catalog.to_json() == original
    assert updated.library_id == "original-library"
    assert updated.playlists[0].wire() == catalog.playlists[0].wire()
    assert len(updated.media) == 3
    assert updated.media[0].wire()["audioLoudness"] == MEASUREMENT
    assert updated.media[1].wire() == catalog.media[1].wire()
    assert updated.media[2].wire() == catalog.media[2].wire()
    again, repeated = merger(updated, {"version": 1, "items": reports})
    assert repeated == []
    assert again.to_json() == updated.to_json()


def test_audit_merge_rejects_corrupt_report_before_any_mutation():
    from offline_tiktok import audio_analysis
    merger = getattr(audio_analysis, "merge_loudness", None)
    assert callable(merger)
    catalog = Catalog("library", [MediaItem.decode(media_wire())])
    original = catalog.to_json()
    with pytest.raises(ValueError):
        merger(catalog, {"version": 1, "items": {"quiet": dict(id="quiet", status="measured", sha256="a" * 64,
            integratedLUFS=float("nan"), truePeakDBTP=-2)}})
    assert catalog.to_json() == original
