"""Explicit user-selected import scope; does not declare the source scan complete."""
from dataclasses import dataclass
import argparse
import hashlib
import json
from pathlib import Path
from .catalog import MediaItem


def membership_digest(ids):
    return hashlib.sha256(json.dumps(ids, separators=(",", ":")).encode()).hexdigest()


@dataclass
class AcceptedSnapshot:
    collection_id: str
    name: str
    source_url: str
    source_count: int
    items: list[MediaItem]
    accepted_at: str
    reason: str
    membership_sha256: str

    @property
    def item_ids(self):
        return [item.id for item in self.items]

    @property
    def provenance(self):
        return dict(kind="acceptedSnapshot", sourceAdvertisedCount=self.source_count,
                    observedCount=len(self.items), excludedUnobservedCount=self.source_count - len(self.items),
                    acceptedAt=self.accepted_at, reason=self.reason, membershipSHA256=self.membership_sha256)

    def validate(self):
        ids = self.item_ids
        if not self.collection_id or not ids or len(ids) != len(set(ids)) or "" in ids:
            raise ValueError("Snapshot has invalid or duplicate membership")
        if self.source_count < len(ids) or not self.accepted_at or not self.reason.strip():
            raise ValueError("Snapshot requires explicit acceptance and source count")
        if membership_digest(ids) != self.membership_sha256:
            raise ValueError("Snapshot membership digest does not match the reviewed order")
        if any(item.status not in ("pending", "unavailable") or item.asset for item in self.items):
            raise ValueError("A membership snapshot cannot claim uploaded or ready assets")

    @classmethod
    def from_checkpoint(cls, ledger, collection_id, *, expected_observed, expected_source, accepted_at, reason, measurements=None):
        collection = ledger["collections"].get(collection_id)
        if not collection:
            raise ValueError("Selected collection is absent from the checkpoint")
        ids = collection["itemIds"]
        if len(ids) != expected_observed or collection.get("advertisedCount") != expected_source:
            raise ValueError("Checkpoint counts differ from the explicitly accepted snapshot")
        items = []
        measured = (measurements or {}).get("media", {})
        for item_id in ids:
            if item_id not in ledger.get("media", {}):
                raise ValueError(f"Snapshot member {item_id} has no source metadata")
            item = MediaItem.decode(ledger["media"][item_id])
            if item.id != item_id:
                raise ValueError("Snapshot member identity differs from its metadata")
            item.asset = item.original = item.artwork = None
            result = measured.get(item_id, {})
            item.status = "unavailable" if result.get("status") == "unmeasured" else "pending"
            if result.get("status") == "measured":
                item.title = result.get("title") or item.title
                item.duration = result.get("duration", item.duration)
                item.kind = result.get("kind", item.kind)
            items.append(item)
        result = cls(collection_id, collection["name"], collection.get("url", ""), expected_source,
                     items, accepted_at, reason, membership_digest(ids))
        result.validate()
        return result

    def write(self, path):
        self.validate()
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        data = dict(snapshotVersion=1, collectionId=self.collection_id, name=self.name, sourceURL=self.source_url,
                    provenance=self.provenance, media=[item.wire() for item in self.items])
        temporary = path.with_suffix(".json.tmp")
        temporary.write_text(json.dumps(data, ensure_ascii=False, allow_nan=False, indent=2), encoding="utf-8")
        temporary.replace(path)

    @classmethod
    def read(cls, path):
        data = json.loads(Path(path).read_text(encoding="utf-8"))
        if data.get("snapshotVersion") != 1 or data["provenance"]["kind"] != "acceptedSnapshot":
            raise ValueError("Unsupported import snapshot")
        p = data["provenance"]
        result = cls(data["collectionId"], data["name"], data["sourceURL"], p["sourceAdvertisedCount"],
                     [MediaItem.decode(item) for item in data["media"]], p["acceptedAt"], p["reason"], p["membershipSHA256"])
        result.validate()
        if result.provenance != p:
            raise ValueError("Snapshot provenance counts do not match its membership")
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--measurements", type=Path)
    parser.add_argument("--playlist-id", required=True)
    parser.add_argument("--accept-observed-count", type=int, required=True)
    parser.add_argument("--source-count", type=int, required=True)
    parser.add_argument("--accepted-at", required=True)
    parser.add_argument("--reason", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--database", type=Path)
    args = parser.parse_args()
    accepted = AcceptedSnapshot.from_checkpoint(json.loads(args.checkpoint.read_text(encoding="utf-8")), args.playlist_id,
        expected_observed=args.accept_observed_count, expected_source=args.source_count,
        accepted_at=args.accepted_at, reason=args.reason,
        measurements=json.loads(args.measurements.read_text(encoding="utf-8")) if args.measurements else None)
    accepted.write(args.output)
    if args.database:
        from .store import LibraryStore
        store = LibraryStore(args.database)
        try:
            store.install_snapshot(accepted)
        finally:
            store.close()
    print(json.dumps(dict(playlistId=accepted.collection_id, name=accepted.name, **accepted.provenance)))


if __name__ == "__main__":
    main()
