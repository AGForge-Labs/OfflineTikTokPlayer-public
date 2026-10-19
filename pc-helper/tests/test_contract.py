import json
from pathlib import Path
import pytest
from jsonschema import Draft202012Validator
from offline_tiktok.catalog import AssetRef, Catalog, MediaItem, Playlist


def contract():
    path = Path(__file__).resolve().parents[2] / "shared" / "catalog.schema.json"
    schema = json.loads(path.read_text(encoding="utf-8"))
    Draft202012Validator.check_schema(schema)
    return Draft202012Validator(schema)


def wire_catalog():
    media = [MediaItem("video", "Title 🎵", "Creator", asset=AssetRef("drive", "asset", "movie.mp4", 512, "a" * 64, "video/mp4")),
             MediaItem("gone", "Unavailable", status="unavailable"), MediaItem("waiting", "Pending", status="pending")]
    return json.loads(Catalog("library", media, [Playlist("music", "Music", ["video", "gone", "waiting"])]).to_json())


def test_helper_catalog_matches_the_shared_wire_contract():
    contract().validate(wire_catalog())


@pytest.mark.parametrize("change", ["future-schema", "missing-ready-asset", "temporary-url", "fractional-size", "invalid-checksum", "duplicate-membership"])
def test_shared_contract_rejects_unsafe_or_incompatible_catalogs(change):
    data = wire_catalog()
    if change == "future-schema":
        data["schemaVersion"] = 2
    elif change == "missing-ready-asset":
        data["media"][0]["asset"] = None
    elif change == "temporary-url":
        data["media"][0]["asset"]["downloadURL"] = "https://content.example/temporary"
    elif change == "fractional-size":
        data["media"][0]["asset"]["byteSize"] = 0.5
    elif change == "invalid-checksum":
        data["media"][0]["asset"]["sha256"] = "invalid"
    else:
        data["playlists"][0]["itemIds"].append("video")
    assert list(contract().iter_errors(data))
