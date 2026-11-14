import json
from httpx import Client, MockTransport, Response

from offline_tiktok.catalog import AssetRef, AudioLoudness, Catalog, MediaItem, StreamEnhancement
from offline_tiktok.graph import GraphClient
from offline_tiktok.quality_backfill import INDEX_NAME, _document, _publish, _read_index, pending_items


def asset(digit):
    return AssetRef("drive", digit, digit + ".mp4", 1000, digit * 64, "video/mp4")


def item(name, digest, level=None):
    ref = asset(digest)
    return MediaItem(name, name, asset=ref, original=ref,
                     audio_loudness=AudioLoudness(ref.sha256, level, -5) if level is not None else None)


def test_backfill_prioritizes_quiet_posts_and_does_not_skip_replaced_assets():
    typical = item("typical", "b", -12)
    quiet = item("quiet", "c", -45)
    unseen = item("new", "d")
    stale = item("stale", "e", -13)
    live = item("live", "a", -17)
    catalog = Catalog("library", [typical, quiet, unseen, stale, live])
    variants = {"stale": StreamEnhancement("a" * 64, asset("f"), True),
                "live": StreamEnhancement("a" * 64, asset("f"), True)}
    assert [m.id for m in pending_items(catalog, variants, {}, 100)] == ["quiet", "new", "stale", "typical"]
    assert pending_items(catalog, variants, {}, 100, added_ids={"new"})[0].id == "new"
    waiting = {"quiet": {"source": quiet.asset.sha256, "phase": "retry", "retryAfter": 101},
               "stale": {"source": "a" * 64, "phase": "unchanged"}}
    assert [m.id for m in pending_items(catalog, variants, waiting, 100)] == ["new", "stale", "typical"]
    assert pending_items(catalog, variants, waiting, 101)[0].id == "quiet"


def test_quality_publication_never_touches_import_catalog_and_reads_back_exact_bytes():
    files = {"catalog.json": b"importer-owned bytes"}

    def response(request):
        if request.url.host == "cdn.invalid":
            assert "Authorization" not in request.headers
            return Response(200, content=files[request.url.path[1:]])
        assert request.headers["Authorization"] == "Bearer synthetic"
        name = request.url.path.split(":/")[1]
        assert name == INDEX_NAME, "The importer keeps exclusive ownership of catalog.json"
        if request.method == "PUT":
            files[name] = request.content
        if name not in files:
            return Response(404)
        return Response(200, json={"size": len(files[name]), "@microsoft.graph.downloadUrl": "https://cdn.invalid/" + name})

    with Client(transport=MockTransport(response)) as http:
        graph = GraphClient(lambda: "synthetic", None, http=http)
        assert _document(graph, "drive", "root", INDEX_NAME, missing=True) is None
        variants = {"clip": StreamEnhancement("a" * 64, asset("b"), True)}
        _publish(graph, "drive", "root", "library", variants)
        assert _read_index(files[INDEX_NAME], "library") == variants
        assert json.loads(files[INDEX_NAME])["version"] == 1
        assert files["catalog.json"] == b"importer-owned bytes"
