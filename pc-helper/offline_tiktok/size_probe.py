"""Measure actual best-quality assets; no Azure resources or cloud uploads."""
import argparse
from concurrent.futures import ThreadPoolExecutor, wait, FIRST_COMPLETED
from contextlib import contextmanager
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from http.cookiejar import Cookie
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import threading
import time
from .catalog import MediaItem
from .cost_audit import atomic_json, response_size, storage_cost
from .gui import data_directory
from .media import MediaDownloader, MediaTools, _QuietLogger


LOCAL_CONVERSIONS = threading.BoundedSemaphore(2)


class BoundedTools(MediaTools):
    def _run(self, args):
        args = list(args)
        # Remote probes/thumbnails must not remain stuck on a dead CDN connection.
        remote = any(str(value).startswith(("https://", "http://127.0.0.1:")) for value in args)
        if remote:
            args[1:1] = ["-rw_timeout", "10000000"]
        result = subprocess.run(args, capture_output=True, timeout=45 if remote else 3600,
                                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        if result.returncode:
            message = re.sub(r"https?://\S+", "[source URL]", result.stderr.decode("utf-8", "replace"))[-1200:].strip()
            raise RuntimeError("Media probe or conversion failed" + (": " + message if message else ""))
        return result.stdout


class MediaSizer:
    def __init__(self, cache, *, extract=None, size=None, probe=None, acquire=None, artwork=False, cookies=()):
        self.cache = Path(cache)
        self.tools = BoundedTools()
        self.extract = extract or self._extract
        self.size = size or self._size
        self.probe = probe or self.tools.probe
        self.cookies = cookies
        self.acquire = acquire or (lambda item: MediaDownloader(self.cache, tools=self.tools).acquire(item, self.cookies))
        self.artwork = artwork
        self.downloader = None
        self.source_headers = {}
        self.observed_lengths = set()

    def _extract(self, item):
        from yt_dlp import YoutubeDL
        self.downloader = YoutubeDL(dict(format="bestvideo+bestaudio/best", quiet=True, no_warnings=True,
                                        logger=_QuietLogger(), noplaylist=True, socket_timeout=20,
                                        retries=2, extractor_retries=1))
        for value in self.cookies:
            if value["domain"].lstrip(".") not in ("tiktok.com", "www.tiktok.com"):
                continue
            self.downloader.cookiejar.set_cookie(Cookie(0, value["name"], value["value"], None, False,
                value["domain"], True, value["domain"].startswith("."), value["path"], True,
                value.get("secure", False), int(value["expires"]) if value.get("expires", -1) > 0 else None,
                True, None, None, {"HttpOnly": value.get("httpOnly", False)}, False))
        info = self.downloader.extract_info(item.source_url, download=False)
        self.source_headers = info.get("http_headers", {})
        return info

    def _size(self, url):
        if not url.startswith("https://"):
            raise ValueError("Media lengths require HTTPS")
        from yt_dlp.networking import Request
        for method in ("HEAD", "GET"):
            headers = dict(self.source_headers)
            if method == "GET":
                headers["Range"] = "bytes=0-0"
            try:
                with self.downloader.urlopen(Request(url, method=method, headers=headers)) as response:
                    return response_size(response.status, dict(response.headers))
            except Exception:
                if method == "GET":
                    raise
        raise ValueError("No confirmed media length")

    @contextmanager
    def _probe_url(self, url):
        if not self.downloader:
            yield url
            return
        downloader, headers = self.downloader, dict(self.source_headers)
        observed_lengths = self.observed_lengths
        observed_lengths.clear()
        route = "/" + secrets.token_urlsafe(24)

        class Forwarder(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_HEAD(self):
                self.forward("HEAD")

            def do_GET(self):
                self.forward("GET")

            def forward(self, method):
                if self.path != route:
                    self.send_error(404)
                    return
                from yt_dlp.networking import Request
                request_headers = dict(headers)
                if self.headers.get("Range"):
                    request_headers["Range"] = self.headers["Range"]
                try:
                    with downloader.urlopen(Request(url, method=method, headers=request_headers)) as response:
                        content_type = response.headers.get("Content-Type", "").lower()
                        if not content_type.startswith("text/") and "json" not in content_type:
                            try:
                                observed_lengths.add(response_size(response.status, dict(response.headers)))
                            except ValueError:
                                pass
                        self.send_response(response.status)
                        for name in ("Content-Length", "Content-Range", "Content-Type", "Accept-Ranges"):
                            if response.headers.get(name):
                                self.send_header(name, response.headers[name])
                        self.end_headers()
                        if method != "HEAD":
                            while chunk := response.read(65536):
                                self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                    pass
                except Exception:
                    try:
                        self.send_error(502)
                    except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                        pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Forwarder)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            # FFprobe uses the extractor's session through this loopback-only
            # byte-range bridge, without exporting cookies or CDN capability URLs.
            yield f"http://127.0.0.1:{server.server_port}{route}"
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def _acquired(self, item):
        with LOCAL_CONVERSIONS:
            return self._acquired_with_capacity(item)

    def _acquired_with_capacity(self, item):
        self.cache.mkdir(parents=True, exist_ok=True)
        if shutil.disk_usage(self.cache).free < 1024 ** 3:
            raise OSError("Local measurement cache has less than 1 GiB free")
        acquired = self.acquire(item)
        original = acquired.original.stat().st_size
        playback = acquired.playback.stat().st_size
        art = acquired.artwork.stat().st_size if acquired.artwork.exists() else 0
        cloud = original + (playback if acquired.original.resolve() != acquired.playback.resolve() else 0) + art
        return dict(originalBytes=original, playbackBytes=playback, artworkBytes=art, cloudBytes=cloud,
                    duration=acquired.duration, method="local original and playback byte counts")

    def measure(self, item):
        cache = self.cache / item.id / "measurement.json"
        if cache.exists():
            previous = json.loads(cache.read_text(encoding="utf-8"))
            if (previous.get("sourceURL") == item.source_url and previous.get("compatibilityVersion") == 2
                    and (item.kind != "video" or previous.get("qualityPolicyVersion") == 1)):
                return previous
        details = None
        if item.kind == "video":
            info = self.extract(item)
            item.title = info.get("title") or item.title
            item.creator = info.get("uploader_id") or item.creator
            if (not info.get("requested_formats") and info.get("ext") in ("mp4", "mov", "m4v")
                    and info.get("url") and info.get("protocol", "https") in ("http", "https")):
                url = info["url"]
                with self._probe_url(url) as probe_url:
                    try:
                        probe = self.probe(probe_url)
                    except (RuntimeError, ValueError, subprocess.TimeoutExpired):
                        probe = {}
                    native = (probe.get("video_codec") in ("h264", "hevc") and
                              probe.get("audio_codec") in (None, "aac", "alac") and
                              probe.get("pixel_format") in ("yuv420p", "yuv420p10le") and
                              (probe.get("video_codec") != "hevc" or probe.get("codec_tag") == "hvc1"))
                    if native:
                        if len(self.observed_lengths) > 1:
                            raise ValueError("The media server reported inconsistent complete file lengths")
                        size = next(iter(self.observed_lengths)) if self.observed_lengths else self.size(url)
                        art_bytes = 0
                        if self.artwork:
                            cache.parent.mkdir(parents=True, exist_ok=True)
                            art = self.tools.thumbnail(probe_url, cache.parent / "artwork.jpg")
                            art_bytes = art.stat().st_size
                        details = dict(originalBytes=size, playbackBytes=size, artworkBytes=art_bytes, cloudBytes=size + art_bytes,
                                       duration=probe.get("duration", 0), width=probe.get("width"), height=probe.get("height"),
                                       method="confirmed HTTP file length and native codec probe", qualityPending=True)
        if details is None:
            details = self._acquired(item)
        result = dict(id=item.id, sourceURL=item.source_url, kind=item.kind, title=item.title, creator=item.creator,
                      status="measured", compatibilityVersion=2, qualityPolicyVersion=1,
                      qualityPending=details.pop("qualityPending", False), measuredAt=datetime.now(timezone.utc).isoformat(), **details)
        cache.parent.mkdir(parents=True, exist_ok=True)
        cache.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
        return result

    def close(self):
        if self.downloader:
            self.downloader.close()
            self.downloader = None


def measure_item(cache, item):
    from .audit_auth import load_session
    cookies = load_session(data_directory() / "cost-audit" / "tiktok-session.bin")
    sizer = MediaSizer(cache, artwork=True, cookies=cookies)
    try:
        return sizer.measure(item)
    finally:
        sizer.close()


def scope_ledger(ledger, playlist_ids=()):
    playlist_ids = list(dict.fromkeys(playlist_ids))
    missing = set(playlist_ids) - ledger["collections"].keys()
    if missing:
        raise ValueError("Unknown playlist IDs: " + ", ".join(sorted(missing)))
    collections = ({key: ledger["collections"][key] for key in playlist_ids}
                   if playlist_ids else ledger["collections"])
    item_ids = {key for value in collections.values() for key in value["itemIds"]}
    return dict(ledger, collections=collections,
                media={key: value for key, value in ledger["media"].items()
                       if not playlist_ids or key in item_ids},
                accountAdvertisedCollectionCount=ledger["advertisedCollectionCount"],
                advertisedCollectionCount=len(playlist_ids) if playlist_ids else ledger["advertisedCollectionCount"],
                scope=dict(kind="selected-playlists" if playlist_ids else "account", playlistIds=playlist_ids))


def report(ledger, measurements, rate):
    measurements = {key: value for key, value in measurements.items() if key in ledger["media"]}
    measured = {key: value for key, value in measurements.items() if value["status"] == "measured" and key in ledger["media"]}
    cloud_bytes = sum(value["cloudBytes"] for value in measured.values())
    playback_bytes = sum(value["playbackBytes"] for value in measured.values())
    failed = sum(value["status"] != "measured" for value in measurements.values())
    pending = len(ledger["media"]) - len(measurements)
    collections = []
    for value in ledger["collections"].values():
        known = [measured[key] for key in value["itemIds"] if key in measured]
        membership_complete = value["finished"] and len(value["itemIds"]) == value["advertisedCount"]
        missing = max(0, value["advertisedCount"] - len(value["itemIds"])) if value["advertisedCount"] is not None else None
        collections.append(dict(id=value["id"], name=value["name"], advertisedCount=value["advertisedCount"],
                                observedCount=len(value["itemIds"]), scanFinished=value["finished"], measuredCount=len(known),
                                unobservedCount=missing, unmeasuredCount=len(value["itemIds"]) - len(known),
                                membershipComplete=membership_complete,
                                qualityPendingPosts=sum(bool(item.get("qualityPending")) for item in known),
                                complete=membership_complete and len(known) == len(value["itemIds"]) and not any(item.get("qualityPending") for item in known),
                                cloudBytes=sum(item["cloudBytes"] for item in known),
                                playbackBytes=sum(item["playbackBytes"] for item in known)))
    complete = (len(collections) == ledger["advertisedCollectionCount"]
                and all(value["complete"] for value in collections)
                and len(measured) == len(ledger["media"]))
    return dict(updatedAt=datetime.now(timezone.utc).isoformat(), region="westus2", tier="Standard GPv2 Hot LRS",
                complete=complete, totalsAreLowerBounds=not complete,
                qualityPendingPosts=sum(bool(value.get("qualityPending")) for value in measured.values()),
                unobservedPlaylistEntries=sum(value["unobservedCount"] or 0 for value in collections),
                failedObservedPosts=failed, pendingObservedPosts=pending,
                scope=ledger.get("scope", dict(kind="account", playlistIds=[])),
                accountAdvertisedCollectionCount=ledger.get("accountAdvertisedCollectionCount", ledger["advertisedCollectionCount"]),
                advertisedCollectionCount=ledger["advertisedCollectionCount"], observedCollectionCount=len(collections),
                uniqueObservedPosts=len(ledger["media"]), measuredPosts=len(measured), cloudBytes=cloud_bytes,
                storageBillingGB=cloud_bytes / 1024 ** 3, playbackBytes=playback_bytes,
                storageRateUSDPerGBMonth=rate,
                monthlyStorageUSDWithFirstYearAllowance=storage_cost(cloud_bytes / 1024 ** 3, rate, free_gb=5),
                monthlyStorageUSDAfterFirstYear=storage_cost(cloud_bytes / 1024 ** 3, rate),
                oneFullOfflineDownloadEgressGB=playback_bytes / 10 ** 9,
                oneFullOfflineDownloadEgressUSD=max(0, playback_bytes / 10 ** 9 - 100) * 0.087,
                collections=collections, media=measurements,
                exclusions=["Actual future streaming/download traffic is unknown", "Request/backend costs and taxes are additional",
                            "Unobserved or unmeasured posts are excluded; this is not a full-library total until all gaps are resolved",
                            "Byte-identical files across different post IDs may further reduce storage after content hashing"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--membership", type=Path, default=data_directory() / "cost-audit" / "membership.json")
    parser.add_argument("--output", type=Path, default=data_directory() / "cost-audit" / "result.json")
    parser.add_argument("--cache", type=Path, default=data_directory() / "cost-audit-media")
    parser.add_argument("--workers", type=int, default=3)
    parser.add_argument("--playlist-id", action="append", default=[], help="Measure only this playlist; can be repeated")
    parser.add_argument("--follow", action="store_true")
    parser.add_argument("--rate", type=float, default=0.0184)
    args = parser.parse_args()
    if not 1 <= args.workers <= 8:
        parser.error("Use 1 to 8 workers")
    args.cache.mkdir(parents=True, exist_ok=True)
    try:
        measurements = json.loads(args.output.read_text(encoding="utf-8")).get("media", {})
    except FileNotFoundError:
        measurements = {}
    # Aggregate checkpoints otherwise bypass MediaSizer.measure's per-file
    # policy check by seeding these legacy entries directly into `queued`.
    measurements = {key: value for key, value in measurements.items()
                    if value.get("status") != "measured" or value.get("compatibilityVersion") == 2}
    queued = {key for key, value in measurements.items() if value["status"] == "measured"}
    futures = {}
    last_progress = None
    auth_path = data_directory() / "cost-audit" / "tiktok-session.bin"
    auth_revision = auth_path.stat().st_mtime if auth_path.exists() else 0
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        while True:
            try:
                ledger = json.loads(args.membership.read_text(encoding="utf-8"))
            except (FileNotFoundError, json.JSONDecodeError):
                if not args.follow:
                    raise
                time.sleep(1)
                continue
            ledger = scope_ledger(ledger, args.playlist_id)
            current_auth_revision = auth_path.stat().st_mtime if auth_path.exists() else 0
            if current_auth_revision != auth_revision:
                auth_revision = current_auth_revision
                queued.difference_update(key for key, value in measurements.items() if value["status"] == "unmeasured")
                print("Helper authorization updated; retrying unresolved video checks.", flush=True)
            for key, data in ledger["media"].items():
                if key not in queued:
                    queued.add(key)
                    item = MediaItem.decode(data)
                    futures[pool.submit(measure_item, args.cache, item)] = key
            if futures:
                done, _ = wait(futures, timeout=1, return_when=FIRST_COMPLETED)
                for future in done:
                    key = futures.pop(future)
                    try:
                        measurements[key] = future.result()
                    except Exception as error:
                        message = re.sub(r"https?://\S+", "[source URL]", str(error))[:700]
                        measurements[key] = dict(id=key, status="unmeasured", reason=message)
            else:
                time.sleep(1)
            result = report(ledger, measurements, args.rate)
            atomic_json(args.output, result)
            progress = (result["measuredPosts"], len(result["media"]), result["uniqueObservedPosts"], result["cloudBytes"])
            if progress != last_progress:
                print(f"Measured {progress[0]}/{progress[2]} observed posts; {progress[1]-progress[0]} unresolved; {progress[3]/1024**3:.3f} GiB confirmed", flush=True)
                last_progress = progress
            if not futures and (not args.follow or all(value["finished"] for value in ledger["collections"].values())):
                break
    return 0 if result["complete"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
