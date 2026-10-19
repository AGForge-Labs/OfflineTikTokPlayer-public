import json
from pathlib import Path
import shutil
import subprocess
from types import SimpleNamespace
import pytest
from offline_tiktok.catalog import AssetRef, MediaItem
from offline_tiktok.media import MediaTools
from offline_tiktok.store import LibraryStore, checksum
from test_audio_repair import Cloud
from test_source_quality import make_video

pytestmark = pytest.mark.skipif(not shutil.which("ffmpeg"), reason="FFmpeg is required")


def fixture(tmp_path, *, old_size="160x240", new_size="160x240", sound="313"):
    old, candidate = tmp_path / "old.mp4", tmp_path / "candidate.mp4"
    make_video(old, audio_rate="32k", size=old_size)
    make_video(candidate, audio_rate="128k", size=new_size, sound=sound)
    store = LibraryStore(tmp_path / "library.sqlite")
    store.update_playlist("music", "Music", ["123"], complete=True)
    asset = AssetRef("drive", "old", old.name, old.stat().st_size, checksum(old), "video/mp4")
    item = MediaItem("123", "Post", duration=4, asset=asset, original=asset, artwork=asset,
                     source_url="https://www.tiktok.com/@fixture_creator_5/video/123")
    store.save_local(item, old, old)
    store.save_remote(item)
    source = SimpleNamespace(acquire=lambda item, cookies: SimpleNamespace(playback=candidate, original=candidate))
    return store, old, candidate, asset, source


def test_quality_repair_changes_only_verified_playback_after_successful_publication(tmp_path):
    from offline_tiktok.quality_repair import QualityRepair
    from offline_tiktok.source_quality import stream_digest
    store, old, candidate, asset, source = fixture(tmp_path)
    original = old.read_bytes()
    cloud = Cloud()
    repair = QualityRepair(store, MediaTools(), tmp_path / "quality.json", downloader=source, graph=cloud)
    assert repair.prepare() == 1
    entry = repair.state["items"]["123"]
    assert stream_digest(entry["playback"], "audio") == stream_digest(candidate, "audio", duration=4)
    assert store.item("123").asset == asset and cloud.published is None
    catalog = repair.sync()
    assert store.item("123").asset.sha256 == entry["sha256"]
    assert store.item("123").original == asset and store.item("123").artwork == asset
    assert store.local("123")["original"] == str(old.resolve())
    assert store.verified_local("123") and old.read_bytes() == original
    assert catalog.playlists[0].item_ids == ["123"]
    assert (tmp_path / "quality-repair-previous-catalog.json").exists()
    store.close()


def test_better_audio_cannot_downgrade_an_existing_higher_resolution_picture(tmp_path):
    from offline_tiktok.quality_repair import QualityRepair
    from offline_tiktok.source_quality import stream_digest
    store, old, candidate, asset, source = fixture(tmp_path, old_size="240x320", new_size="120x160")
    repair = QualityRepair(store, MediaTools(), tmp_path / "quality.json", downloader=source)
    repair.prepare()
    entry = repair.state["items"]["123"]
    assert stream_digest(entry["playback"], "video") == stream_digest(old, "video")
    assert MediaTools().probe(entry["playback"])["audio_bitrate"] > 110000
    store.close()


def test_unmatched_or_unavailable_source_leaves_ready_archive_playable_and_retryable(tmp_path):
    from offline_tiktok.quality_repair import QualityRepair
    store, old, candidate, asset, source = fixture(tmp_path, sound="661")
    path = tmp_path / "quality.json"
    repair = QualityRepair(store, MediaTools(), path, downloader=source)
    assert repair.prepare() == 0
    assert "123" in repair.state["issues"] and "123" not in repair.state["checked"]
    assert store.item("123").asset == asset and store.item("123").status == "ready"
    def unavailable(*args): raise RuntimeError("Temporary source failure")
    source.acquire = unavailable
    resumed = QualityRepair(store, MediaTools(), path, downloader=source)
    assert resumed.prepare() == 0
    assert store.item("123").asset == asset and store.verified_local("123")
    assert "Temporary source failure" in resumed.state["issues"]["123"]["reason"]
    store.close()


