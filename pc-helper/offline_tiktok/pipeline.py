from pathlib import Path
import re
from concurrent.futures import ThreadPoolExecutor, as_completed
from .graph import StorageFull
from .store import checksum


class ImportPipeline:
    def __init__(self, store, browser, downloader, graph=None, *, progress=lambda message: None, cancelled=lambda: False,
                 workers=1, cancel_work=lambda: None):
        self.store, self.browser, self.downloader, self.graph = store, browser, downloader, graph
        self.progress, self.cancelled = progress, cancelled
        if not 1 <= workers <= 4:
            raise ValueError("Use one to four bounded download workers")
        self.workers, self.cancel_work = workers, cancel_work

    def _check(self):
        if self.cancelled():
            raise InterruptedError("Paused. Completed progress is retained.")

    def prepare(self, selected):
        discovered = {}
        for collection in selected:
            self._check()
            items = self.browser.items(collection)
            self.store.update_playlist(collection.id, collection.name, [item.id for item in items], complete=True)
            for item in items:
                discovered.setdefault(item.id, item)
        return self._prepare_items(list(discovered.values()))

    def prepare_snapshot(self, snapshot):
        self._check()
        self.store.install_snapshot(snapshot)
        return self._prepare_items(snapshot.items)

    def _prepare_items(self, items, *, retry_failures=False):
        pending = []
        for index, item in enumerate(items, 1):
            self._check()
            previous = self.store.item(item.id)
            if (previous and previous.asset) or self.store.verified_local(item.id):
                self.progress(f"{index}/{len(items)}: using archived {item.id}")
                continue
            if item.status == "unavailable":
                self.progress(f"{index}/{len(items)}: retaining unavailable entry {item.id}")
                continue
            pending.append((index, item))
        if not pending:
            return self.store.catalog()
        cookies = self.browser.cookies()
        def complete(index, item, result=None, error=None):
            if error is not None:
                reason = re.sub(r"https?://\S+", "[source URL]", str(error))[:700]
                item.status = "pending" if retry_failures else "unavailable"
                self.store.save_remote(item)
                self.store.record_failure(item.id, reason)
                self.progress(f"{index}/{len(items)}: {'will retry' if retry_failures else 'unavailable'} {item.id}; {reason}")
            else:
                item.duration = result.duration
                self.store.save_local(item, result.original, result.playback, result.artwork)
                self.progress(f"{index}/{len(items)}: prepared {item.id}")
        if self.workers == 1:
            for index, item in pending:
                self._check()
                try:
                    result = self.downloader.acquire(item, cookies)
                except InterruptedError:
                    raise
                except Exception as error:
                    complete(index, item, error=error)
                else:
                    complete(index, item, result=result)
            return self.store.catalog()
        pool = ThreadPoolExecutor(max_workers=self.workers, thread_name_prefix="media-import")
        futures = {pool.submit(self.downloader.acquire, item, cookies): (index, item) for index, item in pending}
        try:
            for future in as_completed(futures):
                self._check()
                index, item = futures[future]
                try:
                    result = future.result()
                except InterruptedError:
                    raise
                except Exception as error:
                    complete(index, item, error=error)
                else:
                    complete(index, item, result=result)
        except BaseException:
            self.cancel_work()
            for future in futures: future.cancel()
            raise
        finally:
            pool.shutdown(wait=True, cancel_futures=True)
        return self.store.catalog()

    def sync(self, playlist_ids):
        if not self.graph:
            raise RuntimeError("Connect OneDrive before uploading")
        drive_id, root_id = self.graph.app_folder()
        catalog = self.store.catalog()
        for item in catalog.media:
            for ref in (item.asset, item.original, item.artwork):
                if ref and ref.drive_id != drive_id:
                    raise ValueError("This library belongs to a different OneDrive. Use its original account or start a separate local library.")
        selected = set(playlist_ids)
        item_ids = list(dict.fromkeys(item_id for playlist in catalog.playlists if playlist.id in selected for item_id in playlist.item_ids))
        required = 0
        for item_id in item_ids:
            item = self.store.item(item_id)
            local = self.store.local(item_id)
            if item.asset or not local:
                continue
            required += sum(Path(path).stat().st_size for path in {local["original"], local["playback"], local["artwork"]} if path)
        quota = self.graph.quota()
        if quota and quota.get("remaining", required) < required:
            raise StorageFull(f"OneDrive needs {required / 1073741824:.2f} GiB more for these files; select fewer collections or add capacity.")
        self.progress(f"Prepared upload: {required / 1073741824:.2f} GiB; originals are retained")
        media_root = self.graph.folder("media", drive_id, root_id)
        artwork_root = self.graph.folder("artwork", drive_id, root_id)
        for index, item_id in enumerate(item_ids, 1):
            self._check()
            item = self.store.item(item_id)
            if item.asset:
                continue
            local = self.store.local(item_id)
            if not local:
                continue
            if not self.store.verified_local(item_id):
                raise ValueError(f"Local file {item_id} changed; prepare the collection again before uploading")
            original, playback = Path(local["original"]), Path(local["playback"])
            item.original = self.graph.upload_file(original, checksum(original) + original.suffix, drive_id, media_root)
            item.asset = item.original if original == playback else self.graph.upload_file(playback, checksum(playback) + playback.suffix, drive_id, media_root)
            if local["artwork"]:
                artwork = Path(local["artwork"])
                item.artwork = self.graph.upload_file(artwork, checksum(artwork) + artwork.suffix, drive_id, artwork_root)
            item.status = "ready"
            self.store.save_remote(item)
            self.progress(f"{index}/{len(item_ids)}: uploaded {item_id}")
        # Only publish once every attempted transfer in this run has completed.
        catalog = self.store.catalog()
        self.graph.publish(catalog, drive_id, root_id)
        self.progress("OneDrive catalog published with complete asset references")
        return catalog
