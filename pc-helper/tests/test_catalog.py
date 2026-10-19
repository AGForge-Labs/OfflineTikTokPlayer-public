import json
import pytest

from offline_tiktok.catalog import AssetRef, Catalog, MediaItem, Playlist


def asset():
    return AssetRef("drive", "item", "movie.mp4", 100, "a" * 64, "video/mp4")


def test_combined_playlist_deduplicates_in_first_seen_order():
    catalog = Catalog("library", [MediaItem("1", "First", asset=asset()), MediaItem("2", "Second", asset=asset())],
                      [Playlist("a", "A", ["2", "1"]), Playlist("b", "B", ["1"])])
    assert catalog.queue(["a", "b"]) == ["2", "1"]


def test_catalog_round_trips_asset_identity_without_temporary_urls():
    original = Catalog("library", [MediaItem("1", "Title", creator="Creator", asset=asset())], [Playlist("a", "List", ["1"])])
    data = json.loads(original.to_json())
    assert data["schemaVersion"] == 1
    assert data["media"][0]["asset"]["itemId"] == "item"
    assert Catalog.from_json(original.to_json()).queue(["a"]) == ["1"]


def test_rejects_dangling_membership_and_invalid_checksum():
    with pytest.raises(ValueError, match="missing"):
        Catalog("library", [], [Playlist("a", "A", ["missing"])]).validate()
    with pytest.raises(ValueError, match="checksum"):
        AssetRef("d", "i", "a.mp4", 12, "not-a-checksum", "video/mp4").validate()


def test_unavailable_media_stays_visible_but_is_not_playable():
    catalog = Catalog("library", [MediaItem("1", "Gone", status="unavailable")], [Playlist("a", "A", ["1"])])
    catalog.validate()
    assert catalog.queue(["a"]) == []


def test_large_catalog_does_not_duplicate_playlist_items():
    media = [MediaItem(str(i), str(i), asset=asset()) for i in range(6212)]
    playlists = [Playlist("music", "Music", [str(i) for i in range(2753)]), Playlist("all", "All", [str(i) for i in range(6212)])]
    assert len(Catalog("library", media, playlists).queue(["music", "all"])) == 6212


def test_future_catalog_schema_is_rejected():
    with pytest.raises(ValueError, match="schema"):
        Catalog.from_json('{"schemaVersion":2,"libraryId":"x","media":[],"playlists":[]}')
