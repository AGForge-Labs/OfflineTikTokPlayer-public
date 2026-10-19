import pytest
from offline_tiktok.cost_audit import AuditLedger, storage_cost, response_size


def test_collection_snapshots_preserve_playlists_and_deduplicate_shared_posts(tmp_path):
    ledger = AuditLedger(tmp_path / "audit.json")
    ledger.record({"kind": "discovery", "advertisedCount": 2, "collections": [
        {"id": "10", "name": "Music", "url": "https://www.tiktok.com/@fixture_creator_8/collection/Music-10", "count": 2},
        {"id": "20", "name": "Second", "url": "https://www.tiktok.com/@fixture_creator_8/collection/Second-20", "count": 1}]})
    ledger.record({"kind": "collection", "id": "10", "advertisedCount": 2, "links": [
        {"href": "https://www.tiktok.com/@fixture_creator_1/video/100", "label": "First"}]})
    ledger.record({"kind": "collection", "id": "10", "advertisedCount": 2, "finished": True, "links": [
        {"href": "https://www.tiktok.com/@fixture_creator_1/video/100", "label": "First"},
        {"href": "https://www.tiktok.com/@fixture_creator_2/photo/200", "label": "Second"}]})
    ledger.record({"kind": "collection", "id": "20", "advertisedCount": 1, "finished": True, "links": [
        {"href": "https://www.tiktok.com/@fixture_creator_1/video/100", "label": "First"}]})
    recovered = AuditLedger(tmp_path / "audit.json").data
    assert list(recovered["media"]) == ["100", "200"]
    assert recovered["collections"]["10"]["itemIds"] == ["100", "200"]
    assert recovered["collections"]["20"]["itemIds"] == ["100"]
    assert recovered["collections"]["10"]["finished"]


def test_advertised_missing_members_remain_visible_in_the_audit(tmp_path):
    ledger = AuditLedger(tmp_path / "audit.json")
    ledger.record({"kind": "discovery", "advertisedCount": 2, "collections": [
        {"id": "10", "name": "Music", "url": "https://www.tiktok.com/@fixture_creator_8/collection/Music-10", "count": 3}]})
    ledger.record({"kind": "collection", "id": "10", "advertisedCount": 3, "finished": True, "links": [
        {"href": "https://www.tiktok.com/@fixture_creator_1/video/100", "label": "First"}]})
    assert ledger.data["advertisedCollectionCount"] == 2
    assert len(ledger.data["collections"]) == 1
    assert ledger.data["collections"]["10"]["advertisedCount"] == 3
    assert len(ledger.data["collections"]["10"]["itemIds"]) == 1


def test_media_length_uses_the_full_range_total_and_rejects_error_page_sizes():
    assert response_size(206, {"content-range": "bytes 0-0/123456", "content-length": "1"}) == 123456
    assert response_size(200, {"content-length": "123456"}) == 123456
    with pytest.raises(ValueError):
        response_size(403, {"content-length": "128"})
    with pytest.raises(ValueError):
        response_size(206, {"content-range": "bytes 0-0/*", "content-length": "1"})


def test_storage_allowance_is_monthly_capacity_not_an_egress_allowance():
    rate = 0.0184
    assert storage_cost(100, rate, free_gb=5) == pytest.approx(1.748)
    assert storage_cost(100, rate, free_gb=0) == pytest.approx(1.84)
    assert storage_cost(4, rate, free_gb=5) == 0
