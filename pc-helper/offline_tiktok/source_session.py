"""Loopback-only byte ranges using the extractor's in-memory source session."""
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import secrets
import threading
from .cost_audit import response_size


@contextmanager
def probe_source(downloader, url, headers, observed_lengths=None):
    if not url.startswith("https://"):
        raise ValueError("Source media requires HTTPS")
    route = "/" + secrets.token_urlsafe(24)
    class Forwarder(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def do_HEAD(self): self.forward("HEAD")
        def do_GET(self): self.forward("GET")
        def forward(self, method):
            if self.path != route:
                self.send_error(404)
                return
            from yt_dlp.networking import Request
            outgoing = dict(headers)
            if self.headers.get("Range"):
                outgoing["Range"] = self.headers["Range"]
            try:
                with downloader.urlopen(Request(url, method=method, headers=outgoing)) as response:
                    content_type = response.headers.get("Content-Type", "").lower()
                    if observed_lengths is not None and not content_type.startswith("text/") and "json" not in content_type:
                        try: observed_lengths.add(response_size(response.status, dict(response.headers)))
                        except ValueError: pass
                    self.send_response(response.status)
                    for name in ("Content-Length", "Content-Range", "Content-Type", "Accept-Ranges"):
                        if response.headers.get(name): self.send_header(name, response.headers[name])
                    self.end_headers()
                    if method != "HEAD":
                        while chunk := response.read(65536): self.wfile.write(chunk)
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                pass
            except Exception:
                try: self.send_error(502)
                except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError): pass
    server = ThreadingHTTPServer(("127.0.0.1", 0), Forwarder)
    thread = threading.Thread(target=lambda:server.serve_forever(poll_interval=.05), daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}{route}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
