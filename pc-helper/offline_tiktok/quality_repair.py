"""Upgrade archived posts transactionally, retaining originals and unavailable sources."""
from concurrent.futures import ThreadPoolExecutor, wait, FIRST_COMPLETED
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import shutil
from .audio_repair import AudioRepair
from .graph import StorageFull
from .source_quality import QUALITY_VERSION, combine_tracks, matching_audio, video_score
from .store import checksum


def _audio_score(info):
    if not info.get("audio_codec"):
        return (-1, 0, 0)
    # Small container-duration differences are not a recovered source-quality gain.
    return (info.get("audio_channels", 0), int(info["audio_codec"] in ("alac", "flac", "pcm_s16le", "pcm_s24le")),
            round(info.get("audio_bitrate", 0) / 8000))


def _better_picture(old, new):
    if (min(old["width"], old["height"], new["width"], new["height"]) <= 0
            or abs((new["width"] / new["height"]) / (old["width"] / old["height"]) - 1) > .01
            or new.get("fps", 0) < old.get("fps", 0) - .05
            or new["width"] < old["width"] or new["height"] < old["height"]):
        return False
    if video_score(new)[:3] > video_score(old)[:3]:
        return True
    return new.get("video_bitrate", 0) > old.get("video_bitrate", 0) * 1.05 + 1000


class QualityRepair(AudioRepair):
    backup_name = "quality-repair-previous-catalog.json"

    def __init__(self, store, tools, state_path, *, downloader, **kwargs):
        super().__init__(store, tools, state_path, **kwargs)
        if self.state.get("kind", "source-quality") != "source-quality":
            raise ValueError("This checkpoint belongs to a different repair")
        self.state.update(kind="source-quality", qualityVersion=QUALITY_VERSION)
        self.state.setdefault("checked", {})
        self.state.setdefault("issues", {})
        self.downloader = downloader

    def _replacement_path(self, old):
        return old.with_name(old.stem + f".quality-v{QUALITY_VERSION}.mp4")

    def _check(self):
        if self.cancelled():
            raise InterruptedError("Source-quality repair paused; published files and checkpoints are retained")

    def _prepare_one(self, item, local, cookies):
        self._check()
        old = Path(local["playback"]).resolve()
        if checksum(old) != item.asset.sha256 or local["sha256"] != item.asset.sha256:
            raise ValueError("Archived playback changed before source-quality repair")
        original_info = self.tools.probe(old)
        audio_reference, source_info = old, original_info
        if original_info.get("audio_codec") in (None, "alac", "flac", "pcm_s16le", "pcm_s24le"):
            source_path = Path(local["original"]).resolve()
            if source_path != old:
                if checksum(source_path) != local["original_sha256"]:
                    raise ValueError("Retained source changed; cannot verify its original audio quality")
                source_info = self.tools.probe(source_path)
                if source_info.get("audio_codec"):
                    audio_reference = source_path
        acquired = self.downloader.acquire(item, cookies)
        candidate = Path(acquired.playback).resolve()
        new_info = self.tools.probe(candidate)
        self._check()
        if abs(original_info["duration"] - new_info["duration"]) > .2:
            raise ValueError("The current post has a different duration; retained the archived version")
        improve_picture = _better_picture(original_info, new_info)
        improve_audio = (_audio_score(new_info) > _audio_score(source_info)
                         or bool(not original_info.get("audio_codec") and source_info.get("audio_codec") and new_info.get("audio_codec")))
        picture = candidate if improve_picture else old
        audio = candidate if improve_audio else old
        if not improve_audio and not improve_picture:
            return None
        # Match against the archived post even if both new tracks would win.
        # Same post ID/duration alone cannot prove an unchanged soundtrack.
        if new_info.get("audio_codec"):
            if not source_info.get("audio_codec"):
                raise ValueError("No retained audio reference can verify this post's current soundtrack")
            if candidate != audio_reference:
                matching_audio(audio_reference, candidate, original_info["duration"], ffmpeg=self.tools.ffmpeg)
        if not self.tools.probe(audio).get("audio_codec"):
            audio = None
        replacement = self._replacement_path(old)
        required = sum(path.stat().st_size for path in {picture, audio} if path)
        if shutil.disk_usage(old.parent).free < 2 * 1073741824 + required:
            raise StorageFull("Source-quality repair needs space for a verified copy plus a 2 GiB reserve")
        assembly = combine_tracks(picture, audio, replacement, self.tools, check=self._check)
        self._check()
        if checksum(old) != item.asset.sha256:
            raise ValueError("Archived playback changed during source-quality repair")
        proof_path = Path(acquired.original).with_name("quality.json")
        proof = json.loads(proof_path.read_text(encoding="utf-8")) if proof_path.is_file() else None
        return dict(oldPlayback=str(old), oldAsset=item.asset.wire(), playback=str(replacement),
                    sha256=checksum(replacement), byteSize=replacement.stat().st_size, uploadedAsset=None,
                    improvedPicture=improve_picture, improvedAudio=improve_audio,
                    previous=original_info, previousSource=source_info,
                    current=self.tools.probe(replacement), sourceEvidence=proof, **assembly)

    def prepare(self, media_ids=None, *, cookies=(), workers=2, limit=None):
        """Bound downloads; only the owner thread touches SQLite or the checkpoint."""
        self._check()
        if not 1 <= workers <= 4 or (limit is not None and limit < 1):
            raise ValueError("Use 1-4 quality workers and a positive batch limit")
        selected = set(media_ids) if media_ids is not None else None
        todo = []
        for item in self.store.catalog().media:
            if selected is not None and item.id not in selected:
                continue
            if item.id in self.state["items"]:
                self._verified(item.id, self.state["items"][item.id])
                continue
            local = self.store.local(item.id)
            if item.kind != "video" or item.status != "ready" or not item.asset or not local:
                continue
            checked = self.state["checked"].get(item.id)
            if checked and checked["sha256"] == item.asset.sha256:
                continue
            todo.append((item, local))
            if limit is not None and len(todo) == limit:
                break
        iterator = iter(todo)
        with ThreadPoolExecutor(max_workers=workers, thread_name_prefix="source-quality") as pool:
            active = {}
            def submit():
                value = next(iterator, None)
                if value is not None:
                    item, local = value
                    active[pool.submit(self._prepare_one, item, local, cookies)] = item
            for _ in range(workers): submit()
            while active:
                self._check()
                done, _ = wait(active, timeout=1, return_when=FIRST_COMPLETED)
                for future in done:
                    item = active.pop(future)
                    try:
                        entry = future.result()
                        self._check()
                        if not self.store.item(item.id).asset or self.store.item(item.id).asset.sha256 != item.asset.sha256:
                            raise ValueError("Archived asset changed during preparation; retry against the new catalog")
                        if entry:
                            self.state["items"][item.id] = entry
                            self._verified(item.id, entry)
                        self.state["checked"][item.id] = dict(sha256=item.asset.sha256, improved=bool(entry),
                            checkedAt=datetime.now(timezone.utc).isoformat())
                        self.state["issues"].pop(item.id, None)
                    except (InterruptedError, StorageFull):
                        raise
                    except Exception as error:
                        reason = re.sub(r"https?://\S+", "[source URL]", str(error))[:400]
                        self.state["issues"][item.id] = dict(reason=reason, errorType=type(error).__name__,
                            checkedAt=datetime.now(timezone.utc).isoformat())
                    self._save()
                    self.progress(f"Quality checked {len(self.state['checked'])}; prepared {len(self.state['items'])}; "
                                  f"retry needed {len(self.state['issues'])}: {item.id}")
                    submit()
        return sum(self.store.item(media_id).asset.sha256 != entry["sha256"]
                   for media_id, entry in self.state["items"].items())


