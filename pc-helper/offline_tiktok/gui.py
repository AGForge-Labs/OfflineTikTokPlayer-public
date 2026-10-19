import json
import os
import argparse
from pathlib import Path
import queue
import threading
import time
import tkinter as tk
from tkinter import ttk, messagebox
from .auth import MicrosoftAuth
from .browser import TikTokBrowser
from .graph import GraphClient
from .media import MediaDownloader
from .pipeline import ImportPipeline
from .store import LibraryStore
from .watch import PlaylistWatcher
from .instance import HelperInstance


def data_directory():
    # Browser profiles, tokens and upload capability URLs must not be synced to OneDrive.
    return Path(os.environ.get("LOCALAPPDATA", str(Path.home() / ".local" / "share"))) / "OfflineTikTokPlayer"


def run_background_check(watch, browser):
    browser.set_background(True)
    try:
        return watch.check(force=True)
    finally:
        browser.park()


class HelperApp:
    def __init__(self, root, data_dir=None, *, instance=None):
        self.root = root
        self.instance = instance
        self.last_heartbeat = 0
        self.quitting = False
        self.data_dir = Path(data_dir or data_directory())
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self.config_path = self.data_dir / "settings.json"
        try:
            config = json.loads(self.config_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            config = {}
        self.client_id = tk.StringVar(value=config.get("clientId", ""))
        self.events = queue.Queue()
        self.commands = queue.Queue()
        self.cancelled = threading.Event()
        self.collections = {}
        self.snapshots = {}
        self.busy = False
        self.root.title("Offline TikTok Player — Windows Helper")
        self.root.geometry("1000x800")
        self.root.minsize(900, 680)
        self.status = tk.StringVar(value="Connect TikTok, select collections, prepare files, then upload to OneDrive.")
        self.watch_status = tk.StringVar(value="Automatic additions are paused.")
        self._layout()
        self.worker = threading.Thread(target=self._worker, daemon=True)
        self.worker.start()
        self.root.after(100, self._poll)
        self.root.protocol("WM_DELETE_WINDOW", self._close)

    def _layout(self):
        frame = ttk.Frame(self.root, padding=20)
        frame.pack(fill="both", expand=True)
        ttk.Label(frame, text="Your collections, saved for offline playback", font=("Segoe UI", 19, "bold")).pack(anchor="w")
        ttk.Label(frame, text="Keep your TikTok lists private. Original media stays in your private OneDrive app folder.").pack(anchor="w", pady=(5, 15))
        auth = ttk.LabelFrame(frame, text="Connections", padding=12)
        auth.pack(fill="x")
        self.buttons = []
        row = ttk.Frame(auth)
        row.pack(fill="x")
        self._button(row, "1. Open TikTok / Sign in", lambda: self._submit("open"))
        self._button(row, "2. Scan collections", lambda: self._submit("scan"))
        self._button(row, "Use accepted playlists", lambda: self._submit("snapshots"))
        self._button(row, "Authorize video checks", lambda: self._submit("audit_auth"))
        row = ttk.Frame(auth)
        row.pack(fill="x", pady=(10, 0))
        ttk.Label(row, text="Microsoft application ID").pack(side="left", padx=(0, 10))
        ttk.Entry(row, textvariable=self.client_id, width=41).pack(side="left", fill="x", expand=True)
        self._button(row, "Connect OneDrive", self._connect)
        ttk.Label(auth, text="The Microsoft ID comes from the app registration. No client secret is used.").pack(anchor="w", pady=(6, 0))
        lists = ttk.LabelFrame(frame, text="Select one or more collections", padding=8)
        lists.pack(fill="both", expand=True, pady=(15, 10))
        self.tree = ttk.Treeview(lists, columns=("count",), selectmode="extended")
        self.tree.heading("#0", text="Collection")
        self.tree.heading("count", text="Posts")
        self.tree.column("count", width=80, stretch=False, anchor="e")
        scroll = ttk.Scrollbar(lists, orient="vertical", command=self.tree.yview)
        self.tree.configure(yscrollcommand=scroll.set)
        self.tree.pack(side="left", fill="both", expand=True)
        scroll.pack(side="right", fill="y")
        actions = ttk.Frame(frame)
        actions.pack(fill="x")
        self._button(actions, "Select all", lambda: self.tree.selection_set(self.tree.get_children()))
        self._button(actions, "3. Prepare selected", lambda: self._selected("prepare"))
        self._button(actions, "4. Upload selected", lambda: self._selected("upload"))
        ttk.Button(actions, text="Pause work / checks", command=self._pause).pack(side="right", padx=5)
        watch = ttk.LabelFrame(frame, text="Automatic additions", padding=8)
        watch.pack(fill="x", pady=(12, 0))
        row = ttk.Frame(watch)
        row.pack(fill="x")
        self._button(row, "Check selected every 15 minutes", lambda: self._selected("watch_enable"))
        self._button(row, "Check now", lambda: self._submit("watch_check"))
        ttk.Label(watch, textvariable=self.watch_status, wraplength=900).pack(anchor="w", pady=(6, 0))
        ttk.Label(watch, text="Checks run quietly while the PC is awake, even with this window closed. Reopen Start-Helper.ps1 to manage them.", wraplength=900).pack(anchor="w")
        controls = ttk.Frame(frame)
        controls.pack(fill="x", pady=(8, 0))
        ttk.Button(controls, text="Run in background", command=self._close).pack(side="left")
        ttk.Button(controls, text="Exit helper", command=self._quit).pack(side="right")
        ttk.Label(frame, textvariable=self.status, wraplength=890).pack(fill="x", pady=(12, 5))
        self.log = tk.Text(frame, height=7, wrap="word", state="disabled", font=("Segoe UI", 10))
        self.log.pack(fill="x")

    def _button(self, parent, label, command):
        button = ttk.Button(parent, text=label, command=command)
        button.pack(side="left", padx=(0, 8))
        self.buttons.append(button)

    def _submit(self, action, argument=None):
        if self.busy:
            return
        self.busy = True
        self.cancelled.clear()
        for button in self.buttons:
            button.configure(state="disabled")
        self.commands.put((action, argument))

    def _connect(self):
        client_id = self.client_id.get().strip()
        try:
            config = json.loads(self.config_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            config = {}
        config["clientId"] = client_id
        self.config_path.write_text(json.dumps(config), encoding="utf-8")
        self._submit("connect", client_id)

    def _pause(self):
        self.cancelled.set()
        self.commands.put(("watch_pause", None))

    def _selected(self, action):
        selected = [self.collections[key] for key in self.tree.selection()]
        if not selected:
            messagebox.showinfo("Select collections", "Select the collections you want to prepare or upload.")
            return
        self._submit(action, selected)

    def _progress(self, message):
        self.events.put(("progress", message))

    def _worker(self):
        store = LibraryStore(self.data_dir / "library.sqlite")
        browser = TikTokBrowser(self.data_dir / "tiktok-browser", self._progress, self.cancelled.is_set, background=True)
        downloader = MediaDownloader(self.data_dir / "media", self._progress, self.cancelled.is_set)
        graph = None
        def saved_cloud():
            nonlocal graph
            if graph is None:
                config = json.loads(self.config_path.read_text(encoding="utf-8"))
                auth = MicrosoftAuth(config.get("clientId", ""), self.data_dir, progress=self._progress, cancelled=self.cancelled.is_set)
                auth.token()  # Silent only. Automatic checks never start device sign-in.
                graph = GraphClient(auth.token, store, progress=self._progress, cancelled=self.cancelled.is_set)
            return graph
        pipeline = ImportPipeline(store, browser, downloader, progress=self._progress, cancelled=self.cancelled.is_set)
        watch = PlaylistWatcher(store, pipeline, progress=self._progress, connect_cloud=saved_cloud,
                                stopping=lambda: self.quitting)
        interactive_browser = False
        self.events.put(("watch", dict(watch.state)))
        if watch.state["collections"]:
            from .browser import Collection
            self.events.put(("collections", [Collection(**value) for value in watch.state["collections"]]))
            self.events.put(("selection", [value["id"] for value in watch.state["collections"]]))
        try:
            while True:
                try:
                    action, argument = self.commands.get(timeout=1)
                except queue.Empty:
                    if not watch.due or self.cancelled.is_set() or interactive_browser:
                        continue
                    action, argument = "watch_check", None
                if action == "close":
                    break
                self.events.put(("busy", None))
                try:
                    if action == "open":
                        interactive_browser = True
                        browser.set_background(False)
                        browser.open()
                        self._progress("Sign in in the helper's Edge window, then choose Scan collections.")
                    elif action == "background":
                        browser.set_background(True)
                        browser.park()
                        interactive_browser = False
                    elif action == "scan":
                        self.events.put(("snapshots", {}))
                        self.events.put(("collections", browser.collections()))
                    elif action == "snapshots":
                        from .snapshot import AcceptedSnapshot
                        from .browser import Collection
                        snapshots = [AcceptedSnapshot.read(path) for path in sorted((self.data_dir / "accepted-snapshots").glob("*.json"))]
                        for snapshot in snapshots:
                            store.install_snapshot(snapshot)
                        self.events.put(("snapshots", {snapshot.collection_id: snapshot for snapshot in snapshots}))
                        self.events.put(("collections", [Collection(s.collection_id, s.name, s.source_url, len(s.items)) for s in snapshots]))
                        self._progress(f"Loaded {len(snapshots)} explicitly accepted playlist snapshots. Preparation preserves their recorded membership.")
                    elif action == "audit_auth":
                        from .audit_auth import save_session
                        save_session(self.data_dir / "cost-audit" / "tiktok-session.bin", browser.cookies())
                        self._progress("Video checks authorized for four hours. The helper's own TikTok session stays encrypted on this PC.")
                    elif action == "connect":
                        auth = MicrosoftAuth(argument, self.data_dir, progress=self._progress, cancelled=self.cancelled.is_set)
                        auth.connect()
                        if graph:
                            graph.close()
                        graph = GraphClient(auth.token, store, progress=self._progress, cancelled=self.cancelled.is_set)
                        graph.app_folder()
                        quota = graph.quota()
                        self._progress(f"OneDrive connected: {quota['remaining'] / 1073741824:.2f} GiB available" if quota and "remaining" in quota
                                       else "OneDrive connected; the service will enforce available capacity.")
                    elif action == "prepare":
                        pipeline = ImportPipeline(store, browser, downloader, graph, progress=self._progress, cancelled=self.cancelled.is_set)
                        for collection in argument:
                            accepted = self.snapshots.get(collection.id)
                            if accepted:
                                pipeline.prepare_snapshot(accepted)
                            else:
                                pipeline.prepare([collection])
                        self._progress("Preparation finished. Unavailable posts are recorded; complete originals are retained.")
                    elif action == "upload":
                        ImportPipeline(store, browser, downloader, graph, progress=self._progress, cancelled=self.cancelled.is_set).sync([c.id for c in argument])
                    elif action == "watch_enable":
                        watch.configure(argument)
                        self._progress("Automatic additions enabled for the selected playlists; checking now.")
                        interactive_browser = False
                        run_background_check(watch, browser)
                    elif action == "watch_check":
                        if not watch.state["enabled"]:
                            raise ValueError("Select an archived playlist and enable 15-minute checks first.")
                        interactive_browser = False
                        run_background_check(watch, browser)
                    elif action == "watch_pause":
                        watch.pause()
                        self._progress("Work and automatic checks paused. Completed progress is retained.")
                except Exception as error:
                    self.events.put(("error", str(error)))
                finally:
                    if action in ("scan", "audit_auth", "prepare"):
                        interactive_browser = False
                        try:
                            browser.set_background(True)
                            browser.park()
                        except Exception as error:
                            self.events.put(("error", str(error)))
                    self.events.put(("watch", dict(watch.state)))
                    self.events.put(("done", None))
        finally:
            browser.close()
            if graph:
                graph.close()
            store.close()

    def _poll(self):
        if self.instance:
            for command in self.instance.receive():
                if command == "show":
                    self.root.deiconify(); self.root.lift()
                elif command == "hide":
                    self._close()
                elif command == "pause":
                    self._pause()
                elif command == "check":
                    self._submit("watch_check")
                elif command == "quit":
                    self._quit()
            if time.monotonic() - self.last_heartbeat >= 5:
                try:
                    self.instance.report(visible=self.root.state() != "withdrawn", busy=self.busy)
                except OSError:
                    pass  # A reader briefly holding this file must not stop Tk's control loop.
                self.last_heartbeat = time.monotonic()
        if self.quitting:
            return
        while not self.events.empty():
            kind, value = self.events.get_nowait()
            if kind == "snapshots":
                self.snapshots = value
            elif kind == "collections":
                self.tree.delete(*self.tree.get_children())
                self.collections = {collection.id: collection for collection in value}
                for collection in value:
                    self.tree.insert("", "end", iid=collection.id, text=collection.name, values=(collection.count if collection.count is not None else "—",))
                self.status.set(f"Found {len(value)} collections. Select the ones to save.")
            elif kind == "selection":
                self.tree.selection_set([key for key in value if self.tree.exists(key)])
            elif kind == "watch":
                from datetime import datetime
                names = ", ".join(c["name"] for c in value["collections"])
                if value["enabled"]:
                    due = datetime.fromtimestamp(value["nextCheck"]).strftime("%I:%M %p")
                    detail = f"Every 15 minutes: {names}. Next check: {due}."
                else:
                    detail = "Automatic additions paused." + (f" Saved selection: {names}." if names else "")
                if value["lastSuccess"]:
                    detail += " Last completed: " + datetime.fromtimestamp(value["lastSuccess"]).strftime("%b %d %I:%M %p") + "."
                if value["lastError"]:
                    detail += " " + value["lastError"]
                self.watch_status.set(detail)
            elif kind == "busy":
                self.busy = True
                for button in self.buttons:
                    button.configure(state="disabled")
            elif kind in ("progress", "error"):
                self.status.set(value)
                self.log.configure(state="normal")
                self.log.insert("end", value + "\n")
                if int(self.log.index("end-1c").split(".")[0]) > 300:
                    self.log.delete("1.0", "100.0")
                self.log.see("end")
                self.log.configure(state="disabled")
            elif kind == "done":
                self.busy = False
                for button in self.buttons:
                    button.configure(state="normal")
        self.root.after(100, self._poll)

    def _close(self):
        self.commands.put(("background", None))
        self.root.withdraw()

    def _quit(self):
        self.quitting = True
        self.cancelled.set()
        self.commands.put(("close", None))
        self.root.withdraw()
        self.root.quit()

    def shutdown(self):
        if not self.quitting:
            self.quitting = True
            self.cancelled.set()
            self.commands.put(("close", None))
        self.worker.join()


def main(argv=None, *, data_dir=None):
    parser = argparse.ArgumentParser(description="Private player helper and quiet background checker")
    mode = parser.add_mutually_exclusive_group()
    for command in ("background", "show", "pause", "check", "quit"):
        mode.add_argument("--" + command, action="store_true")
    args = parser.parse_args(argv)
    directory = Path(data_dir or data_directory())
    instance = HelperInstance(directory)
    if not instance.acquire():
        command = next((name for name in ("pause", "check", "quit") if getattr(args, name)), None)
        if command or not args.background:
            if not instance.send(command or "show"):
                raise RuntimeError("The running helper is still starting. Try opening it again shortly.")
        return
    root = None
    try:
        if args.quit:
            return
        if args.pause:
            store = LibraryStore(directory / "library.sqlite")
            try:
                PlaylistWatcher(store, None).pause()
            finally:
                store.close()
            return
        root = tk.Tk()
        if args.background or args.check:
            root.withdraw()
        app = HelperApp(root, directory, instance=instance)
        if args.check:
            instance.send("check")
        try:
            root.mainloop()
        finally:
            app.shutdown()
    finally:
        if root:
            root.destroy()
        instance.close()


if __name__ == "__main__":
    main()
