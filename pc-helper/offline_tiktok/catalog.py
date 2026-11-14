from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
import json
import math
import re


@dataclass
class AssetRef:
    drive_id: str
    item_id: str
    file_name: str
    byte_size: int
    sha256: str
    content_type: str

    def validate(self):
        if not self.drive_id or not self.item_id or self.byte_size <= 0:
            raise ValueError("Invalid asset identity or size")
        if not re.fullmatch(r"[a-f0-9]{64}", self.sha256):
            raise ValueError("Invalid asset checksum")
        if "/" in self.file_name or "\\" in self.file_name:
            raise ValueError("Asset filename must be a basename")

    def wire(self):
        return dict(driveId=self.drive_id, itemId=self.item_id, fileName=self.file_name,
                    byteSize=self.byte_size, sha256=self.sha256, contentType=self.content_type)

    @classmethod
    def decode(cls, data):
        return cls(data["driveId"], data["itemId"], data["fileName"], data["byteSize"], data["sha256"], data["contentType"])


@dataclass
class AudioLoudness:
    asset_sha256: str
    integrated_lufs: float
    true_peak_dbtp: float
    version: int = 1

    def validate(self):
        if type(self.version) is not int or self.version != 1:
            raise ValueError("Unsupported loudness measurement version")
        if not isinstance(self.asset_sha256, str) or not re.fullmatch(r"[a-f0-9]{64}", self.asset_sha256):
            raise ValueError("Loudness measurement needs its source checksum")
        for value, lower, upper in ((self.integrated_lufs, -70, 10), (self.true_peak_dbtp, -100, 20)):
            if type(value) not in (int, float) or not math.isfinite(value) or not lower <= value <= upper:
                raise ValueError("Invalid loudness measurement")

    def wire(self):
        self.validate()
        return dict(version=self.version, assetSHA256=self.asset_sha256,
                    integratedLUFS=self.integrated_lufs, truePeakDBTP=self.true_peak_dbtp)

    @classmethod
    def decode(cls, data):
        try:
            result = cls(data["assetSHA256"], data["integratedLUFS"], data["truePeakDBTP"], data["version"])
        except (KeyError, TypeError):
            raise ValueError("Incomplete loudness measurement") from None
        result.validate()
        return result


@dataclass(frozen=True)
class StreamEnhancement:
    source_sha256: str
    asset: AssetRef
    audio_mastered: bool
    version: int = 1

    def validate(self, source):
        self.asset.validate()
        if (type(self.version) is not int or self.version != 1 or type(self.audio_mastered) is not bool
                or not source or source.sha256 != self.source_sha256 or self.asset.drive_id != source.drive_id
                or self.asset.sha256 == source.sha256 or self.asset.content_type != "video/mp4"):
            raise ValueError("Enhanced playback is not bound to its archived source")

    def wire(self):
        return dict(version=self.version, sourceSHA256=self.source_sha256, asset=self.asset.wire(),
                    audioMastered=self.audio_mastered)

    @classmethod
    def decode(cls, data):
        return cls(data["sourceSHA256"], AssetRef.decode(data["asset"]), data["audioMastered"], data["version"])


@dataclass
class MediaItem:
    id: str
    title: str
    creator: str = ""
    source_url: str = ""
    duration: float = 0
    kind: str = "video"
    status: str = "ready"
    asset: AssetRef | None = None
    original: AssetRef | None = None
    artwork: AssetRef | None = None
    audio_loudness: AudioLoudness | None = None
    stream_enhancement: StreamEnhancement | None = None

    def wire(self):
        result = dict(id=self.id, title=self.title, creator=self.creator, sourceURL=self.source_url,
                    duration=self.duration, kind=self.kind, status=self.status,
                    asset=self.asset.wire() if self.asset else None,
                    original=self.original.wire() if self.original else None,
                    artwork=self.artwork.wire() if self.artwork else None)
        if self.audio_loudness is not None:
            result["audioLoudness"] = self.audio_loudness.wire()
        if self.stream_enhancement and self.asset and self.stream_enhancement.source_sha256 == self.asset.sha256:
            self.stream_enhancement.validate(self.asset)
            result["streamEnhancement"] = self.stream_enhancement.wire()
        return result

    @classmethod
    def decode(cls, data):
        return cls(data["id"], data["title"], data.get("creator", ""), data.get("sourceURL", ""),
                   data.get("duration", 0), data.get("kind", "video"), data.get("status", "ready"),
                   *[AssetRef.decode(data[key]) if data.get(key) else None for key in ("asset", "original", "artwork")],
                   AudioLoudness.decode(data["audioLoudness"]) if data.get("audioLoudness") is not None else None,
                   StreamEnhancement.decode(data["streamEnhancement"]) if data.get("streamEnhancement") is not None else None)


@dataclass
class Playlist:
    id: str
    name: str
    item_ids: list[str] = field(default_factory=list)

    def wire(self):
        return dict(id=self.id, name=self.name, itemIds=self.item_ids)


@dataclass
class Catalog:
    library_id: str
    media: list[MediaItem] = field(default_factory=list)
    playlists: list[Playlist] = field(default_factory=list)
    updated_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())

    def validate(self):
        if not self.library_id:
            raise ValueError("Missing library identity")
        ids = {item.id for item in self.media}
        if len(ids) != len(self.media) or "" in ids:
            raise ValueError("Duplicate or empty media identity")
        if len({p.id for p in self.playlists}) != len(self.playlists):
            raise ValueError("Duplicate playlist identity")
        for item in self.media:
            if item.kind not in ("video", "slideshow") or item.status not in ("ready", "unavailable", "pending"):
                raise ValueError("Invalid media kind/status")
            if not isinstance(item.duration, (int, float)) or not math.isfinite(item.duration) or item.duration < 0:
                raise ValueError("Invalid duration")
            if item.status == "ready" and item.asset is None:
                raise ValueError("Ready media is missing its uploaded asset")
            for ref in (item.asset, item.original, item.artwork):
                if ref:
                    ref.validate()
            if item.audio_loudness is not None:
                item.audio_loudness.validate()
            if item.stream_enhancement is not None:
                item.stream_enhancement.validate(item.asset)
        for playlist in self.playlists:
            if not playlist.id or len(set(playlist.item_ids)) != len(playlist.item_ids):
                raise ValueError("Invalid playlist identity or duplicate membership")
            if any(item_id not in ids for item_id in playlist.item_ids):
                raise ValueError("Playlist references missing media")

    def queue(self, playlist_ids):
        selected = set(playlist_ids)
        playable = {item.id for item in self.media if item.status == "ready" and item.asset}
        seen = set()
        result = []
        for playlist in self.playlists:
            if playlist.id not in selected:
                continue
            for item_id in playlist.item_ids:
                if item_id in playable and item_id not in seen:
                    seen.add(item_id)
                    result.append(item_id)
        return result

    def to_json(self):
        self.validate()
        return json.dumps(dict(schemaVersion=1, libraryId=self.library_id, updatedAt=self.updated_at,
                               media=[m.wire() for m in self.media], playlists=[p.wire() for p in self.playlists]),
                          ensure_ascii=False, allow_nan=False, separators=(",", ":"))

    @classmethod
    def from_json(cls, raw):
        data = json.loads(raw)
        if data.get("schemaVersion") != 1:
            raise ValueError("Unsupported catalog schema")
        result = cls(data["libraryId"], [MediaItem.decode(m) for m in data["media"]],
                     [Playlist(p["id"], p["name"], p["itemIds"]) for p in data["playlists"]], data.get("updatedAt", ""))
        result.validate()
        return result
