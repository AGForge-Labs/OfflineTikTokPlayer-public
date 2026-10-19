import json
from pathlib import Path
import httpx
import pytest
from offline_tiktok.graph import GraphClient, StorageFull, AuthenticationRequired
from offline_tiktok.store import LibraryStore
from offline_tiktok.catalog import Catalog


def client_for(handler, store, cancelled=lambda: False):
    return GraphClient(lambda: "token", store, http=httpx.Client(transport=httpx.MockTransport(handler)),
                       cancelled=cancelled, sleep=lambda seconds: None)


def test_repair_verifies_server_sha1_when_available(tmp_path):
    import hashlib
    from offline_tiktok.catalog import AssetRef
    from offline_tiktok.store import checksum
    source = tmp_path / "fixed.mp4"
    source.write_bytes(b"repaired soundtrack")
    ref = AssetRef("drive", "fixed", source.name, source.stat().st_size, checksum(source), "video/mp4")
    store = LibraryStore(tmp_path / "db.sqlite")
    def handler(request):
        assert request.url.host == "graph.microsoft.com"
        return httpx.Response(200, json={"id": "fixed", "size": ref.byte_size,
            "file": {"hashes": {"sha1Hash": hashlib.sha1(source.read_bytes()).hexdigest().upper()}}})
    assert client_for(handler, store).verify_file(ref, source)
    store.close()


@pytest.mark.parametrize("content,expected", [(b"repaired soundtrack", True), (b"corrupt! soundtrack", False)])
def test_repair_roundtrip_hashes_bytes_without_sending_token_to_content_host(tmp_path, content, expected):
    from offline_tiktok.catalog import AssetRef
    from offline_tiktok.store import checksum
    source = tmp_path / "fixed.mp4"
    source.write_bytes(b"repaired soundtrack")
    ref = AssetRef("drive", "fixed", source.name, source.stat().st_size, checksum(source), "video/mp4")
    store = LibraryStore(tmp_path / "db.sqlite")
    def handler(request):
        if request.url.host == "graph.microsoft.com":
            return httpx.Response(200, json={"id": "fixed", "size": ref.byte_size,
                "@microsoft.graph.downloadUrl": "https://content.example/fixed", "file": {"hashes": {"quickXorHash": "unused"}}})
        assert "authorization" not in request.headers
        return httpx.Response(200, content=content)
    assert client_for(handler, store).verify_file(ref, source) is expected
    store.close()


def test_deleted_repair_is_not_considered_verified(tmp_path):
    from offline_tiktok.catalog import AssetRef
    from offline_tiktok.store import checksum
    source = tmp_path / "fixed.mp4"
    source.write_bytes(b"repair")
    ref = AssetRef("drive", "fixed", source.name, 6, checksum(source), "video/mp4")
    store = LibraryStore(tmp_path / "db.sqlite")
    assert not client_for(lambda request: httpx.Response(404), store).verify_file(ref, source)
    store.close()


def test_resumes_at_server_offset_without_sending_graph_token_to_upload_host(tmp_path):
    data = tmp_path / "movie.mp4"
    data.write_bytes(b"x" * 700000)
    store = LibraryStore(tmp_path / "db.sqlite")
    from offline_tiktok.store import checksum
    digest = checksum(data)
    store.save_upload(digest, "https://upload.example/session", 0, "2099-01-01T00:00:00Z",
                      target="/drives/drive/items/root:/media/movie.mp4")
    chunks = []
    def handler(request):
        if request.url.host == "upload.example":
            assert "authorization" not in request.headers
            if request.method == "GET":
                return httpx.Response(200, json={"nextExpectedRanges": ["655360-"], "expirationDateTime": "2099-01-01T00:00:00Z"})
            chunks.append((request.headers["content-range"], len(request.content)))
            return httpx.Response(201, json={"id": "asset", "name": "movie.mp4", "size": 700000})
        raise AssertionError("Resume must reuse the upload session")
    ref = client_for(handler, store).upload_file(data, "media/movie.mp4", "drive", "root", force_chunked=True)
    assert chunks == [("bytes 655360-699999/700000", 44640)]
    assert ref.item_id == "asset"
    assert store.upload(digest) is None
    store.close()


def test_quota_failure_does_not_publish_a_catalog(tmp_path):
    source = tmp_path / "movie.mp4"
    source.write_bytes(b"x" * 10)
    store = LibraryStore(tmp_path / "db.sqlite")
    requests = []
    def handler(request):
        requests.append(str(request.url))
        return httpx.Response(507, json={"error": {"code": "quotaLimitReached"}})
    with pytest.raises(StorageFull):
        client_for(handler, store).upload_file(source, "movie.mp4", "drive", "root")
    assert not any("catalog.json" in url for url in requests)
    store.close()


def test_authentication_failure_is_actionable_and_not_retried_forever(tmp_path):
    store = LibraryStore(tmp_path / "db.sqlite")
    calls = []
    def handler(request):
        calls.append(request)
        return httpx.Response(401, json={"error": {"code": "InvalidAuthenticationToken"}})
    with pytest.raises(AuthenticationRequired):
        client_for(handler, store).app_folder()
    assert len(calls) == 1
    store.close()