def test_quality_publication_failure_resumes_without_replacing_originals_or_losing_new_additions(tmp_path):
    from offline_tiktok.quality_repair import QualityRepair
    store, old, candidate, asset, source = fixture(tmp_path)
    cloud = Cloud(fail_publish=True)
    path = tmp_path / "quality.json"
    repair = QualityRepair(store, MediaTools(), path, downloader=source, graph=cloud)
    repair.prepare()
    with pytest.raises(RuntimeError, match="publication"): repair.sync()
    assert store.item("123").asset == asset
    uploads = dict(cloud.uploaded)
    store.update_playlist("music", "Renamed Music", ["456", "123"], complete=True)
    cloud.fail_publish = False
    resumed = QualityRepair(store, MediaTools(), path, downloader=source, graph=cloud)
    resumed.sync()
    assert cloud.uploaded == uploads
    assert cloud.published.playlists[0].item_ids == ["456", "123"]
    assert cloud.published.playlists[0].name == "Renamed Music"
    store.close()


def test_equal_source_is_checked_once_and_pause_retains_checkpoints(tmp_path):
    from offline_tiktok.quality_repair import QualityRepair
    store, old, candidate, asset, source = fixture(tmp_path)
    source.acquire = lambda *args: SimpleNamespace(playback=old, original=old)
    path = tmp_path / "quality.json"
    repair = QualityRepair(store, MediaTools(), path, downloader=source)
    assert repair.prepare() == 0 and "123" in repair.state["checked"]
    source.acquire = lambda *args: pytest.fail("A checked unchanged asset must resume without another download")
    assert QualityRepair(store, MediaTools(), path, downloader=source).prepare() == 0
    paused = QualityRepair(store, MediaTools(), path, downloader=source, cancelled=lambda:True)
    with pytest.raises(InterruptedError): paused.prepare()
    assert json.loads(path.read_text())["checked"]["123"]["sha256"] == asset.sha256
    store.close()


def test_changed_soundtrack_is_rejected_even_when_both_new_tracks_would_win(tmp_path):
    from offline_tiktok.quality_repair import QualityRepair
    store, old, candidate, asset, source = fixture(tmp_path, old_size="120x160", new_size="240x320", sound="661")
    repair = QualityRepair(store, MediaTools(), tmp_path / "quality.json", downloader=source)
    assert repair.prepare() == 0
    assert "123" in repair.state["issues"]
    assert store.item("123").asset == asset
    store.close()


def test_compatibility_alac_is_ranked_using_its_lossy_mp3_source(tmp_path):
    from offline_tiktok.quality_repair import QualityRepair
    store, old, candidate, asset, source = fixture(tmp_path)
    mp3 = tmp_path / "source-with-mp3.mp4"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(old), "-c:v", "copy", "-c:a", "libmp3lame", "-b:a", "32k", str(mp3)], check=True, capture_output=True)
    alac = MediaTools().compatible(mp3)
    item = store.item("123")
    item.asset = AssetRef("drive", "alac", alac.name, alac.stat().st_size, checksum(alac), "video/mp4")
    item.original = AssetRef("drive", "mp3", mp3.name, mp3.stat().st_size, checksum(mp3), "video/mp4")
    store.save_local(item, mp3, alac)
    store.save_remote(item)
    repair = QualityRepair(store, MediaTools(), tmp_path / "quality.json", downloader=source)
    assert repair.prepare() == 1
    assert repair.state["items"]["123"]["improvedAudio"] is True
    assert repair.state["items"]["123"]["current"]["audio_codec"] == "aac"
    store.close()


def test_fractional_frame_rate_rounding_cannot_replace_a_higher_bitrate_picture():
    from offline_tiktok.quality_repair import _better_picture
    old = dict(width=960, height=720, fps=30000/1001, video_bitrate=596314)
    new = dict(width=960, height=720, fps=30, video_bitrate=208800)
    assert not _better_picture(old, new)


