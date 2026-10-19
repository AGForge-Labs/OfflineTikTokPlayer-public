from types import SimpleNamespace
import pytest
from offline_tiktok.size_probe import BoundedTools


def test_failed_probe_keeps_useful_errors_without_exposing_source_urls(monkeypatch):
    monkeypatch.setattr("offline_tiktok.size_probe.subprocess.run", lambda *args, **kwargs: SimpleNamespace(
        returncode=1, stdout=b"", stderr=b"https://media.example/v.mp4?token=SECRET: Server returned 403 Forbidden"))
    with pytest.raises(RuntimeError) as caught:
        BoundedTools()._run(["ffmpeg", "-i", "http://127.0.0.1:123/source"])
    assert "403 Forbidden" in str(caught.value)
    assert "SECRET" not in str(caught.value)
