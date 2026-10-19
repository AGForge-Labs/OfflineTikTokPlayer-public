from pathlib import Path
import hashlib
import shutil
import subprocess
import pytest
from offline_tiktok.audio_repair import AudioRepair
from offline_tiktok.catalog import AssetRef, MediaItem, Catalog
from offline_tiktok.graph import StorageFull
from offline_tiktok.media import MediaTools
from offline_tiktok.store import LibraryStore, checksum

pytestmark = pytest.mark.skipif(not shutil.which("ffmpeg"), reason="FFmpeg is required")


class Cloud:
    def __init__(self, remaining=10000000, fail_publish=False):
        self.remaining, self.fail_publish = remaining, fail_publish
        self.uploaded = {}
        self.published = None
    def app_folder(self): return "drive", "root"
    def quota(self): return {"remaining": self.remaining}
    def folder(self, name, drive, root): return name
    def upload_file(self, source, name, drive, folder):
        self.uploaded[name] = Path(source).read_bytes()
        return AssetRef(drive, "new:" + name, name, Path(source).stat().st_size, checksum(source), "video/mp4")
    def verify_file(self, ref, source):
        value = self.uploaded.get(ref.file_name)
        return value is not None and len(value) == ref.byte_size and hashlib.sha256(value).hexdigest() == ref.sha256
    def publish(self, catalog, drive, root):
        if self.fail_publish: raise RuntimeError("publication interrupted")
        self.published = Catalog.from_json(catalog.to_json())


def library(tmp_path):
    path = tmp_path / "old.mp4"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "color=c=green:s=160x240:r=12:d=1",
                    "-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                    "-c:a", "libmp3lame", "-shortest", str(path)], check=True, capture_output=True)
    original = tmp_path / "original.zip"
    original.write_bytes(b"original photos and MP3 soundtrack")
    store = LibraryStore(tmp_path / "db.sqlite")
    store.update_playlist("music", "Music", ["1"], complete=True)
    ref = AssetRef("drive", "old", path.name, path.stat().st_size, checksum(path), "video/mp4")
    original_ref = AssetRef("drive", "original", original.name, original.stat().st_size, checksum(original), "application/zip")
    item = MediaItem("1", "Photo post", duration=1, kind="slideshow", asset=ref, original=original_ref, artwork=ref)
    store.save_local(item, original, path)
    store.save_remote(item)
    return store, path, original, ref


def test_repair_publishes_new_playback_after_upload_and_keeps_original_and_membership(tmp_path):
    store, old, original, ref = library(tmp_path)
    old_bytes, original_bytes = old.read_bytes(), original.read_bytes()
    original_ref, artwork_ref = store.item("1").original, store.item("1").artwork
    cloud = Cloud()
    repair = AudioRepair(store, MediaTools(), tmp_path / "repair.json", graph=cloud)
    assert repair.prepare() == 1
    assert store.item("1").asset == ref
    assert store.local("1")["playback"] == str(old.resolve())
    updated = repair.sync()
    assert updated.playlists[0].item_ids == ["1"]
    assert store.item("1").asset.sha256 != ref.sha256
    assert store.item("1").original == original_ref
    assert store.item("1").artwork == artwork_ref
    assert MediaTools().probe(store.local("1")["playback"])["audio_codec"] == "alac"
    assert store.verified_local("1")
    assert old.read_bytes() == old_bytes and original.read_bytes() == original_bytes
    assert cloud.published.media[0].asset == store.item("1").asset
    store.close()


def test_failed_publication_retains_old_library_and_resume_reuses_the_uploaded_copy(tmp_path):
    store, old, original, ref = library(tmp_path)
    cloud = Cloud(fail_publish=True)
    state = tmp_path / "repair.json"
    repair = AudioRepair(store, MediaTools(), state, graph=cloud)
    repair.prepare()
    with pytest.raises(RuntimeError, match="interrupted"): repair.sync()
    assert store.item("1").asset == ref
    assert store.local("1")["playback"] == str(old.resolve())
    assert cloud.published is None
    uploaded = dict(cloud.uploaded)
    store.close()
    store = LibraryStore(tmp_path / "db.sqlite")
    cloud.fail_publish = False
    AudioRepair(store, MediaTools(), state, graph=cloud).sync()
    assert store.item("1").asset != ref
    assert cloud.uploaded == uploaded
    store.close()


def test_quota_failure_does_not_replace_the_library(tmp_path):
    store, old, original, ref = library(tmp_path)
    cloud = Cloud(remaining=0)
    repair = AudioRepair(store, MediaTools(), tmp_path / "repair.json", graph=cloud)
    repair.prepare()
    with pytest.raises(StorageFull): repair.sync()
    assert store.item("1").asset == ref
    assert cloud.published is None and not cloud.uploaded
    store.close()


def test_changed_prepared_file_never_becomes_a_published_asset(tmp_path):
    store, old, original, ref = library(tmp_path)
    cloud = Cloud()
    repair = AudioRepair(store, MediaTools(), tmp_path / "repair.json", graph=cloud)
    repair.prepare()
    old.with_name("old.iphone.mp4").write_bytes(b"interrupted or altered")
    with pytest.raises(ValueError, match="changed|verification"): repair.sync()
    assert store.item("1").asset == ref
    assert cloud.published is None and not cloud.uploaded
    store.close()


def test_resume_repairs_a_remote_copy_changed_after_an_interrupted_publication(tmp_path):
    store, old, original, ref = library(tmp_path)
    cloud = Cloud(fail_publish=True)
    state = tmp_path / "repair.json"
    repair = AudioRepair(store, MediaTools(), state, graph=cloud)
    repair.prepare()
    with pytest.raises(RuntimeError): repair.sync()
    name = next(iter(cloud.uploaded))
    cloud.uploaded[name] = b"x" * len(cloud.uploaded[name])
    cloud.fail_publish = False
    AudioRepair(store, MediaTools(), state, graph=cloud).sync()
    published = cloud.published.media[0].asset
    assert hashlib.sha256(cloud.uploaded[published.file_name]).hexdigest() == published.sha256
    assert store.item("1").asset == published
    store.close()


def test_publication_success_then_database_failure_can_be_resumed(tmp_path, monkeypatch):
    store, old, original, ref = library(tmp_path)
    cloud = Cloud()
    state = tmp_path / "repair.json"
    repair = AudioRepair(store, MediaTools(), state, graph=cloud)
    repair.prepare()
    def failed_commit(replacements): raise RuntimeError("disk write interrupted")
    monkeypatch.setattr(store, "replace_playback_copies", failed_commit)
    with pytest.raises(RuntimeError, match="disk write"): repair.sync()
    assert cloud.published.media[0].asset != ref
    assert store.item("1").asset == ref
    store.close()
    store = LibraryStore(tmp_path / "db.sqlite")
    AudioRepair(store, MediaTools(), state, graph=cloud).sync()
    assert store.item("1").asset == cloud.published.media[0].asset
    assert store.verified_local("1")
    store.close()
