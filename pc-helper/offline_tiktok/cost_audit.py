"""Local, read-only cloud-cost audit of DOM-observed collection membership."""
import argparse
from datetime import datetime, timezone
import html
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import math
from pathlib import Path
import re
import secrets
import time
from urllib.parse import parse_qs
from .browser import collection_from_link, post_from_link


def atomic_json(path, data, *, check=lambda:None):
    check()
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    for attempt in range(40):
        check()
        try:
            temporary.replace(path)
            return
        except PermissionError:
            if attempt == 39:
                raise
            # Windows readers and OneDrive can briefly deny replacing an open file.
            time.sleep(0.1)


def storage_cost(gb, rate, *, free_gb=0):
    if any(not math.isfinite(value) or value < 0 for value in (gb, rate, free_gb)):
        raise ValueError("Storage quantities and rates must be finite and nonnegative")
    return max(0, gb - free_gb) * rate


def response_size(status, headers):
    headers = {name.lower(): value for name, value in headers.items()}
    if status == 206:
        match = re.fullmatch(r"bytes \d+-\d+/(\d+)", headers.get("content-range", ""))
        size = int(match[1]) if match else 0
    elif status == 200:
        try:
            size = int(headers.get("content-length", "0"))
        except ValueError:
            size = 0
    else:
        size = 0
    if size <= 0:
        raise ValueError("The media server did not confirm its complete file length")
    return size


class AuditLedger:
    def __init__(self, path):
        self.path = Path(path)
        try:
            self.data = json.loads(self.path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            self.data = {"advertisedCollectionCount": 0, "collections": {}, "media": {}}

    def record(self, snapshot):
        if snapshot["kind"] == "discovery":
            self.data["advertisedCollectionCount"] = int(snapshot["advertisedCount"])
            for value in snapshot["collections"]:
                parsed = collection_from_link(value["url"])
                if not parsed or parsed.id != value["id"]:
                    raise ValueError("Invalid collection identity")
                previous = self.data["collections"].get(parsed.id, {})
                self.data["collections"][parsed.id] = {
                    **previous, "id": parsed.id, "name": str(value["name"]), "url": parsed.url,
                    "advertisedCount": value.get("count"), "itemIds": previous.get("itemIds", []),
                    "finished": previous.get("finished", False)}
        elif snapshot["kind"] == "collection":
            collection = self.data["collections"][snapshot["id"]]
            known = set(collection["itemIds"])
            for link in snapshot["links"]:
                item = post_from_link(link["href"], link.get("label", ""))
                if not item:
                    continue
                if item.id not in known:
                    known.add(item.id)
                    collection["itemIds"].append(item.id)
                self.data["media"].setdefault(item.id, item.wire())
            collection["advertisedCount"] = int(snapshot["advertisedCount"])
            collection["finished"] = bool(snapshot.get("finished", False))
            collection["countMatched"] = len(known) == collection["advertisedCount"]
        else:
            raise ValueError("Unknown audit snapshot")
        self.data["updatedAt"] = datetime.now(timezone.utc).isoformat()
        atomic_json(self.path, self.data)


def serve(path, port):
    ledger = AuditLedger(path)
    token = secrets.token_urlsafe(32)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            if self.path != "/":
                self.send_error(404)
                return
            rows = "".join(f"<tr><td>{html.escape(value['name'])}</td><td>{len(value['itemIds'])} / {value.get('advertisedCount')}</td><td>{'Reached end' if value['finished'] else 'Reading'}</td></tr>"
                           for value in ledger.data["collections"].values())
            document = f"""<!doctype html><html><head><meta charset="utf-8"><title>Local TikTok storage audit</title>
            <style>body{{font:16px system-ui;max-width:1100px;margin:35px auto;padding:20px;background:#141414;color:#eee}}textarea{{width:100%;height:150px}}td,th{{padding:8px;text-align:left}}button{{padding:10px;margin:8px 0}}</style></head>
            <body><h1>Local TikTok storage audit</h1><p>{len(ledger.data['collections'])} / {ledger.data['advertisedCollectionCount']} collections observed; {len(ledger.data['media'])} unique posts recorded.</p>
            <form action="/record" method="post"><label for="snapshot-data">Collection snapshot</label><textarea id="snapshot-data" name="snapshot" required></textarea>
            <input type="hidden" name="token" value="{token}"><button type="submit">Save snapshot</button></form>
            <table><tr><th>Collection</th><th>Observed / advertised posts</th><th>Scan</th></tr>{rows}</table></body></html>""".encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(document)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'")
            self.end_headers()
            self.wfile.write(document)

        def do_POST(self):
            origin = f"http://127.0.0.1:{self.server.server_port}"
            if self.path != "/record" or self.headers.get("Host") != f"127.0.0.1:{self.server.server_port}" or self.headers.get("Origin") != origin:
                self.send_error(403)
                return
            size = int(self.headers.get("Content-Length", "0"))
            if size <= 0 or size > 2 * 1024 * 1024:
                self.send_error(413)
                return
            try:
                values = parse_qs(self.rfile.read(size).decode("utf-8"))
                if not secrets.compare_digest(values.get("token", [""])[0], token):
                    self.send_error(403)
                    return
                ledger.record(json.loads(values["snapshot"][0]))
            except (ValueError, KeyError, TypeError):
                self.send_error(400)
                return
            self.send_response(303)
            self.send_header("Location", "/")
            self.send_header("Content-Length", "0")
            self.end_headers()

    server = HTTPServer(("127.0.0.1", port), Handler)
    print(f"Local audit recorder: http://127.0.0.1:{server.server_port}/", flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()


def main():
    from .gui import data_directory
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--record", type=Path, default=data_directory() / "cost-audit" / "membership.json")
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    serve(args.record, args.port)


if __name__ == "__main__":
    main()
