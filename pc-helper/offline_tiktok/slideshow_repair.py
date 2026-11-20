"""Repair legacy Photo Mode playback using the retained originals."""
import argparse
from collections import Counter
from concurrent.futures import as_completed, ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import shutil
from time import sleep
from urllib.parse import quote, urlparse
import zipfile

from .catalog import AssetRef
from .cost_audit import atomic_json
from .graph import MediaVerificationInterrupted
from .instance import HelperInstance
from .media import MediaTools
from .photo import NATIVE_MEMBER, PHOTO_RENDER, archive_images, render_archive
from .quality_backfill import MAX_INDEX_BYTES, _retrieve, _root
from .store import LibraryStore, checksum


def _catalog_snapshot(graph, drive, root):
    meta = graph._request("GET", _root(drive, root, "catalog.json")).json()
    size, url = meta["size"], meta.get("@microsoft.graph.downloadUrl", "")
    if (not meta.get("id") or not meta.get("eTag") or not 0 < size <= MAX_INDEX_BYTES
            or urlparse(url).scheme != "https"):
        raise ValueError("Cannot verify the OneDrive catalog revision")
    content = bytearray()
    with graph.http.stream("GET", url, follow_redirects=True, headers={"Cache-Control": "no-cache"}) as response:
        if response.status_code != 200:
            raise ValueError("Could not read the current OneDrive catalog")
        for chunk in response.iter_bytes(1024 * 1024):
            content.extend(chunk)
            if len(content) > size:
                raise ValueError("Catalog exceeded its declared size")
    if len(content) != size:
        raise ValueError("Incomplete catalog download")
    return meta, bytes(content)


