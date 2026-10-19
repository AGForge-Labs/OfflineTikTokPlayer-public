"""Repair legacy MP3-in-MP4 renditions without changing originals or playlist membership."""
import argparse
import json
from pathlib import Path
import shutil
from .catalog import AssetRef, MediaItem
from .cost_audit import atomic_json
from .graph import GraphClient, StorageFull
from .media import MediaTools
from .store import LibraryStore, checksum


class AudioRepair:
    backup_name = "audio-repair-previous-catalog.json"

    def __init__(self, store, tools, state_path, *, graph=None, progress=lambda message: None, cancelled=lambda: False):
        self.store, self.tools, self.graph = store, tools, graph
        self.path = Path(state_path)
        self.progress, self.cancelled = progress, cancelled
        library_id = store.catalog().library_id
        if self.path.exists():
            self.state = json.loads(self.path.read_text(encoding="utf-8"))
            if (self.state.get("schemaVersion") != 1 or self.state.get("libraryId") != library_id
                    or not isinstance(self.state.get("items"), dict)):
                raise ValueError("Audio repair checkpoint belongs to a different library or is invalid")
        else:
            self.state = dict(schemaVersion=1, libraryId=library_id, items={})

    def _check(self):
        if self.cancelled():
            raise InterruptedError("Audio repair paused; originals, published library and checkpoints are retained")

    def _save(self):
        atomic_json(self.path, self.state, check=self._check)

    def _replacement_path(self, old):
        return old.with_name(old.stem + ".iphone.mp4")

    def _verified(self, media_id, entry):
        item, local = self.store.item(media_id), self.store.local(media_id)
        if not item or not local:
            raise ValueError("Audio repair item is no longer in the local library")
        old, replacement = Path(entry["oldPlayback"]).resolve(), Path(entry["playback"]).resolve()
        expected = self._replacement_path(old)
        old_asset = AssetRef.decode(entry["oldAsset"])
        if (replacement != expected or Path(local["playback"]).resolve() not in (old, replacement)
                or not item.asset or item.asset.sha256 not in (old_asset.sha256, entry["sha256"])):
            raise ValueError("Audio repair source changed; no replacement was published")
        if (not replacement.is_file() or replacement.stat().st_size != entry["byteSize"]
                or checksum(replacement) != entry["sha256"]):
            raise ValueError("Prepared audio copy changed or failed verification")
        return item, local, replacement

    def prepare(self, media_ids=None):
        selected = set(media_ids) if media_ids is not None else None
        for item in self.store.catalog().media:
            self._check()
            if selected is not None and item.id not in selected:
                continue
            if item.id in self.state["items"]:
                self._verified(item.id, self.state["items"][item.id])
                continue
            local = self.store.local(item.id)
            if item.status != "ready" or not item.asset or not local:
                continue
            old = Path(local["playback"]).resolve()
            info = self.tools.probe(old)
            if info["audio_codec"] != "mp3":
                continue
            if checksum(old) != item.asset.sha256 or local["sha256"] != item.asset.sha256:
                raise ValueError("Archived playback file changed before audio repair")
            if shutil.disk_usage(old.parent).free < 2 * 1073741824 + info["duration"] * 384000:
                raise StorageFull("Audio repair paused: insufficient local space for a lossless copy plus a 2 GiB reserve")
            replacement = self.tools.compatible(old).resolve()
            fixed = self.tools.probe(replacement)
            if (replacement == old or fixed["audio_codec"] != "alac"
                    or any(fixed[key] != info[key] for key in ("video_codec", "width", "height"))
                    or abs(fixed["duration"] - info["duration"]) > 0.2):
                raise ValueError("Compatible audio rendition failed validation")
            self.state["items"][item.id] = dict(oldPlayback=str(old), oldAsset=item.asset.wire(),
                playback=str(replacement), sha256=checksum(replacement), byteSize=replacement.stat().st_size,
                uploadedAsset=None)
            self._save()
            self.progress(f"Prepared audio repair {len(self.state['items'])}: {item.id}")
        return sum(self.store.item(media_id).asset.sha256 != entry["sha256"]
                   for media_id, entry in self.state["items"].items())

    def sync(self):
        if not self.graph:
            raise ValueError("Connect OneDrive before publishing repaired audio")
        self._check()
        drive_id, root_id = self.graph.app_folder()
        pending = []
        for media_id, entry in self.state["items"].items():
            item, local, replacement = self._verified(media_id, entry)
            if item.asset.sha256 != entry["sha256"]:
                pending.append((media_id, entry, replacement))
        if not pending:
            return self.store.catalog()
        for item in self.store.catalog().media:
            if any(ref and ref.drive_id != drive_id for ref in (item.asset, item.original, item.artwork)):
                raise ValueError("The repaired library belongs to a different OneDrive account")
        required = sum(entry["byteSize"] for _, entry, _ in pending if not entry["uploadedAsset"])
        quota = self.graph.quota()
        if quota and quota.get("remaining", required) < required:
            raise StorageFull(f"OneDrive needs {required / 1073741824:.2f} GiB for repaired playback copies; originals are retained")
        media_root = self.graph.folder("media", drive_id, root_id)
        for index, (media_id, entry, path) in enumerate(pending, 1):
            self._check()
            self._verified(media_id, entry)
            if entry["uploadedAsset"]:
                cached = AssetRef.decode(entry["uploadedAsset"])
                self._validate_ref(cached, entry, drive_id)
                if not self.graph.verify_file(cached, path):
                    entry["uploadedAsset"] = None
                    self._save()
                    quota = self.graph.quota()
                    if quota and quota.get("remaining", entry["byteSize"]) < entry["byteSize"]:
                        raise StorageFull("OneDrive has insufficient space to replace a missing or changed repaired file")
            if not entry["uploadedAsset"]:
                ref = self.graph.upload_file(path, entry["sha256"] + ".mp4", drive_id, media_root)
                self._validate_ref(ref, entry, drive_id)
                if not self.graph.verify_file(ref, path):
                    raise ValueError("Repaired upload failed live OneDrive checksum verification")
                entry["uploadedAsset"] = ref.wire()
                self._save()
            else:
                self._validate_ref(AssetRef.decode(entry["uploadedAsset"]), entry, drive_id)
            self.progress(f"Uploaded repaired audio {index}/{len(pending)}: {media_id}")
        self._check()
        # Read the latest metadata after transfers so newly imported items are retained.
        catalog = self.store.catalog()
        backup = self.path.with_name(self.backup_name)
        if not backup.exists():
            backup.write_text(catalog.to_json(), encoding="utf-8")
        replacements = {}
        for media_id, entry, path in pending:
            self._verified(media_id, entry)
            item = next(item for item in catalog.media if item.id == media_id)
            item.asset = AssetRef.decode(entry["uploadedAsset"])
            replacements[media_id] = dict(item=item, playback=str(path), sha256=entry["sha256"], byte_size=entry["byteSize"])
        catalog.validate()
        # Until this succeeds, both the phone and the local store keep the old catalog.
        self.graph.publish(catalog, drive_id, root_id)
        self.store.replace_playback_copies(replacements)
        self.progress(f"Published {len(pending)} repaired audio copies; originals and playlists are unchanged")
        return catalog

    @staticmethod
    def _validate_ref(ref, entry, drive_id):
        ref.validate()
        if ref.drive_id != drive_id or ref.sha256 != entry["sha256"] or ref.byte_size != entry["byteSize"]:
            raise ValueError("OneDrive did not confirm the repaired file identity and checksum")


def main():
    from .auth import MicrosoftAuth
    from .gui import data_directory
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path, default=data_directory())
    parser.add_argument("--media-id", action="append")
    parser.add_argument("--publish", action="store_true", help="Upload verified copies and publish their catalog after preparation")
    args = parser.parse_args()
    store = LibraryStore(args.data_dir / "library.sqlite")
    graph = None
    try:
        if args.publish:
            config = json.loads((args.data_dir / "settings.json").read_text(encoding="utf-8"))
            auth = MicrosoftAuth(config["clientId"], args.data_dir)
            graph = GraphClient(auth.token, store, progress=print)
        repair = AudioRepair(store, MediaTools(), args.data_dir / "audio-repair-v1.json", graph=graph, progress=print)
        count = repair.prepare(args.media_id)
        print(f"Verified compatible copies pending publication: {count}", flush=True)
        if args.publish: repair.sync()
    finally:
        if graph: graph.close()
        store.close()


if __name__ == "__main__":
    main()
