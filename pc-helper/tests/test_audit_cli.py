import json
import sys
import pytest
from offline_tiktok import size_probe


@pytest.mark.parametrize("expected,finished,exit_code", [(2, False, 1), (1, True, 0)])
def test_audit_exit_status_requires_complete_membership(tmp_path, monkeypatch, expected, finished, exit_code):
    membership = tmp_path / "membership.json"
    output = tmp_path / "cost.json"
    item = dict(id="1", title="Test clip", creator="creator", sourceURL="https://www.tiktok.com/@fixture_creator_5/video/1",
                kind="video", status="pending")
    membership.write_text(json.dumps(dict(advertisedCollectionCount=1, media={"1": item}, collections={
        "music": dict(id="music", name="Music", advertisedCount=expected, itemIds=["1"], finished=finished),
    })), encoding="utf-8")
    monkeypatch.setattr(sys, "argv", ["size-probe", "--membership", str(membership), "--output", str(output),
                                    "--cache", str(tmp_path / "cache"), "--workers", "1", "--playlist-id", "music"])
    monkeypatch.setattr(size_probe, "data_directory", lambda: tmp_path)
    monkeypatch.setattr(size_probe, "measure_item", lambda *args: dict(id="1", status="measured", cloudBytes=100, playbackBytes=100))
    assert size_probe.main() == exit_code
    assert json.loads(output.read_text(encoding="utf-8"))["complete"] == (exit_code == 0)


def test_resuming_audit_remeasures_legacy_aggregate_entries(tmp_path, monkeypatch):
    membership, output = tmp_path / "membership.json", tmp_path / "cost.json"
    item = dict(id="1", title="Photo render", sourceURL="https://www.tiktok.com/@fixture_creator_5/video/1", status="pending")
    membership.write_text(json.dumps(dict(advertisedCollectionCount=1, media={"1": item}, collections={
        "music": dict(id="music", name="Music", advertisedCount=1, itemIds=["1"], finished=True)})))
    output.write_text(json.dumps(dict(media={"1": dict(id="1", status="measured", cloudBytes=100, playbackBytes=100)})))
    monkeypatch.setattr(sys, "argv", ["size-probe", "--membership", str(membership), "--output", str(output),
                                    "--cache", str(tmp_path / "cache"), "--workers", "1"])
    monkeypatch.setattr(size_probe, "data_directory", lambda: tmp_path)
    monkeypatch.setattr(size_probe, "measure_item", lambda *args: dict(id="1", status="measured", compatibilityVersion=2,
                                                                    cloudBytes=350, playbackBytes=250))
    assert size_probe.main() == 0
    result = json.loads(output.read_text())
    assert result["cloudBytes"] == 350
    assert result["media"]["1"]["compatibilityVersion"] == 2
