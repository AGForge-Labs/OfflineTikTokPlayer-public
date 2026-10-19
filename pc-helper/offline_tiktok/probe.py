"""Bounded live-media proof. Results explicitly separate source and native evidence."""
import argparse
import json
from pathlib import Path
from .auth import MicrosoftAuth
from .browser import post_from_link
from .catalog import Catalog, MediaItem, Playlist
from .graph import GraphClient
from .gui import data_directory
from .media import MediaDownloader, MediaTools
from .store import LibraryStore


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--video-url", required=True)
    parser.add_argument("--photo-url", required=True)
    parser.add_argument("--work-dir", type=Path, default=data_directory() / "proof")
    parser.add_argument("--client-id", help="Use an already connected Microsoft app registration")
    args = parser.parse_args()
    args.work_dir.mkdir(parents=True, exist_ok=True)
    report = {"passed": [], "pending": ["native AVPlayer playback", "physical iPhone acceptance", "TestFlight"], "media": []}
    store = LibraryStore(args.work_dir / "library.sqlite")
    downloader = MediaDownloader(args.work_dir / "media", progress=lambda text: print(text, flush=True))
    tools = MediaTools()
    graph = None
    try:
        for url, expected_kind in ((args.video_url, "video"), (args.photo_url, "slideshow")):
            item = post_from_link(url)
            if not item or item.kind != expected_kind:
                raise ValueError(f"Expected a TikTok {expected_kind} URL")
            acquired = downloader.acquire(item)
            item.duration = acquired.duration
            store.save_local(item, acquired.original, acquired.playback, acquired.artwork)
            details = tools.probe(acquired.playback)
            report["media"].append({"id": item.id, "kind": item.kind, **details, "originalBytes": acquired.original.stat().st_size,
                                    "playbackBytes": acquired.playback.stat().st_size})
            report["passed"].append(f"real TikTok {expected_kind} acquisition and local decoding")
        store.update_playlist("proof", "Import proof", [m["id"] for m in report["media"]], complete=True)
        if args.client_id:
            auth = MicrosoftAuth(args.client_id, data_directory())
            graph = GraphClient(auth.token, store)
            from .pipeline import ImportPipeline
            catalog = ImportPipeline(store, None, None, graph).sync(["proof"])
            for item in catalog.media:
                source = Path(store.local(item.id)["playback"])
                with source.open("rb") as stream:
                    stream.seek(32)
                    expected = stream.read(64)
                if graph.read_range(item.asset, 32, 95) != expected:
                    raise ValueError("Cloud media byte-range mismatch")
            report["passed"].append("real OneDrive uploads, catalog publication and matching seek byte ranges")
        else:
            report["pending"].append("OneDrive app registration/sign-in and live cloud upload")
        report["pending"].append("complete collection enumeration through the helper's persistent browser")
    except Exception as error:
        import re
        report["failed"] = re.sub(r"https?://\S+", "[source URL]", str(error))[:1200]
    finally:
        if graph:
            graph.close()
        store.close()
    (args.work_dir / "proof-result.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 1 if "failed" in report else 0


if __name__ == "__main__":
    raise SystemExit(main())