def main():
    import argparse
    from .audit_auth import load_session
    from .auth import MicrosoftAuth
    from .graph import GraphClient
    from .gui import data_directory
    from .instance import HelperInstance
    from .media import MediaDownloader, MediaTools
    from .store import LibraryStore
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path, default=data_directory())
    parser.add_argument("--media-id", action="append")
    parser.add_argument("--workers", type=int, default=2)
    parser.add_argument("--limit", type=int)
    parser.add_argument("--publish", action="store_true")
    args = parser.parse_args()
    owner, graph, store = None, None, None
    job = HelperInstance(args.data_dir / "quality-repair-v1" / "job")
    try:
        if not job.acquire():
            raise RuntimeError("A source-quality repair is already running; its checkpoints are retained")
        if args.publish:
            owner = HelperInstance(args.data_dir)
            if not owner.acquire():
                raise RuntimeError("Exit the helper before publishing quality replacements; its saved schedule will resume on relaunch")
            owner.report(visible=False, busy=True)
        store = LibraryStore(args.data_dir / "library.sqlite")
        tools = MediaTools()
        if args.publish:
            config = json.loads((args.data_dir / "settings.json").read_text(encoding="utf-8"))
            auth = MicrosoftAuth(config["clientId"], args.data_dir)
            graph = GraphClient(auth.token, store, progress=print)
        downloader = MediaDownloader(args.data_dir / "quality-repair-v1" / "staging", tools=tools)
        repair = QualityRepair(store, tools, args.data_dir / "quality-repair-v1.json",
                               downloader=downloader, graph=graph, progress=lambda message:print(message, flush=True))
        count = repair.prepare(args.media_id, workers=args.workers, limit=args.limit,
                               cookies=load_session(args.data_dir / "cost-audit" / "tiktok-session.bin"))
        print(f"Verified source-quality copies pending publication: {count}", flush=True)
        if args.publish: repair.sync()
    finally:
        if graph: graph.close()
        if store: store.close()
        if owner: owner.close()
        job.close()


if __name__ == "__main__":
    main()
