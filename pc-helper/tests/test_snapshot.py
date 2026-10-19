import hashlib
import json
import pytest
from offline_tiktok.browser import Collection
from offline_tiktok.catalog import MediaItem
from offline_tiktok.store import LibraryStore


def checkpoint():
    return {
        "collections": {"music": {"id": "music", "name": "Music", "url": "https://www.tiktok.com/@fixture_creator_6/collection/Music-music",
                                   "advertisedCount": 5, "itemIds": ["3", "1", "2"], "finished": False},
                        "other": {"id": "other", "name": "Other", "advertisedCount": 1, "itemIds": ["9"]}},
        "media": {i: MediaItem(i, f"Post {i}", source_url=f"https://www.tiktok.com/@fixture_creator_5/video/{i}", status="pending").wire()
                  for i in ["1", "2", "3", "9"]},
    }


def snapshot(data=None):
    from offline_tiktok.snapshot import AcceptedSnapshot
    return AcceptedSnapshot.from_checkpoint(data or checkpoint(), "music", expected_observed=3, expected_source=5,
                                           accepted_at="2026-10-14", reason="User accepted these identified posts",
                                           measurements={"media": {"2": {"status": "unmeasured", "reason": "Source has no video"}}})


def test_accepted_snapshot_is_an_explicit_store_operation(tmp_path):
    store = LibraryStore(tmp_path / "library.sqlite")
    assert callable(getattr(store, "install_snapshot", None)), "Explicit accepted-snapshot installation is missing"
    store.close()


def test_snapshot_retains_only_selected_order_and_unavailable_identity(tmp_path):
    accepted = snapshot()
    store = LibraryStore(tmp_path / "library.sqlite")
    store.install_snapshot(accepted)
    assert store.playlists()[0].item_ids == ["3", "1", "2"]
    assert store.item("9") is None
    assert store.item("2").status == "unavailable"
    assert store.item("3").status == "pending"
    provenance = store.snapshot_provenance("music")
    assert provenance["sourceAdvertisedCount"] == 5
    assert provenance["excludedUnobservedCount"] == 2
    assert provenance["acceptedAt"] == "2026-10-14"
    assert provenance["membershipSHA256"] == accepted.membership_sha256
    store.catalog().validate()
    store.close()


def test_snapshot_cannot_silently_shrink_a_previously_imported_playlist(tmp_path):
    store = LibraryStore(tmp_path / "library.sqlite")
    store.update_playlist("music", "Earlier complete list", ["3", "1", "2", "4", "5"], complete=True)
    with pytest.raises(ValueError, match="existing membership"):
        store.install_snapshot(snapshot())
    assert store.playlists()[0].item_ids == ["3", "1", "2", "4", "5"]
    assert store.snapshot_provenance("music") is None
    store.close()


@pytest.mark.parametrize("mutation", ["count", "source", "duplicate", "missing"])
def test_snapshot_requires_the_exact_reviewed_membership(mutation):
    data = checkpoint()
    if mutation == "count": data["collections"]["music"]["itemIds"].pop()
    if mutation == "source": data["collections"]["music"]["advertisedCount"] = 6
    if mutation == "duplicate": data["collections"]["music"]["itemIds"][2] = "1"
    if mutation == "missing": del data["media"]["1"]
    with pytest.raises(ValueError):
        snapshot(data)


def test_snapshot_file_is_digest_checked_and_idempotent(tmp_path):
    from offline_tiktok.snapshot import AcceptedSnapshot
    accepted = snapshot()
    path = tmp_path / "accepted.json"
    accepted.write(path)
    restored = AcceptedSnapshot.read(path)
    store = LibraryStore(tmp_path / "library.sqlite")
    store.install_snapshot(restored)
    store.install_snapshot(restored)
    assert len(store.playlists()) == 1
    wire = json.loads(path.read_text(encoding="utf-8"))
    wire["media"].reverse()
    path.write_text(json.dumps(wire), encoding="utf-8")
    with pytest.raises(ValueError, match="digest"):
        AcceptedSnapshot.read(path)
    store.close()


def test_snapshot_preparation_uses_no_scan_and_skips_known_unavailable(tmp_path):
    from offline_tiktok.pipeline import ImportPipeline
    from offline_tiktok.media import Acquisition

    class Browser:
        def items(self, collection): raise AssertionError("Do not rescan an accepted snapshot")
        def cookies(self): return []

    seen = []
    class Downloader:
        def acquire(self, item, cookies):
            seen.append(item.id)
            p = tmp_path / f"{item.id}.mp4"
            p.write_bytes(b"completed local media")
            return Acquisition(p, p, None, 12)

    store = LibraryStore(tmp_path / "library.sqlite")
    pipeline = ImportPipeline(store, Browser(), Downloader())
    pipeline.prepare_snapshot(snapshot())
    pipeline.prepare_snapshot(snapshot())
    assert seen == ["3", "1"]
    assert store.item("2").status == "unavailable"
    assert store.verified_local("3")
    assert store.playlists()[0].item_ids == ["3", "1", "2"]
    store.close()
