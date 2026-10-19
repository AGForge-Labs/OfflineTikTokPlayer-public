from io import BytesIO
import httpx
import pytest
from offline_tiktok.source_session import probe_source


def test_probe_transport_forwards_source_ranges_without_exposing_session_or_source_url():
    calls, lengths = [], set()
    class Reply(BytesIO):
        status = 206
        headers = {"Content-Length":"3", "Content-Range":"bytes 2-4/8", "Content-Type":"video/mp4"}
    class Downloader:
        def urlopen(self, request):
            calls.append((request.url, dict(request.headers)))
            return Reply(b"234")
    source="https://media.example/post.mp4?signed=PRIVATE"
    with probe_source(Downloader(),source,{"X-Session":"PRIVATE"},lengths) as local:
        assert local.startswith("http://127.0.0.1:") and "PRIVATE" not in local
        response=httpx.get(local,headers={"Range":"bytes=2-4"},trust_env=False)
        assert response.status_code==206 and response.content==b"234"
        assert response.headers["Content-Range"]=="bytes 2-4/8"
        assert "X-Session" not in response.headers
        assert httpx.get(local+"-wrong",trust_env=False).status_code==404
    assert len(calls)==1 and calls[0][0]==source
    assert calls[0][1]["Range"]=="bytes=2-4" and calls[0][1]["X-Session"]=="PRIVATE"
    assert lengths=={8}
    with pytest.raises(httpx.TransportError): httpx.get(local,timeout=.2,trust_env=False)


def test_plaintext_source_is_rejected_before_a_forwarder_starts():
    with pytest.raises(ValueError,match="HTTPS"):
        with probe_source(None,"http://media.example/post",{}):
            pytest.fail("Plaintext source must not be forwarded")
