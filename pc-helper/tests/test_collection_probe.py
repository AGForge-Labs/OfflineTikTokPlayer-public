from offline_tiktok.browser import Collection, post_from_link
from offline_tiktok.cost_audit import AuditLedger
from offline_tiktok.collection_probe import run_probe


def test_failed_collection_proof_keeps_a_partial_audit_without_claiming_completeness(tmp_path):
    ledger = AuditLedger(tmp_path / "membership.json")
    ledger.record(dict(kind="discovery", advertisedCount=1, collections=[dict(
        id="1", name="Music", url="https://www.tiktok.com/@fixture_creator_8/collection/Music-1", count=3)]))

    class PartialBrowser:
        def items(self, collection, observed):
            observed([post_from_link("https://www.tiktok.com/@fixture_creator_5/video/10")], 3, False)
            raise ValueError("Incomplete collection: found 1 of 3 posts")

    result = run_probe(PartialBrowser(), ledger, Collection("1", "Music", "https://www.tiktok.com/@fixture_creator_8/collection/Music-1", 3))
    assert not result["complete"]
    assert result["scannedPosts"] == 1
    assert ledger.data["collections"]["1"]["itemIds"] == ["10"]
    assert not ledger.data["collections"]["1"]["finished"]
    assert "1 of 3" in result["failure"]
