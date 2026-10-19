from pathlib import Path
import pytest
from offline_tiktok.browser import Collection
from offline_tiktok.catalog import AssetRef, MediaItem
from offline_tiktok.media import Acquisition
from offline_tiktok.store import LibraryStore, checksum
from offline_tiktok.pipeline import ImportPipeline


class Browser:
    def items(self, collection):
        return [MediaItem("1", "First", status="pending"), MediaItem("2", "Second", status="pending")]

    def cookies(self):
        return []


class Downloader:
    def __init__(self, root):
        self.root = root
        self.count = 0

    def acquire(self, item, cookies):
        self.count += 1
        path = self.root / (item.id + ".mp4")
        path.write_bytes((item.id + " original video").encode())
        return Acquisition(path, path, path, 3)


class Cloud:
    def __init__(self, fail_on=None):
        self.fail_on = fail_on
        self.assets = []
        self.published = None

    def app_folder(self):
        return "drive", "root"

    def quota(self):
        return {"remaining": 1000000}

    def folder(self, name, drive_id, root):
        return name

    def upload_file(self, source, destination, drive_id, root):
        if len(self.assets) == self.fail_on:
            raise RuntimeError("transfer interrupted")
        self.assets.append(Path(source).read_bytes())
        return AssetRef("drive", str(len(self.assets)), destination, Path(source).stat().st_size, checksum(source), "video/mp4")

    def publish(self, catalog, drive_id, root):
        catalog.validate()
        self.published = catalog.to_json()
        return "catalog"


def test_shared_items_download_once_and_cloud_catalog_contains_only_complete_assets(tmp_path):
    store = LibraryStore(tmp_path / "db.sqlite")
    download = Downloader(tmp_path)
    cloud = Cloud()
    pipeline = ImportPipeline(store, Browser(), download, cloud)
    selected = [Collection("a", "Music", "url"), Collection("b", "Second list", "url")]
    pipeline.prepare(selected)
    assert download.count == 2
    pipeline.sync(["a", "b"])
    assert cloud.published is not None
    assert store.catalog().queue(["a", "b"]) == ["1", "2"]
    store.close()


def test_interrupted_upload_never_publishes_replacement_catalog(tmp_path):
    store = LibraryStore(tmp_path / "db.sqlite")
    cloud = Cloud(fail_on=1)
    pipeline = ImportPipeline(store, Browser(), Downloader(tmp_path), cloud)
    pipeline.prepare([Collection("a", "Music", "url")])
    with pytest.raises(RuntimeError, match="interrupted"):
        pipeline.sync(["a"])
    assert cloud.published is None
    assert store.verified_local("1")
    assert store.verified_local("2")
    store.close()


def test_already_archived_post_survives_source_unavailability(tmp_path):
    store = LibraryStore(tmp_path / "db.sqlite")
    ref = AssetRef("drive", "asset", "video.mp4", 100, "a" * 64, "video/mp4")
    store.save_remote(MediaItem("1", "Archived", asset=ref))
    download = Downloader(tmp_path)
    ImportPipeline(store, Browser(), download).prepare([Collection("a", "Renamed", "url")])
    assert download.count == 1
    assert store.item("1").asset.item_id == "asset"
    assert store.playlists()[0].name == "Renamed"
    store.close()


def test_parallel_downloads_keep_playlist_order_and_database_on_owner_thread(tmp_path):
    import threading
    barrier = threading.Barrier(2)
    threads = set()
    lock = threading.Lock()
    class ParallelDownloader(Downloader):
        def acquire(self, item, cookies):
            with lock: threads.add(threading.get_ident())
            barrier.wait(timeout=5)
            return super().acquire(item, cookies)
    store = LibraryStore(tmp_path / "db.sqlite")
    ImportPipeline(store, Browser(), ParallelDownloader(tmp_path), workers=2).prepare([Collection("a", "Music", "url")])
    assert len(threads) == 2
    assert store.playlists()[0].item_ids == ["1", "2"]
    assert store.verified_local("1") and store.verified_local("2")
    store.close()


def test_parallel_pause_cancels_active_work_without_marking_posts_unavailable(tmp_path):
    import threading
    stop = threading.Event()
    class PausingDownloader:
        def acquire(self, item, cookies):
            if item.id == "1": raise InterruptedError("storage pause")
            stop.wait(timeout=5)
            raise InterruptedError("cancelled")
    store = LibraryStore(tmp_path / "db.sqlite")
    pipeline = ImportPipeline(store, Browser(), PausingDownloader(), workers=2, cancel_work=stop.set)
    with pytest.raises(InterruptedError): pipeline.prepare([Collection("a", "Music", "url")])
    assert stop.is_set()
    assert all(item.status == "pending" for item in store.catalog().media)
    store.close()