def test_download_url_is_resolved_fresh_and_range_is_sent_to_content_host(tmp_path):
    store = LibraryStore(tmp_path / "db.sqlite")
    from offline_tiktok.catalog import AssetRef
    ref = AssetRef("drive", "asset", "movie.mp4", 100, "a" * 64, "video/mp4")
    resolves = []
    ranges = []
    def handler(request):
        if request.url.host == "graph.microsoft.com":
            resolves.append(1)
            return httpx.Response(200, json={"@microsoft.graph.downloadUrl": f"https://content.example/{len(resolves)}"})
        assert "authorization" not in request.headers
        ranges.append(request.headers.get("range"))
        return httpx.Response(206, content=b"abcd", headers={"content-range": "bytes 4-7/100"})
    graph = client_for(handler, store)
    assert graph.read_range(ref, 4, 7) == b"abcd"
    assert graph.read_range(ref, 4, 7) == b"abcd"
    assert len(resolves) == 2
    assert ranges == ["bytes=4-7", "bytes=4-7"]
    store.close()


def test_personal_onedrive_download_annotation_survives_metadata_field_filtering(tmp_path):
    store = LibraryStore(tmp_path / "db.sqlite")
    from offline_tiktok.catalog import AssetRef
    ref = AssetRef("drive", "asset", "movie.mp4", 100, "a" * 64, "video/mp4")
    def handler(request):
        if request.url.host == "graph.microsoft.com":
            # This is the actual personal-account response observed in the live proof.
            if "$select" in request.url.params:
                return httpx.Response(200, json={"id": "asset", "@odata.etag": "version"})
            return httpx.Response(200, json={"id": "asset", "@microsoft.graph.downloadUrl": "https://content.example/movie"})
        assert "authorization" not in request.headers
        assert request.headers["range"] == "bytes=4-7"
        return httpx.Response(206, content=b"abcd")
    graph = client_for(handler, store)
    try:
        assert graph.read_range(ref, 4, 7) == b"abcd"
    finally:
        graph.close()
        store.close()


def test_catalog_publication_rejects_ready_item_without_uploaded_asset(tmp_path):
    store = LibraryStore(tmp_path / "db.sqlite")
    from offline_tiktok.catalog import MediaItem
    graph = client_for(lambda request: pytest.fail("Incomplete catalog must not reach OneDrive"), store)
    with pytest.raises(ValueError, match="missing"):
        graph.publish(Catalog("library", [MediaItem("1", "Incomplete")]), "drive", "root")
    store.close()


def test_upload_cancellation_keeps_checkpoint(tmp_path):
    source = tmp_path / "movie.mp4"
    source.write_bytes(b"x" * 700000)
    store = LibraryStore(tmp_path / "db.sqlite")
    uploaded = []
    def handler(request):
        if request.url.host == "graph.microsoft.com":
            return httpx.Response(200, json={"uploadUrl": "https://upload.example/session", "expirationDateTime": "2099-01-01T00:00:00Z"})
        uploaded.append(len(request.content))
        return httpx.Response(202, json={"nextExpectedRanges": ["655360-"]})
    graph = client_for(handler, store, cancelled=lambda: bool(uploaded))
    graph.chunk_size = 655360
    with pytest.raises(InterruptedError):
        graph.upload_file(source, "movie.mp4", "drive", "root", force_chunked=True)
    from offline_tiktok.store import checksum
    assert store.upload(checksum(source))["offset"] == 655360
    store.close()


@pytest.mark.parametrize("drive,root,destination", [
    ("other-drive", "root", "movie.mp4"),
    ("drive", "other-root", "movie.mp4"),
    ("drive", "root", "another.mp4"),
])
def test_interrupted_upload_cannot_resume_into_a_different_destination(tmp_path, drive, root, destination):
    source = tmp_path / "movie.mp4"
    source.write_bytes(b"x" * 700000)
    store = LibraryStore(tmp_path / "db.sqlite")
    first_chunk = []

    def first_handler(request):
        if request.url.host == "graph.microsoft.com":
            return httpx.Response(200, json={"uploadUrl": "https://upload.example/old", "expirationDateTime": "2099-01-01T00:00:00Z"})
        first_chunk.append(True)
        return httpx.Response(202, json={"nextExpectedRanges": ["655360-"]})

    initial = client_for(first_handler, store, cancelled=lambda: bool(first_chunk))
    initial.chunk_size = 655360
    with pytest.raises(InterruptedError):
        initial.upload_file(source, "movie.mp4", "drive", "root", force_chunked=True)
    initial.close()
    store.close()
    store = LibraryStore(tmp_path / "db.sqlite")
    requests = []

    def second_handler(request):
        requests.append(request)
        if str(request.url) == "https://upload.example/old":
            pytest.fail("A prior account or destination's session must never be used")
        if request.url.host == "graph.microsoft.com":
            assert request.method == "POST"
            assert f"/v1.0/drives/{drive}/items/{root}:/{destination}:/createUploadSession" == request.url.path
            return httpx.Response(200, json={"uploadUrl": "https://upload.example/new", "expirationDateTime": "2099-01-01T00:00:00Z"})
        assert request.headers["content-range"] == "bytes 0-699999/700000"
        return httpx.Response(201, json={"id": "new-asset", "name": destination, "size": 700000})

    graph = client_for(second_handler, store)
    ref = graph.upload_file(source, destination, drive, root, force_chunked=True)
    assert ref.drive_id == drive
    assert ref.item_id == "new-asset"
    assert len(requests) == 2
    graph.close()
    store.close()
