"""Quiet OneDrive companion. Only this process owns the optional quality index."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import asdict
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import shutil
import sys
from tempfile import TemporaryDirectory
import time
from urllib.parse import quote, urlparse

import httpx

from .auth import MicrosoftAuth
from .catalog import Catalog, StreamEnhancement
from .graph import AuthenticationRequired, GraphClient, StorageFull
from .store import LibraryStore, checksum
from .stream_quality import PROFILE_VERSION, enhance

INDEX_NAME = "stream-quality-v1.json"
MAX_INDEX_BYTES = 10 * 1024 * 1024


def _root(drive, folder, name):
    return f"/drives/{quote(drive, safe='')}/items/{quote(folder, safe='')}:/{quote(name, safe='')}"


def _document(graph, drive, folder, name, *, missing=False):
    meta = graph._request("GET", _root(drive, folder, name), allowed=(404,) if missing else ())
    if meta.status_code == 404:
        return None
    data = meta.json()
    url = data.get("@microsoft.graph.downloadUrl", "")
    size = data.get("size", 0)
    if urlparse(url).scheme != "https" or type(size) is not int or not 0 < size <= MAX_INDEX_BYTES:
        raise ValueError("OneDrive returned invalid private library metadata")
    content = bytearray()
    with graph.http.stream("GET", url, follow_redirects=True, headers={"Cache-Control": "no-cache"}) as response:
        if response.status_code != 200:
            raise RuntimeError("Could not read private library metadata")
        for block in response.iter_bytes(1024 * 1024):
            content.extend(block)
            if len(content) > size:
                raise ValueError("The private library metadata exceeds its declared size")
    if len(content) != size:
        raise ValueError("The private library metadata is incomplete")
    return bytes(content)


def _read_index(raw, library_id):
    if raw is None:
        return {}
    data = json.loads(raw)
    if data.get("version") != PROFILE_VERSION or data.get("libraryId") != library_id or not isinstance(data.get("items"), dict):
        raise ValueError("Enhanced playback index does not belong to this library and profile")
    return {key: StreamEnhancement.decode(value) for key, value in data["items"].items()}


def _publish(graph, drive, folder, library_id, entries):
    content = json.dumps(dict(version=PROFILE_VERSION, libraryId=library_id,
                             items={key: value.wire() for key, value in entries.items()}),
                         ensure_ascii=False, separators=(",", ":")).encode()
    if len(content) > MAX_INDEX_BYTES:
        raise ValueError("Enhanced playback index exceeds the size limit")
    result = graph._request("PUT", _root(drive, folder, INDEX_NAME) + ":/content",
                            headers={"Content-Type": "application/json"}, content=content)
    if result.json().get("size") != len(content) or _document(graph, drive, folder, INDEX_NAME) != content:
        raise ValueError("OneDrive did not confirm the quality index bytes")


def _retrieve(graph, asset, path):
    for attempt in range(3):
        digest, size = hashlib.sha256(), 0
        url = graph.resolve(asset)
        try:
            with graph.http.stream("GET", url, follow_redirects=True) as response:
                if response.status_code in (401, 403, 404, 408, 429) or response.status_code >= 500:
                    if attempt < 2:
                        time.sleep(2 ** attempt)
                        continue
                if response.status_code != 200:
                    raise ValueError("OneDrive did not return the complete archived media")
                with path.open("wb") as stream:
                    for block in response.iter_bytes(1024 * 1024):
                        size += len(block)
                        if size > asset.byte_size:
                            raise ValueError("OneDrive returned more bytes than the archive declares")
                        digest.update(block)
                        stream.write(block)
        except httpx.TransportError:
            if attempt == 2:
                raise ValueError("Archived media transfer was interrupted") from None
            continue
        if size == asset.byte_size and digest.hexdigest() == asset.sha256:
            return
    raise ValueError("Archived media failed its checksum")


def _atomic_json(path, value):
    partial = path.with_suffix(".tmp")
    partial.write_text(json.dumps(value, allow_nan=False, separators=(",", ":")), encoding="utf-8")
    partial.replace(path)


def _verified_existing(index, item):
    try:
        index[item.id].validate(item.asset)
        return True
    except (KeyError, ValueError):
        return False


def _ready_state(item, checkpoint):
    value = checkpoint.get(item.id, {})
    return value if value.get("source") == item.asset.sha256 else {}


def pending_items(catalog, entries, checkpoint, now, *, added_ids=()):
    ready = [i for i in catalog.media if i.status == "ready" and i.asset]
    ordered = enumerate(ready)

    def sort_key(pair):
        sequence, item = pair
        if item.id in added_ids:
            # New imports should get their enhancement without waiting behind
            # the entire archived collection; retain the quiet-first backfill.
            return (-1, -sequence)
        loudness = item.audio_loudness
        if loudness and loudness.asset_sha256 == item.asset.sha256:
            level = loudness.integrated_lufs
            return (0 if level < -20 else 2, level if level < -20 else -sequence)
        return (1, -sequence)

    def due(item):
        if _verified_existing(entries, item):
            return False
        state = _ready_state(item, checkpoint)
        return (state.get("phase") not in ("unchanged", "unavailable")
                and (state.get("phase") != "retry" or state.get("retryAfter", 0) <= now))

    return [item for _, item in sorted(ordered, key=sort_key) if due(item)]


class Job:
    def __init__(self, data, state, *, workers=2, log=print):
        self.data, self.state, self.workers, self.log = Path(data), Path(state), workers, log
        self.state.mkdir(parents=True, exist_ok=True)
        config = json.loads((self.data / "settings.json").read_text(encoding="utf-8-sig"))
        self.auth = MicrosoftAuth(config.get("clientId", ""), self.data)
        self.checkpoint_path = self.state / "quality-backfill-v1.json"
        self.status = self.state / "quality-status.json"
        if self.checkpoint_path.exists():
            document = json.loads(self.checkpoint_path.read_text(encoding="utf-8"))
            self.previous_library = document["libraryId"]
            self.checkpoint = document["items"]
            self.priority = set(document.get("priority", ()))
        else:
            self.previous_library = None
            self.checkpoint = {}
            self.priority = set()
        self._seen = None

    def _graph(self):
        # The normal helper keeps its own SQLite writer and import checkpoints.
        # Only upload-session capabilities belong in this separate local database.
        store = LibraryStore(self.state / "quality-upload-sessions.sqlite")
        graph = GraphClient(self.auth.token, store)
        return store, graph

    def _create(self, item, media_root):
        store, graph = self._graph()
        try:
            with TemporaryDirectory(dir=self.state, prefix="quality-work-") as scratch:
                directory = Path(scratch)
                suffix = Path(item.asset.file_name).suffix.lower()
                source = directory / ("archived" + (suffix if suffix in (".mp4", ".mov", ".m4v") else ".mp4"))
                output = directory / "enhanced.mp4"
                _retrieve(graph, item.asset, source)
                result = enhance(source, output)
                if not result.path:
                    return None, result
                if checksum(output) == item.asset.sha256:
                    return None, result
                filename = checksum(output) + ".mp4"
                asset = graph.upload_file(output, filename, item.asset.drive_id, media_root)
                enhancement = StreamEnhancement(item.asset.sha256, asset, result.audio_mastered)
                enhancement.validate(item.asset)
                if not graph.verify_file(asset, output):
                    raise ValueError("Uploaded enhancement failed OneDrive verification")
                if len(graph.read_range(asset, 0, min(4095, asset.byte_size - 1))) != min(4096, asset.byte_size):
                    raise ValueError("Uploaded enhancement failed HTTP range verification")
                return enhancement, result
        finally:
            graph.close()
            store.close()

    def run(self, limit=None, time_budget=None):
        if shutil.disk_usage(self.state).free < 2 * 1024**3:
            raise StorageFull("Backfill paused; less than 2 GiB local space remains")
        store, graph = self._graph()
        try:
            drive, root = graph.app_folder()
            catalog = Catalog.from_json(_document(graph, drive, root, "catalog.json"))
            if self.previous_library and self.previous_library != catalog.library_id:
                raise ValueError("Backfill stopped because the OneDrive library has changed")
            entries = _read_index(_document(graph, drive, root, INDEX_NAME, missing=True), catalog.library_id)
            if any(item.status == "ready" and item.asset and item.asset.drive_id != drive for item in catalog.media):
                raise ValueError("The catalog contains media from a different OneDrive")
            ready = [item for item in catalog.media if item.status == "ready" and item.asset]
            seen = {item.id for item in ready}
            if self._seen is not None:
                self.priority.update(seen - self._seen)
                self.priority.intersection_update(seen)
            self._seen = seen
            pending = pending_items(catalog, entries, self.checkpoint, time.time(), added_ids=self.priority)
            total = len(ready)
            matching = {item.id for item in catalog.media if _verified_existing(entries, item)}
            deadline = time.monotonic() + time_budget if time_budget else None

            def progress(phase):
                state = [_ready_state(item, self.checkpoint) for item in ready if item.id not in matching]
                unchanged, retries, unavailable = (sum(1 for value in state if value.get("phase") == name)
                                                    for name in ("unchanged", "retry", "unavailable"))
                status = dict(phase=phase, playable=total, enhanced=len(matching),
                              pending=total-len(matching)-unchanged-retries-unavailable,
                              unchanged=unchanged, retries=retries, unavailable=unavailable,
                              updatedAt=datetime.now(timezone.utc).isoformat())
                _atomic_json(self.status, status)
                self.log(f"{phase}: {len(matching)} enhanced of {total}; {unchanged} kept as archived; "
                         f"{retries} retrying; {unavailable} need review")

            progress("running" if pending else "watching")
            if not pending:
                return False
            folder = graph.folder("stream-quality-v1", drive, root)
            # Initialize the upload DB once before starting SQLite connections in worker threads.
            for start in range(0, min(len(pending), limit or len(pending)), 6):
                if (self.state / "pause").exists():
                    progress("paused")
                    return False
                if deadline and start > 0 and time.monotonic() >= deadline:
                    return True  # Refresh the catalog and serve new imports/retries promptly.
                stop = min(start + 6, limit or len(pending))
                replacements = {}
                states = {}
                with ThreadPoolExecutor(max_workers=self.workers) as pool:
                    work = {pool.submit(self._create, item, folder): item for item in pending[start:stop]}
                    for future in as_completed(work):
                        item = work[future]
                        try:
                            variant, result = future.result()
                        except (AuthenticationRequired, StorageFull):
                            raise
                        except Exception as error:
                            previous = self.checkpoint.get(item.id, {})
                            count = 1 + (previous.get("attempts", 0) if previous.get("source") == item.asset.sha256 else 0)
                            states[item.id] = dict(source=item.asset.sha256, attempts=count,
                                phase="retry" if count < 3 else "unavailable", retryAfter=time.time() + 900 * count,
                                reason=type(error).__name__ + ": " + (str(error) if type(error) is ValueError else "failed quality verification"))
                            continue
                        measured = asdict(result)
                        measured.pop("path")
                        if variant:
                            replacements[item.id] = variant
                        states[item.id] = dict(source=item.asset.sha256, phase="enhanced" if variant else "unchanged", **measured)
                if replacements:
                    # The importer cannot overwrite this index. Source checksums
                    # make a simultaneous change to a primary asset harmless.
                    combined = entries | replacements
                    _publish(graph, drive, root, catalog.library_id, combined)
                    entries = combined
                    matching.update(replacements)
                self.checkpoint.update(states)
                self.priority.difference_update(replacements)
                self.priority.difference_update(key for key, value in states.items() if value["phase"] == "unchanged")
                self.previous_library = catalog.library_id
                _atomic_json(self.checkpoint_path, dict(libraryId=catalog.library_id, items=self.checkpoint,
                                                        priority=sorted(self.priority)))
                progress("running")
            progress("watching" if len(pending) <= (limit or len(pending)) else "pilot-complete")
            return True
        finally:
            graph.close()
            store.close()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", required=True, type=Path)
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--limit", type=int)
    parser.add_argument("--workers", type=int, choices=(1, 2, 3, 4), default=2)
    args = parser.parse_args(argv)
    if args.limit is not None and (not args.once or args.limit < 1):
        parser.error("A positive limit requires --once")
    from .instance import HelperInstance
    instance = HelperInstance(args.state)
    if not instance.acquire():
        return 0
    try:
        job = Job(args.data, args.state, workers=args.workers, log=lambda message: print(message, flush=True))
        while True:
            worked = False
            try:
                instance.report(mode="quality", visible=False)
                if not (args.state / "pause").exists():
                    worked = job.run(limit=args.limit, time_budget=None if args.once else 12 * 60)
            except (AuthenticationRequired, StorageFull, OSError, RuntimeError, ValueError) as error:
                # URLs or paths from network/subprocess exceptions do not go to logs.
                print(f"Quality backfill paused for retry: {type(error).__name__}", flush=True)
                if args.once:
                    return 1
            if args.once:
                return 0
            time.sleep(1 if worked else 15 * 60)
    finally:
        instance.close()


if __name__ == "__main__":
    sys.exit(main())
