"""Resume an explicitly accepted playlist without requiring a fresh collection scan."""
import argparse
import json
import threading
from pathlib import Path
from .browser import TikTokBrowser
from .media import MediaDownloader, MediaTools, Acquisition
from .pipeline import ImportPipeline
from .snapshot import AcceptedSnapshot
from .store import LibraryStore


class CachedDownloader:
    def __init__(self, fallback, cache_root, measurements, *, tools=None):
        self.fallback = fallback
        self.cache_root = Path(cache_root)
        self.measurements = measurements.get("media", {})
        self.tools = tools or MediaTools()
        self._photo_lock = threading.Lock()

    def acquire(self, item, cookies):
        measurement = self.measurements.get(item.id, {})
        directory = self.cache_root / item.id
        if item.kind == "video":
            from .quality_download import digest
            from .source_quality import QUALITY_VERSION
            original = directory / "source-quality-v1" / "original.mp4"
            try:
                proof = json.loads(original.with_name("quality.json").read_text(encoding="utf-8"))
                if (proof.get("version") == QUALITY_VERSION and proof.get("postID") == item.id
                        and original.stat().st_size == proof.get("byteSize") and digest(original) == proof.get("sha256")):
                    playback = self.tools.compatible(original)
                    details = self.tools.probe(playback)
                    artwork = directory / "artwork.jpg"
                    if not artwork.exists(): self.tools.thumbnail(playback, artwork)
                    return Acquisition(original, playback, artwork, details["duration"])
            except (OSError, ValueError, RuntimeError):
                pass
            return self.fallback.acquire(item, cookies)
        originals = [path for path in directory.glob("original.*") if path.stem == "original" and path.suffix.lower() in (".mp4", ".mkv", ".mov", ".webm", ".m4v")]
        if item.kind == "slideshow": originals = [directory / "original-photo.zip"]
        for original in originals:
            playbacks = [directory / "slideshow.mp4"] if item.kind == "slideshow" else [original, original.with_name(original.stem + ".iphone.mp4")]
            for playback in playbacks:
                if (measurement.get("status") != "measured" or not original.is_file() or not playback.is_file()
                        or original.stat().st_size != measurement.get("originalBytes")
                        or playback.stat().st_size != measurement.get("playbackBytes")):
                    continue
                try:
                    details = self.tools.probe(playback)
                    if not details.get("video_codec"): continue
                    playback = self.tools.compatible(playback)
                    details = self.tools.probe(playback)
                    artwork = directory / "artwork.jpg"
                    if not artwork.exists(): self.tools.thumbnail(playback, artwork)
                    return Acquisition(original, playback, artwork, details["duration"])
                except (OSError, RuntimeError, ValueError):
                    continue
        if item.kind == "slideshow":
            with self._photo_lock: return self.fallback.acquire(item, cookies)
        return self.fallback.acquire(item, cookies)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path, required=True)
    parser.add_argument("--snapshot", type=Path, required=True)
    parser.add_argument("--reuse-media-root", type=Path)
    parser.add_argument("--measurements", type=Path)
    parser.add_argument("--workers", type=int, choices=range(1, 5), default=4)
    args = parser.parse_args()
    snapshot = AcceptedSnapshot.read(args.snapshot)
    paused = threading.Event()
    pause_file = args.data_dir / "archive.pause"
    def cancelled(): return paused.is_set() or pause_file.exists()
    def progress(message):
        if not message.startswith("Video "):
            print(message, flush=True)
    store = LibraryStore(args.data_dir / "library.sqlite")
    browser = TikTokBrowser(args.data_dir / "tiktok-browser", progress, cancelled)
    downloader = MediaDownloader(args.data_dir / "media", progress, cancelled)
    if args.reuse_media_root and args.measurements:
        downloader = CachedDownloader(downloader, args.reuse_media_root, json.loads(args.measurements.read_text(encoding="utf-8")))
    try:
        ImportPipeline(store, browser, downloader, progress=progress, cancelled=cancelled,
                       workers=args.workers, cancel_work=paused.set).prepare_snapshot(snapshot)
        local_count = sum(1 for item_id in snapshot.item_ids if store.local(item_id))
        unavailable = sum(1 for item_id in snapshot.item_ids if store.item(item_id).status == "unavailable")
        print(json.dumps(dict(playlistId=snapshot.collection_id, entries=len(snapshot.items),
                              localCheckpoints=local_count, unavailable=unavailable)), flush=True)
        return 0
    except InterruptedError as error:
        progress(str(error)); return 2
    finally:
        browser.close(); store.close()


if __name__ == "__main__":
    raise SystemExit(main())
