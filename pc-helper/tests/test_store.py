import hashlib
from pathlib import Path
import pytest
from offline_tiktok.catalog import MediaItem
from offline_tiktok.store import LibraryStore


def test_completed_download_survives_restart_and_detects_corruption(tmp_path):
    media = tmp_path / "movie.mp4"
    media.write_bytes(b"real completed content")
    store = LibraryStore(tmp_path / "db.sqlite")
    store.save_local(MediaItem("1", "Title", status="pending"), media, media)
    store.close()
    restored = LibraryStore(tmp_path / "db.sqlite")
    assert restored.local("1")["sha256"] == hashlib.sha256(b"real completed content").hexdigest()
    assert restored.verified_local("1")
    media.write_bytes(b"changed")
    assert not restored.verified_local("1")
    restored.close()


def test_partial_enumeration_cannot_erase_previous_members(tmp_path):
    store = LibraryStore(tmp_path / "db.sqlite")
    store.update_playlist("p", "Original", ["2", "1"], complete=True)
    with pytest.raises(ValueError, match="incomplete"):
        store.update_playlist("p", "Renamed", ["2"], complete=False)
    assert store.playlists()[0].item_ids == ["2", "1"]
    store.update_playlist("p", "Renamed", ["1", "2", "1"], complete=True)
    assert store.playlists()[0].name == "Renamed"
    assert store.playlists()[0].item_ids == ["1", "2"]
    store.close()


def test_unavailable_source_keeps_already_archived_item(tmp_path):
    store = LibraryStore(tmp_path / "db.sqlite")
    store.save_remote(MediaItem("1", "Old title", status="unavailable"))
    store.record_failure("1", "TikTok no longer exposes this post")
    assert store.catalog().media[0].title == "Old title"
    assert store.failure("1") == "TikTok no longer exposes this post"
    store.close()


def test_upload_checkpoint_round_trips(tmp_path):
    store = LibraryStore(tmp_path / "db.sqlite")
    store.save_upload("digest", "https://upload.example/session", 655360, "2099-01-01T00:00:00Z")
    store.close()
    store = LibraryStore(tmp_path / "db.sqlite")
    assert store.upload("digest")["offset"] == 655360
    assert store.upload("digest")["expires_at"] == "2099-01-01T00:00:00Z"
    store.close()


def test_playback_repair_rolls_back_all_rows_if_one_record_is_missing(tmp_path):
    from offline_tiktok.catalog import AssetRef
    old, new = tmp_path / "old.mp4", tmp_path / "new.mp4"
    old.write_bytes(b"old source")
    new.write_bytes(b"compatible source")
    store = LibraryStore(tmp_path / "db.sqlite")
    old_ref = AssetRef("drive", "old", old.name, old.stat().st_size, hashlib.sha256(old.read_bytes()).hexdigest(), "video/mp4")
    item = MediaItem("1", "Song", asset=old_ref)
    store.save_local(item, old, old)
    store.save_remote(item)
    new_ref = AssetRef("drive", "new", new.name, new.stat().st_size, hashlib.sha256(new.read_bytes()).hexdigest(), "video/mp4")
    replacement = dict(item=MediaItem("1", "Song", asset=new_ref), playback=str(new), sha256=new_ref.sha256, byte_size=new_ref.byte_size)
    with pytest.raises(ValueError, match="original local record"):
        store.replace_playback_copies({"1": replacement, "missing": replacement})
    assert store.item("1").asset == old_ref
    assert store.local("1")["playback"] == str(old.resolve())
    store.close()
