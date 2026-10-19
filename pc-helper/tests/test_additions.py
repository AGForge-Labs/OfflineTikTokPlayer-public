import pytest
from offline_tiktok.browser import Collection, CollectionScan, TikTokBrowser
from offline_tiktok.catalog import AssetRef, MediaItem
from offline_tiktok.store import LibraryStore
from test_snapshot import snapshot


def links(*ids):
    return [dict(href=f"https://www.tiktok.com/@fixture_creator_5/video/{key}") for key in ids]


def test_prefix_requires_ordered_known_anchors_and_does_not_use_creation_date():
    scan = CollectionScan()
    scan.add(links("1", "900", "800", "700", "600"))
    proof = scan.additions(["900", "800", "700", "600"])
    assert [item.id for item in proof.items] == ["1"]  # an old post can be a new favorite
    assert proof.anchors == ("900", "800", "700")
    assert proof.known_ids == ("900", "800", "700", "600")


def test_prefix_waits_for_three_anchors_and_rejects_resorted_or_interleaved_rows():
    scan = CollectionScan()
    scan.add(links("new", "a", "b"))  # nonnumeric links are deliberately ignored
    scan.add(links("1", "10", "20"))
    assert scan.additions(["10", "20", "30"]) is None
    scan.add(links("30"))
    assert len(scan.additions(["10", "20", "30"]).items) == 1
    for ids in [("1", "30", "20", "10"), ("1", "10", "2", "20", "30")]:
        broken = CollectionScan()
        broken.add(links(*ids))
        with pytest.raises(ValueError, match="order"):
            broken.additions(["10", "20", "30"])


def test_deleted_leading_source_entries_do_not_delete_the_archive():
    scan = CollectionScan()
    scan.add(links("1", "20", "30", "40"))
    proof = scan.additions(["10", "20", "30", "40"])
    assert proof.anchors == ("20", "30", "40")
    assert [item.id for item in proof.items] == ["1"]


def test_verified_additions_preserve_assets_and_accepted_baseline_on_reinstall(tmp_path):
    store = LibraryStore(tmp_path / "library.sqlite")
    baseline = snapshot()
    store.install_snapshot(baseline)
    ref = AssetRef("drive", "repaired", "song.mp4", 100, "a" * 64, "video/mp4")
    store.save_remote(MediaItem("3", "Archived", asset=ref))
    scan = CollectionScan()
    scan.add(links("4", "3", "1", "2"))
    proof = scan.additions(["3", "1", "2"])
    assert store.merge_additions("music", proof) == ["4"]
    assert store.playlists()[0].item_ids == ["4", "3", "1", "2"]
    store.install_snapshot(baseline)
    assert store.playlists()[0].item_ids == ["4", "3", "1", "2"]
    assert store.item("3").asset == ref
    assert store.snapshot_provenance("music") == baseline.provenance
    with pytest.raises(ValueError, match="changed"):
        store.merge_additions("music", proof)
    store.close()


def test_browser_checks_twice_and_refuses_changing_or_unanchored_pages(tmp_path):
    from types import SimpleNamespace
    class Heading:
        def wait_for(self, **kwargs): pass
        def inner_text(self): return "100 videos"
    class Page:
        visit = -1
        def goto(self, *args, **kwargs): self.visit += 1
        def get_by_role(self, *args, **kwargs): return Heading()
        def wait_for_timeout(self, milliseconds): pass
    browser = TikTokBrowser(tmp_path / "browser")
    browser.page = Page()
    browser.page.mouse = SimpleNamespace(move=lambda *a: None, wheel=lambda *a: None)
    browser.open = lambda: browser
    collection = Collection("123", "Music", "https://www.tiktok.com/@fixture_creator_6/collection/Music-123", 100)
    browser._links = lambda **kw: links("1", "10", "20", "30")
    assert [i.id for i in browser.additions(collection, ["10", "20", "30"]).items] == ["1"]
    browser.page.visit = -1
    browser._links = lambda **kw: links(*(("1", "10", "20", "30") if browser.page.visit == 0 else ("2", "1", "10", "20", "30")))
    with pytest.raises(ValueError, match="changed"):
        browser.additions(collection, ["10", "20", "30"])
    browser._links = lambda **kw: links("9", "8", "7")
    with pytest.raises(ValueError, match="anchor"):
        browser.additions(collection, ["10", "20", "30"])
