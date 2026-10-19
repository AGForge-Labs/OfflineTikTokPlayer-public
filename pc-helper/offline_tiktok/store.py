import hashlib
import json
from pathlib import Path
import sqlite3
import uuid
from .catalog import Catalog, MediaItem, Playlist


def checksum(path: Path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


class LibraryStore:
    """Durable job checkpoints; each worker owns its database connection."""

    def __init__(self, path):
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path)
        self.db.row_factory = sqlite3.Row
        self.db.executescript("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS settings (name TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS media (id TEXT PRIMARY KEY, data TEXT NOT NULL,
                local_data TEXT, remote_data TEXT, last_error TEXT);
            CREATE TABLE IF NOT EXISTS playlists (id TEXT PRIMARY KEY, name TEXT NOT NULL, items TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS uploads (digest TEXT PRIMARY KEY, url TEXT NOT NULL,
                offset INTEGER NOT NULL, expires_at TEXT NOT NULL, target TEXT);
        """)
        with self.db:
            # Unscoped pre-release sessions are retained but never reused by GraphClient.
            if "target" not in {row[1] for row in self.db.execute("PRAGMA table_info(uploads)")}:
                self.db.execute("ALTER TABLE uploads ADD COLUMN target TEXT")
            self.db.execute("INSERT OR IGNORE INTO settings VALUES ('library_id', ?)", (str(uuid.uuid4()),))

    def close(self):
        self.db.close()

    def setting(self, name, default=None):
        row = self.db.execute("SELECT value FROM settings WHERE name=?", (name,)).fetchone()
        return json.loads(row[0]) if row else default

    def set_setting(self, name, value):
        with self.db:
            self.db.execute("INSERT OR REPLACE INTO settings VALUES (?,?)", (name, json.dumps(value, allow_nan=False)))

    def merge_additions(self, playlist_id, proof):
        row = self.db.execute("SELECT items FROM playlists WHERE id=?", (playlist_id,)).fetchone()
        known = json.loads(row[0]) if row else []
        if tuple(known) != proof.known_ids:
            raise ValueError("Archived membership changed during the additions check")
        required = min(3, len(known))
        if not proof.anchors or len(proof.anchors) != required or proof.anchors[0] not in known:
            raise ValueError("Missing collection anchors")
        start = known.index(proof.anchors[0])
        if tuple(known[start:start + required]) != proof.anchors:
            raise ValueError("Collection anchor order changed")
        additions = list(dict.fromkeys(item.id for item in proof.items if item.id not in known))
        merged = additions + known
        with self.db:
            self.db.execute("UPDATE playlists SET items=? WHERE id=?", (json.dumps(merged), playlist_id))
            for item in proof.items:
                self.db.execute("INSERT OR IGNORE INTO media(id,data) VALUES (?,?)", (item.id, json.dumps(item.wire())))
            if self.snapshot_provenance(playlist_id):
                from .snapshot import membership_digest
                self.db.execute("INSERT OR REPLACE INTO settings VALUES (?,?)",
                                ("snapshot_extension_" + playlist_id, json.dumps(membership_digest(merged))))
        return additions

    def update_playlist(self, playlist_id, name, item_ids, *, complete):
        if not complete:
            raise ValueError("Refusing to replace membership after incomplete enumeration")
        unique = list(dict.fromkeys(item_ids))
        with self.db:
            self.db.execute("INSERT INTO playlists VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name, items=excluded.items",
                            (playlist_id, name, json.dumps(unique)))
            for item_id in unique:
                placeholder = MediaItem(item_id, f"TikTok {item_id}", status="pending")
                self.db.execute("INSERT OR IGNORE INTO media (id,data) VALUES (?,?)", (item_id, json.dumps(placeholder.wire())))

    def playlists(self):
        return [Playlist(row["id"], row["name"], json.loads(row["items"])) for row in self.db.execute("SELECT * FROM playlists ORDER BY rowid")]

    def install_snapshot(self, snapshot):
        snapshot.validate()
        row = self.db.execute("SELECT items FROM playlists WHERE id=?", (snapshot.collection_id,)).fetchone()
        if row and json.loads(row[0]) != snapshot.item_ids:
            from .snapshot import membership_digest
            existing = json.loads(row[0])
            if (self.snapshot_provenance(snapshot.collection_id) != snapshot.provenance
                    or existing[-len(snapshot.items):] != snapshot.item_ids
                    or self.setting("snapshot_extension_" + snapshot.collection_id) != membership_digest(existing)):
                raise ValueError("Refusing to replace existing membership with a smaller or different snapshot")
        with self.db:
            self.db.execute("INSERT INTO playlists VALUES (?,?,?) ON CONFLICT(id) DO NOTHING",
                            (snapshot.collection_id, snapshot.name, json.dumps(snapshot.item_ids)))
            for item in snapshot.items:
                # Reinstalling membership must preserve completed local/cloud assets.
                self.db.execute("INSERT INTO media(id,data) VALUES (?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data "
                                "WHERE media.local_data IS NULL AND media.remote_data IS NULL",
                                (item.id, json.dumps(item.wire())))
            self.db.execute("INSERT OR REPLACE INTO settings VALUES (?,?)",
                            ("accepted_snapshot_" + snapshot.collection_id, json.dumps(snapshot.provenance)))

    def snapshot_provenance(self, playlist_id):
        row = self.db.execute("SELECT value FROM settings WHERE name=?", ("accepted_snapshot_" + playlist_id,)).fetchone()
        return json.loads(row[0]) if row else None

    def save_local(self, item, original, playback, artwork=None):
        original, playback = Path(original).resolve(), Path(playback).resolve()
        record = dict(original=str(original), playback=str(playback), sha256=checksum(playback),
                      original_sha256=checksum(original), byte_size=playback.stat().st_size,
                      artwork=str(Path(artwork).resolve()) if artwork else None)
        with self.db:
            self.db.execute("INSERT INTO media (id,data,local_data) VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data,local_data=excluded.local_data,remote_data=NULL,last_error=NULL",
                            (item.id, json.dumps(item.wire()), json.dumps(record)))

    def local(self, item_id):
        row = self.db.execute("SELECT local_data FROM media WHERE id=?", (item_id,)).fetchone()
        return json.loads(row[0]) if row and row[0] else None

    def verified_local(self, item_id):
        record = self.local(item_id)
        if not record:
            return False
        try:
            return (checksum(Path(record["playback"])) == record["sha256"] and
                    checksum(Path(record["original"])) == record["original_sha256"])
        except OSError:
            return False

    def item(self, item_id):
        row = self.db.execute("SELECT data,remote_data FROM media WHERE id=?", (item_id,)).fetchone()
        return MediaItem.decode(json.loads(row["remote_data"] or row["data"])) if row else None

    def save_remote(self, item):
        encoded = json.dumps(item.wire())
        with self.db:
            self.db.execute("INSERT INTO media (id,data,remote_data) VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data,remote_data=excluded.remote_data,last_error=NULL",
                            (item.id, encoded, encoded))

    def replace_playback_copies(self, replacements):
        """Commit only after the new cloud catalog is published; preserve source originals."""
        with self.db:
            for media_id, replacement in replacements.items():
                row = self.db.execute("SELECT local_data FROM media WHERE id=?", (media_id,)).fetchone()
                if not row or not row[0]:
                    raise ValueError("Audio repair is missing its original local record")
                local = json.loads(row[0])
                local.update(playback=replacement["playback"], sha256=replacement["sha256"], byte_size=replacement["byte_size"])
                encoded = json.dumps(replacement["item"].wire())
                self.db.execute("UPDATE media SET data=?,remote_data=?,local_data=?,last_error=NULL WHERE id=?",
                                (encoded, encoded, json.dumps(local), media_id))

    def record_failure(self, item_id, reason):
        with self.db:
            self.db.execute("UPDATE media SET last_error=? WHERE id=?", (reason, item_id))

    def failure(self, item_id):
        row = self.db.execute("SELECT last_error FROM media WHERE id=?", (item_id,)).fetchone()
        return row[0] if row else None

    def catalog(self):
        library_id = self.db.execute("SELECT value FROM settings WHERE name='library_id'").fetchone()[0]
        rows = self.db.execute("SELECT data,remote_data FROM media ORDER BY rowid").fetchall()
        items = [MediaItem.decode(json.loads(row["remote_data"] or row["data"])) for row in rows]
        return Catalog(library_id, items, self.playlists())

    def save_upload(self, digest, url, offset, expires_at, *, target=None):
        with self.db:
            self.db.execute("INSERT OR REPLACE INTO uploads (digest,url,offset,expires_at,target) VALUES (?,?,?,?,?)",
                            (digest, url, offset, expires_at, target))

    def upload(self, digest):
        row = self.db.execute("SELECT * FROM uploads WHERE digest=?", (digest,)).fetchone()
        return dict(row) if row else None

    def clear_upload(self, digest):
        with self.db:
            self.db.execute("DELETE FROM uploads WHERE digest=?", (digest,))
