"""Product polling on the helper's owner thread; no scheduled cloud jobs."""
from dataclasses import asdict
import re
import time
from .browser import Collection


class PlaylistWatcher:
    interval = 15 * 60
    setting_key = "playlist_watch_v1"

    def __init__(self, store, pipeline, *, clock=time.time, progress=lambda message: None, connect_cloud=None,
                 stopping=lambda: False):
        self.store, self.pipeline, self.clock, self.progress = store, pipeline, clock, progress
        self.connect_cloud = connect_cloud
        self.stopping = stopping
        self.running = False
        self.state = store.setting(self.setting_key, dict(version=1, enabled=False, collections=[], nextCheck=0,
            lastChecked=None, lastSuccess=None, lastError=None, failures=0, dirty=False))

    def _save(self):
        self.store.set_setting(self.setting_key, self.state)

    def configure(self, collections):
        selected = list({collection.id: collection for collection in collections}.values())
        saved = {playlist.id: playlist for playlist in self.store.playlists()}
        if not selected or any(collection.id not in saved or not saved[collection.id].item_ids for collection in selected):
            raise ValueError("Prepare an archived playlist before enabling automatic additions")
        self.state.update(enabled=True, collections=[asdict(c) for c in selected], nextCheck=self.clock(), failures=0, lastError=None)
        self._save()

    def pause(self):
        self.state["enabled"] = False
        self._save()

    @property
    def due(self):
        return self.state["enabled"] and not self.running and self.clock() >= self.state["nextCheck"]

    def check(self, *, force=False):
        if not self.state["enabled"] or self.running or not (force or self.due):
            return None
        self.running = True
        self.state["lastChecked"] = self.clock()
        self._save()
        try:
            collections = [Collection(**value) for value in self.state["collections"]]
            saved = {playlist.id: playlist for playlist in self.store.playlists()}
            proofs = [(c, self.pipeline.browser.additions(c, saved[c.id].item_ids)) for c in collections]
            new_count = sum(len(proof.items) for _, proof in proofs)
            if new_count:
                # Durable before any membership change: a crash must retry publication.
                self.state["dirty"] = True
                self._save()
            for collection, proof in proofs:
                self.store.merge_additions(collection.id, proof)
            ids = list(dict.fromkeys(key for c in collections for key in next(p for p in self.store.playlists() if p.id == c.id).item_ids))
            pending = [item for key in ids if (item := self.store.item(key)).status == "pending" and not item.asset]
            if pending:
                self.pipeline._prepare_items(pending, retry_failures=True)
                if any(self.store.verified_local(item.id) for item in pending):
                    self.state["dirty"] = True
                    self._save()
            if self.state["dirty"]:
                if self.connect_cloud:
                    self.pipeline.graph = self.connect_cloud()
                self.pipeline.sync([c.id for c in collections])
                self.state["dirty"] = False
            waiting = sum(not self.store.item(item.id).asset for item in pending)
            self.state.update(lastSuccess=self.clock(), lastError=f"{waiting} video(s) waiting for a download retry" if waiting else None,
                              failures=0, nextCheck=self.clock() + self.interval)
            self.progress(f"Automatic check: {new_count} new video(s); " + (f"{waiting} will retry. " if waiting else "") + "Next check in 15 minutes.")
            return new_count
        except InterruptedError:
            if self.stopping():
                self.state.update(nextCheck=self.clock(), lastError="Helper stopped; completed progress is retained.")
            else:
                self.state.update(enabled=False, lastError="Automatic checks paused; completed progress is retained.")
            self.progress(self.state["lastError"])
        except Exception as error:
            failures = self.state["failures"] + 1
            self.state.update(lastError=re.sub(r"https?://\S+", "[service URL]", str(error))[:700], failures=failures,
                              nextCheck=self.clock() + min(3600, self.interval * 2 ** min(failures - 1, 2)))
            self.progress("Automatic check will retry: " + self.state["lastError"])
        finally:
            self.running = False
            self._save()