def test_previously_silent_archive_requires_an_audio_reference_for_replacement(tmp_path):
    from offline_tiktok.quality_repair import QualityRepair
    store, old, candidate, asset, source = fixture(tmp_path)
    silent = tmp_path / "silent.mp4"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(old), "-an", "-c:v", "copy", str(silent)], check=True, capture_output=True)
    item = store.item("123")
    item.asset = item.original = AssetRef("drive", "silent", silent.name, silent.stat().st_size, checksum(silent), "video/mp4")
    store.save_local(item, silent, silent)
    store.save_remote(item)
    repair = QualityRepair(store, MediaTools(), tmp_path / "quality.json", downloader=source)
    assert repair.prepare() == 0
    assert "reference" in repair.state["issues"]["123"]["reason"]
    store.close()


def test_silent_compatibility_copy_can_recover_sound_from_verified_retained_source(tmp_path):
    from offline_tiktok.quality_repair import QualityRepair
    store, old, candidate, asset, source = fixture(tmp_path)
    silent = tmp_path / "silent.mp4"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(candidate), "-an", "-c:v", "copy", str(silent)], check=True, capture_output=True)
    item = store.item("123")
    item.asset = AssetRef("drive", "silent", silent.name, silent.stat().st_size, checksum(silent), "video/mp4")
    item.original = AssetRef("drive", "source", candidate.name, candidate.stat().st_size, checksum(candidate), "video/mp4")
    store.save_local(item, candidate, silent)
    store.save_remote(item)
    repair = QualityRepair(store, MediaTools(), tmp_path / "quality.json", downloader=source)
    assert repair.prepare() == 1
    assert repair.state["items"]["123"]["current"]["audio_codec"] == "aac"
    store.close()


def test_a_brief_windows_reader_lock_does_not_abort_a_quality_checkpoint(tmp_path, monkeypatch):
    from offline_tiktok.quality_repair import QualityRepair
    store, old, candidate, asset, source = fixture(tmp_path)
    journal = tmp_path / "quality.json"
    replace, attempts = Path.replace, []
    def busy_once(path, target):
        if Path(target) == journal:
            attempts.append(target)
            if len(attempts) == 1: raise PermissionError("Reader briefly denies replacement")
        return replace(path, target)
    monkeypatch.setattr(Path, "replace", busy_once)
    repair = QualityRepair(store, MediaTools(), journal, downloader=source)
    assert repair.prepare() == 1
    assert len(attempts) == 2 and json.loads(journal.read_text())["items"]["123"]
    store.close()


def test_cancellation_during_a_checkpoint_reader_lock_retains_the_previous_record(tmp_path, monkeypatch):
    from offline_tiktok.cost_audit import atomic_json
    import offline_tiktok.cost_audit
    journal = tmp_path / "quality.json"
    journal.write_text('{"previous":true}')
    cancelled = [False]
    def check():
        if cancelled[0]: raise InterruptedError("paused")
    def locked(*args): raise PermissionError("Reader lock")
    monkeypatch.setattr(Path, "replace", locked)
    monkeypatch.setattr(offline_tiktok.cost_audit.time, "sleep", lambda seconds:cancelled.__setitem__(0,True))
    with pytest.raises(InterruptedError): atomic_json(journal, dict(replacement=True), check=check)
    assert json.loads(journal.read_text()) == dict(previous=True)


def test_cli_refuses_a_second_quality_writer_before_opening_the_library(tmp_path, monkeypatch):
    from offline_tiktok.quality_repair import main
    from offline_tiktok.instance import HelperInstance
    owner=HelperInstance(tmp_path/"quality-repair-v1"/"job")
    assert owner.acquire()
    monkeypatch.setattr("sys.argv",["quality_repair","--data-dir",str(tmp_path)])
    try:
        with pytest.raises(RuntimeError,match="already running"): main()
        assert not (tmp_path/"library.sqlite").exists()
    finally:
        owner.close()
