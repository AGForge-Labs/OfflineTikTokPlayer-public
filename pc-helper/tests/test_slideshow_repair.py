import copy
from io import BytesIO
import json
from pathlib import Path
from types import SimpleNamespace
import zipfile

from PIL import Image
import pytest

from offline_tiktok.catalog import AssetRef, MediaItem
from offline_tiktok.store import LibraryStore, checksum


def original_zip(path, colors):
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w") as archive:
        for index, color in enumerate(colors):
            image = BytesIO()
            Image.new("RGB", (48, 64), color).save(image, format="PNG")
            archive.writestr(f"image-{index:06}.png", image.getvalue())
    return path


def ref(path, key):
    return AssetRef("drive", key, path.name, path.stat().st_size, checksum(path),
                    "application/zip" if path.suffix == ".zip" else "video/mp4")


class PrivateDrive:
    def __init__(self, raw):
        self.raw = raw
        self.etag = '"e1"'
        self.fail_publish = False
        self.upload_count = 0
        self.puts = 0
        self.fail_readback = False
        self.objects = {}

    def app_folder(self):
        return "drive", "root"

    def folder(self, name, drive, root):
        return "media"

    def upload_file(self, path, name, drive, folder):
        self.upload_count += 1
        asset = ref(path, name)
        self.objects[asset.sha256] = Path(path).read_bytes()
        return asset

    def verify_file(self, asset, path):
        return self.objects[asset.sha256] == Path(path).read_bytes()

    def _request(self, method, path, **kwargs):
        if method == "GET" and path.endswith("/catalog.json"):
            if self.fail_readback and self.puts:
                self.fail_readback = False
                raise RuntimeError("readback interrupted")
            value = {"id": "catalog-id", "eTag": self.etag, "size": len(self.raw),
                     "@microsoft.graph.downloadUrl": "https://example.test/catalog"}
            return SimpleNamespace(status_code=200, json=lambda: value)
        if method == "PUT" and path.endswith("/catalog-id/content"):
            assert kwargs["headers"]["If-Match"] == self.etag
            if self.fail_publish:
                return SimpleNamespace(status_code=412)
            self.puts += 1
            self.raw, self.etag = kwargs["content"], '"e2"'
            return SimpleNamespace(status_code=200)
        raise AssertionError((method, path))

    @property
    def http(self):
        from contextlib import contextmanager
        @contextmanager
        def stream(method, url, **kwargs):
            assert (method, url) == ("GET", "https://example.test/catalog")
            yield SimpleNamespace(status_code=200, iter_bytes=lambda size: iter([self.raw]))
        return SimpleNamespace(stream=stream)


def test_repair_retries_publication_without_reimport_and_preserves_live_metadata(tmp_path):
    from offline_tiktok.slideshow_repair import SlideshowRepair
    from offline_tiktok.media import MediaTools
    store = LibraryStore(tmp_path / "library.sqlite")
    store.update_playlist("p", "Original order", ["2", "1", "3", "4"], complete=True)
    for item_id, colors in (("1", ["red", "blue"]), ("2", ["green"]), ("3", ["red", "blue"]), ("4", ["red"])):
        directory = tmp_path / "media" / item_id
        original = original_zip(directory / "original-photo.zip", colors)
        playback = directory / "legacy.mp4"
        playback.write_bytes(b"old playback " + item_id.encode())
        item = MediaItem(item_id, "Post " + item_id, kind="video" if item_id == "4" else "slideshow",
                         duration=5, asset=ref(playback, "old" + item_id), original=ref(original, "zip" + item_id))
        store.save_local(item, original, playback)
        store.save_remote(item)
        if item_id == "3":
            original.unlink()
    document = json.loads(store.catalog().to_json())
    document["futureLibraryField"] = {"untouched": True}
    document["media"][0]["unknownField"] = ["retain"]
    document["playlists"][0]["ownerAdded"] = 10
    ready = document["media"][1]
    ready["unknownOnRepairedPost"] = 7
    ready["original"]["providerHint"] = "preserve"
    ready["audioLoudness"] = {"version": 1, "assetSHA256": ready["asset"]["sha256"],
                              "integratedLUFS": -17, "truePeakDBTP": -2}
    ready["streamEnhancement"] = {"version": 1, "sourceSHA256": ready["asset"]["sha256"],
                                  "asset": dict(ready["asset"], sha256="a" * 64), "audioMastered": True}
    graph = PrivateDrive(json.dumps(document).encode())
    before = copy.deepcopy(document)
    repair = SlideshowRepair(store, tmp_path, tmp_path / "repair", MediaTools(), graph=graph)
    repair.prepare(workers=1)
    assert {key: x["phase"] for key, x in repair.entries.items()} == {
        "1": "prepared", "2": "single", "3": "missing"}
    previous_asset = store.item("1").asset
    graph.fail_publish = True
    with pytest.raises(ValueError, match="changed"):
        repair.publish()
    assert store.item("1").asset == previous_asset
    assert json.loads(graph.raw) == before
    graph.fail_publish = False
    graph.fail_readback = True
    with pytest.raises(RuntimeError, match="readback"):
        repair.publish()
    assert store.item("1").asset == previous_asset
    repair = SlideshowRepair(store, tmp_path, tmp_path / "repair", MediaTools(), graph=graph)
    repair.publish()
    updated = json.loads(graph.raw)
    assert updated["futureLibraryField"] == before["futureLibraryField"]
    assert updated["playlists"] == before["playlists"]
    old_media = {row["id"]:row for row in before["media"]}
    new_media = {row["id"]:row for row in updated["media"]}
    assert all(old_media[k] == new_media[k] for k in ("2", "3", "4"))
    assert new_media["1"]["original"] == old_media["1"]["original"]
    assert new_media["1"]["unknownOnRepairedPost"] == 7
    assert "audioLoudness" not in new_media["1"] and "streamEnhancement" not in new_media["1"]
    assert abs(new_media["1"]["duration"] - 6.6) < .05
    assert store.item("1").asset.sha256 == new_media["1"]["asset"]["sha256"] != previous_asset.sha256
    assert store.verified_local("1")
    repair.prepare(workers=1)
    repair.publish()
    assert graph.puts == graph.upload_count == 1
    store.close()


def test_archive_rejects_missing_or_duplicate_originals(tmp_path):
    from offline_tiktok.photo import archive_images
    path = original_zip(tmp_path / "photo.zip", ["red"])
    with zipfile.ZipFile(path, "a") as archive:
        archive.writestr("image-000002.png", b"gap")
    with zipfile.ZipFile(path) as archive, pytest.raises(ValueError, match="order"):
        archive_images(archive)