class SlideshowRepair:
    def __init__(self, store, data, state, tools, *, graph=None, progress=lambda message: None):
        self.store, self.tools, self.graph, self.progress = store, tools, graph, progress
        self.data, self.state = Path(data).resolve(), Path(state).resolve()
        self.state.mkdir(parents=True, exist_ok=True)
        self.library_id = store.catalog().library_id
        self.path = self.state / "photo-timing-v1.json"
        self.checkpoint = (json.loads(self.path.read_text(encoding="utf8")) if self.path.exists() else
                           dict(version=1, libraryId=self.library_id, driveId=None, items={}))
        if (self.checkpoint.get("version") != 1 or self.checkpoint.get("libraryId") != self.library_id
                or not isinstance(self.checkpoint.get("items"), dict)):
            raise ValueError("Photo checkpoint belongs to another library or version")
        self.entries = self.checkpoint["items"]

    def _save(self):
        atomic_json(self.path, self.checkpoint)

    def _bind_drive(self, drive):
        if self.checkpoint["driveId"] not in (None, drive):
            raise ValueError("Photo repair belongs to another OneDrive account")
        self.checkpoint["driveId"] = drive

    def _paths(self, item_id, original):
        if not re.fullmatch(r"[0-9]+", item_id):
            raise ValueError("Invalid photo post ID")
        original.validate()
        # The checkpoint and every read verify all 256 bits. A shorter directory
        # name also fits Windows tools under a long packaged-app data directory.
        return self.state / item_id / original.sha256[:24]

    def _source_path(self, item, local):
        directory = self._paths(item.id, item.original)
        candidates = [Path(local["original"])] if local and local.get("original") else []
        candidates += [self.data / "media" / item.id / "original-photo.zip", directory / "original-photo.zip"]
        return next((path.resolve() for path in candidates if path.is_file()
                     and path.stat().st_size == item.original.byte_size and checksum(path) == item.original.sha256), None)

    def _prepare_one(self, item, original, base):
        with zipfile.ZipFile(original) as archive:
            images, _ = archive_images(archive)
            if len(images) == 1 and NATIVE_MEMBER not in archive.namelist():
                return dict(base, phase="single")
        if shutil.disk_usage(self.state).free < 2 * 1024 ** 3:
            raise InterruptedError("Photo repair paused for local storage")
        output = self._paths(item.id, item.original) / PHOTO_RENDER
        render_archive(self.tools, original, output, scratch_dir=self.state)
        details = self.tools.probe(output)
        digest = checksum(output)
        if digest == item.asset.sha256:
            return dict(base, phase="current")
        loudness = self.tools.loudness(output) if details["audio_codec"] else None
        return dict(base, phase="prepared", originalPath=str(original), playback=str(output),
                    sha256=digest, byteSize=output.stat().st_size, duration=details["duration"],
                    audioLoudness=loudness.wire() if loudness else None, uploaded=None)

    def prepare(self, *, workers=2, limit=None, fetch_originals=False, retry=False, media_ids=None):
        if not 1 <= workers <= 4 or (limit is not None and limit < 1):
            raise ValueError("Use one to four workers and a positive limit")
        if fetch_originals:
            self._bind_drive(self.graph.app_folder()[0])
        selected = set(media_ids) if media_ids else None
        tasks = []
        for item in self.store.catalog().media:
            if (item.kind != "slideshow" or item.status != "ready" or not item.asset or not item.original
                    or selected is not None and item.id not in selected):
                continue
            self._bind_drive(item.asset.drive_id)
            self._bind_drive(item.original.drive_id)
            base = dict(original=item.original.wire(), oldAsset=item.asset.wire())
            known = self.entries.get(item.id, {})
            if known.get("original") == base["original"]:
                # May be resuming after a successful publish and before saving its checkpoint.
                if known.get("uploaded") == base["oldAsset"] and known.get("phase") == "published":
                    continue
                if known.get("oldAsset") == base["oldAsset"]:
                    phase = known.get("phase")
                    if phase in ("single", "native", "current", "published"):
                        continue
                    if phase == "prepared" and self._verified_render(known):
                        continue
                    if phase == "issue" and not retry:
                        continue
            local = self.store.local(item.id)
            if Path(item.original.file_name).suffix.lower() != ".zip":
                self.entries[item.id] = dict(base, phase="native")
                continue
            if (local and Path(local["playback"]).name == PHOTO_RENDER and local["sha256"] == item.asset.sha256
                    and local["original_sha256"] == item.original.sha256):
                self.entries[item.id] = dict(base, phase="current")
                continue
            original = self._source_path(item, local)
            if original is None and fetch_originals:
                directory = self._paths(item.id, item.original)
                directory.mkdir(parents=True, exist_ok=True)
                partial = directory / "original.part"
                try:
                    _retrieve(self.graph, item.original, partial)
                except Exception as error:
                    self.entries[item.id] = dict(base, phase="issue", reason=type(error).__name__)
                    self._save()
                    continue
                original = directory / "original-photo.zip"
                partial.replace(original)
            if original is None:
                self.entries[item.id] = dict(base, phase="missing")
                continue
            tasks.append((item, original, base))
            if limit and len(tasks) >= limit:
                break
        self._save()
        with ThreadPoolExecutor(max_workers=workers) as pool:
            jobs = {pool.submit(self._prepare_one, *task): task for task in tasks}
            for future in as_completed(jobs):
                item, _, base = jobs[future]
                try:
                    self.entries[item.id] = future.result()
                except (InterruptedError, KeyboardInterrupt):
                    for remaining in jobs:
                        remaining.cancel()
                    raise
                except Exception as error:
                    self.entries[item.id] = dict(base, phase="issue", reason=type(error).__name__,
                                                 detail=re.sub(r"https?://\S+", "[source]", str(error))[-500:])
                self._save()
                self.progress(f"Photo {item.id} {self.entries[item.id]['phase']}")
        return Counter(row["phase"] for item_id, row in self.entries.items() if selected is None or item_id in selected)

    @staticmethod
    def _verified_render(entry):
        path = Path(entry["playback"])
        return path.is_file() and path.stat().st_size == entry["byteSize"] and checksum(path) == entry["sha256"]

    def _patch_item(self, row, entry):
        if row.get("kind") != "slideshow" or row.get("status") != "ready" or not row.get("original") or not row.get("asset"):
            raise ValueError("Photo availability changed since preparation")
        # Later schema versions may attach auxiliary fields to the same
        # original. Compare its complete known identity and keep the raw object.
        original = AssetRef.decode(row["original"])
        current, replacement = AssetRef.decode(row["asset"]), AssetRef.decode(entry["uploaded"])
        if original != AssetRef.decode(entry["original"]) or current not in (AssetRef.decode(entry["oldAsset"]), replacement):
            raise ValueError("Photo source changed since preparation; leaving its catalog intact")
        if current == replacement:
            return False
        row.update(asset=entry["uploaded"], duration=entry["duration"])
        row.pop("streamEnhancement", None)
        row.pop("audioLoudness", None)
        if entry["audioLoudness"]:
            row["audioLoudness"] = entry["audioLoudness"]
        return True

    def _confirm_upload(self, ref, path):
        # OneDrive can acknowledge a content upload before its read replica
        # returns the matching hash. Re-read the same immutable item ID.
        delays = (0, 1, 3, 8)
        for attempt, delay in enumerate(delays, start=1):
            if delay:
                sleep(delay)
            try:
                if self.graph.verify_file(ref, path):
                    return True
            except MediaVerificationInterrupted:
                if attempt == len(delays):
                    raise
        return False

    def _upload(self, pending, drive, root):
        folder = None
        for item_id, entry in pending.items():
            path = Path(entry["playback"])
            if not self._verified_render(entry):
                raise ValueError("Prepared photo rendition changed")
            if entry.get("uploaded"):
                ref = AssetRef.decode(entry["uploaded"])
                if ref.drive_id == drive and self._confirm_upload(ref, path):
                    continue
            folder = folder or self.graph.folder("media", drive, root)
            ref = self.graph.upload_file(path, entry["sha256"] + ".mp4", drive, folder)
            ref.validate()
            if (ref.drive_id != drive or ref.sha256 != entry["sha256"] or ref.byte_size != entry["byteSize"]
                    or ref.item_id in (entry["oldAsset"]["itemId"], entry["original"]["itemId"])
                    or not self._confirm_upload(ref, path)):
                raise ValueError("Replacement photo upload failed verification")
            entry["uploaded"] = ref.wire()
            self._save()
            self.progress(f"Photo {item_id} uploaded")

    def publish(self, media_ids=None):
        selected = set(media_ids) if media_ids else None
        pending = {k: v for k, v in self.entries.items() if v["phase"] == "prepared"
                   and (selected is None or k in selected)}
        if not pending:
            return 0
        drive, root = self.graph.app_folder()
        self._bind_drive(drive)
        meta, raw = _catalog_snapshot(self.graph, drive, root)
        if json.loads(raw).get("libraryId") != self.library_id:
            raise ValueError("OneDrive contains a different photo library")
        self._upload(pending, drive, root)
        with self.store.db:
            self.store.db.execute("BEGIN IMMEDIATE")
            meta, raw = _catalog_snapshot(self.graph, drive, root)
            current = json.loads(raw)
            if current.get("libraryId") != self.library_id or current.get("schemaVersion") != 1:
                raise ValueError("OneDrive catalog belongs to another library or version")
            rows = {row["id"]: row for row in current["media"]}
            if len(rows) != len(current["media"]) or not pending.keys() <= rows.keys():
                raise ValueError("Catalog media identities changed since preparation")
            changed = False
            for item_id, entry in pending.items():
                changed |= self._patch_item(rows[item_id], entry)
                local_item = self.store.item(item_id)
                if not local_item:
                    raise ValueError("Local library membership changed")
                self._patch_item(local_item.wire(), entry)
                source = Path(entry["originalPath"])
                if not source.is_file() or checksum(source) != entry["original"]["sha256"]:
                    raise ValueError("Retained photo original changed before publication")
            if changed:
                backup = self.state / ("catalog-before-" + hashlib.sha256(raw).hexdigest()[:24] + ".json")
                if not backup.exists():
                    with backup.open("xb") as stream:
                        stream.write(raw)
                if backup.read_bytes() != raw:
                    raise ValueError("Could not verify the previous catalog backup")
                current["updatedAt"] = datetime.now(timezone.utc).isoformat()
                content = json.dumps(current, ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode("utf8")
                path = f"/drives/{quote(drive, safe='')}/items/{quote(meta['id'], safe='')}/content"
                response = self.graph._request("PUT", path, headers={"If-Match": meta["eTag"],
                    "Content-Type": "application/json"}, content=content, allowed=(412,))
                if response.status_code == 412:
                    raise ValueError("OneDrive catalog changed during publication; retry the saved photo repairs")
                confirmed, actual = _catalog_snapshot(self.graph, drive, root)
                if confirmed["id"] != meta["id"] or actual != content:
                    raise ValueError("Could not confirm the published photo catalog bytes")
            for item_id, entry in pending.items():
                local = self.store.local(item_id) or {}
                local.update(original=entry["originalPath"], original_sha256=entry["original"]["sha256"],
                             playback=entry["playback"], sha256=entry["sha256"], byte_size=entry["byteSize"])
                local.setdefault("artwork", None)
                encoded = json.dumps(rows[item_id], allow_nan=False)
                self.store.db.execute("UPDATE media SET data=?,remote_data=?,local_data=?,last_error=NULL WHERE id=?",
                                      (encoded, encoded, json.dumps(local), item_id))
        for entry in pending.values():
            entry["phase"] = "published"
        self._save()
        return len(pending)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", required=True, type=Path)
    parser.add_argument("--state-dir", type=Path)
    parser.add_argument("--media-id", action="append")
    parser.add_argument("--limit", type=int)
    parser.add_argument("--workers", type=int, choices=range(1, 5), default=2)
    parser.add_argument("--retry", action="store_true", help="Recheck source issues already recorded for these originals")
    parser.add_argument("--fetch-originals", action="store_true", help="Retrieve missing original ZIPs from this OneDrive")
    parser.add_argument("--publish", action="store_true", help="Publish verified prepared replacements to this library")
    args = parser.parse_args(argv)
    state = args.state_dir or args.data_dir / "photo-timing-v1"
    if not (args.data_dir / "library.sqlite").is_file():
        parser.error("The original private library database is required")
    job = HelperInstance(state / "job")
    if not job.acquire():
        parser.error("Another photo repair is using these checkpoints")
    store = graph = owner = None
    try:
        store = LibraryStore(args.data_dir / "library.sqlite")
        if args.fetch_originals or args.publish:
            from .auth import MicrosoftAuth
            from .graph import GraphClient
            config = json.loads((args.data_dir / "settings.json").read_text(encoding="utf-8-sig"))
            auth = MicrosoftAuth(config["clientId"], args.data_dir)
            graph = GraphClient(auth.token, store)
        repair = SlideshowRepair(store, args.data_dir, state, MediaTools(), graph=graph,
                                 progress=lambda message: print(message, flush=True))
        counts = repair.prepare(workers=args.workers, limit=args.limit, fetch_originals=args.fetch_originals,
                                retry=args.retry, media_ids=args.media_id)
        print(json.dumps(counts), flush=True)
        if args.publish:
            owner = HelperInstance(args.data_dir)
            if not owner.acquire():
                raise RuntimeError("The import helper owns this library; exit it before publishing the prepared photos")
            print(f"Published {repair.publish(args.media_id)} photo repairs", flush=True)
        return int(bool(counts["issue"] or counts["missing"]))
    finally:
        if owner: owner.close()
        if graph: graph.close()
        if store: store.close()
        job.close()


if __name__ == "__main__":
    raise SystemExit(main())
