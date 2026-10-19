import pytest
from offline_tiktok.browser import Collection, CollectionScan
from offline_tiktok.store import LibraryStore
from offline_tiktok.pipeline import ImportPipeline
from test_pipeline import Cloud, Downloader


class Browser:
    ids = ["4", "3", "2", "1"]
    calls = 0
    fail = False
    def additions(self, collection, known_ids):
        self.calls += 1
        if self.fail: raise RuntimeError("Sign in to TikTok")
        scan = CollectionScan()
        scan.add([dict(href=f"https://www.tiktok.com/@fixture_creator_1/video/{key}") for key in self.ids])
        return scan.additions(known_ids)
    def cookies(self): return []


def watcher(tmp_path, *, cloud=None, download=None):
    from offline_tiktok.watch import PlaylistWatcher
    store = LibraryStore(tmp_path / "db.sqlite")
    store.update_playlist("p", "Music", ["3", "2", "1"], complete=True)
    browser = Browser()
    cloud = cloud or Cloud()
    download = download or Downloader(tmp_path)
    pipeline = ImportPipeline(store, browser, download, cloud)
    clock = [100.0]
    watch = PlaylistWatcher(store, pipeline, clock=lambda: clock[0])
    watch.configure([Collection("p", "Music", "https://www.tiktok.com/@fixture_creator_6/collection/Music-123", 4)])
    return watch, store, browser, download, cloud, clock


def test_fifteen_minute_checks_persist_skip_unchanged_and_catch_up_after_sleep(tmp_path):
    from offline_tiktok.watch import PlaylistWatcher
    watch, store, browser, download, cloud, clock = watcher(tmp_path)
    assert watch.due
    assert watch.check() == 1
    assert store.playlists()[0].item_ids == ["4", "3", "2", "1"]
    assert watch.state["lastSuccess"] == 100
    assert watch.state["nextCheck"] == 1000
    first = cloud.published
    cloud.published = None
    assert watch.check() is None
    assert browser.calls == 1
    clock[0] = 1000
    assert watch.check() == 0
    assert cloud.published is None
    assert first is not None and download.count == 4  # initial pending baseline is resumed too
    restarted = PlaylistWatcher(store, watch.pipeline, clock=lambda: 10000)
    assert restarted.due
    restarted.pause()
    assert not PlaylistWatcher(store, watch.pipeline, clock=lambda: 10001).due
    store.close()


def test_failed_upload_retries_checkpoint_even_when_new_prefix_is_now_known(tmp_path):
    cloud = Cloud(fail_on=0)
    watch, store, browser, download, _, clock = watcher(tmp_path, cloud=cloud)
    assert watch.check() is None
    assert watch.state["dirty"] and "interrupted" in watch.state["lastError"]
    assert cloud.published is None
    cloud.fail_on = None
    clock[0] = watch.state["nextCheck"]
    assert watch.check() == 0
    assert download.count == 4  # no completed media is downloaded again
    assert cloud.published is not None and not watch.state["dirty"]
    store.close()


def test_source_failure_backoff_and_pause_never_changes_membership(tmp_path):
    watch, store, browser, download, cloud, clock = watcher(tmp_path)
    browser.fail = True
    for failure in range(1, 6):
        assert watch.check() is None
        assert watch.state["failures"] == failure
        assert 900 <= watch.state["nextCheck"] - clock[0] <= 3600
        clock[0] = watch.state["nextCheck"]
    assert store.playlists()[0].item_ids == ["3", "2", "1"]
    assert download.count == 0 and cloud.published is None
    watch.pause()
    assert watch.check(force=True) is None
    store.close()


@pytest.mark.parametrize("stopping", [True, False])
def test_shutdown_cancellation_preserves_resume_but_explicit_pause_stays_paused(tmp_path, stopping):
    from offline_tiktok.watch import PlaylistWatcher
    watch, store, browser, download, cloud, clock = watcher(tmp_path)
    watch.stopping = lambda: stopping
    def interrupted(*args): raise InterruptedError("cancelled")
    browser.additions = interrupted
    assert watch.check() is None
    restored = PlaylistWatcher(store, watch.pipeline, clock=lambda: clock[0])
    assert restored.state["enabled"] is stopping
    assert restored.due is stopping
    assert store.playlists()[0].item_ids == ["3", "2", "1"]
    store.close()


def test_transient_media_failure_stays_pending_and_retries_without_losing_other_additions(tmp_path):
    class InterruptedDownloader(Downloader):
        fail = True
        def acquire(self, item, cookies):
            if item.id == "4" and self.fail: raise RuntimeError("temporary network failure")
            return super().acquire(item, cookies)
    download = InterruptedDownloader(tmp_path)
    watch, store, browser, _, cloud, clock = watcher(tmp_path, download=download)
    assert watch.check() == 1
    assert store.item("4").status == "pending"
    assert "temporary" in store.failure("4")
    assert cloud.published is not None
    cloud.published = None
    clock[0] = watch.state["nextCheck"]
    assert watch.check() == 0
    assert cloud.published is None  # retrying a still-missing source changes no catalog content
    download.fail = False
    clock[0] = watch.state["nextCheck"]
    assert watch.check() == 0
    assert store.item("4").asset is not None
    assert download.count == 4
    store.close()
