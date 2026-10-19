import json
from pathlib import Path
from types import SimpleNamespace
import pytest


def test_only_one_helper_can_own_the_runtime_and_commands_target_that_instance(tmp_path):
    from offline_tiktok.instance import HelperInstance
    first = HelperInstance(tmp_path)
    duplicate = HelperInstance(tmp_path)
    assert first.acquire()
    try:
        assert not duplicate.acquire()
        assert duplicate.send("show")
        assert duplicate.send("pause")
        assert first.receive() == ["show", "pause"]
        assert first.receive() == []
        with pytest.raises(ValueError): duplicate.send("run arbitrary code")
    finally:
        first.close()
    assert duplicate.acquire()
    duplicate.close()


def test_stale_and_invalid_commands_cannot_control_a_replacement_process(tmp_path):
    from offline_tiktok.instance import HelperInstance
    old = HelperInstance(tmp_path)
    assert old.acquire()
    assert old.send("quit")
    old.close()
    new = HelperInstance(tmp_path)
    assert new.acquire()
    try:
        (tmp_path / "helper-commands" / "broken.json").write_text("broken", encoding="utf-8")
        assert new.receive() == []
        assert new.send("check")
        assert new.receive() == ["check"]
    finally:
        new.close()


def test_runtime_lock_also_excludes_a_separate_process(tmp_path):
    import subprocess
    import sys
    from offline_tiktok.instance import HelperInstance
    owner = HelperInstance(tmp_path)
    assert owner.acquire()
    try:
        result = subprocess.run([sys.executable, "-c",
            "import sys; from offline_tiktok.instance import HelperInstance; i=HelperInstance(sys.argv[1]); print(i.acquire())",
            str(tmp_path)], capture_output=True, text=True, check=True)
        assert result.stdout.strip() == "False"
    finally:
        owner.close()


def test_a_temporarily_locked_health_file_does_not_stop_processing_control_commands():
    from offline_tiktok.gui import HelperApp
    import queue
    app = HelperApp.__new__(HelperApp)
    scheduled = []
    app.root = SimpleNamespace(state=lambda: "withdrawn", after=lambda *args: scheduled.append(args))
    def unavailable(**kwargs): raise PermissionError("health file momentarily open")
    app.instance = SimpleNamespace(receive=lambda: [], report=unavailable)
    app.last_heartbeat = 0
    app.busy = False
    app.quitting = False
    app.events = queue.Queue()
    app._poll()
    assert scheduled and scheduled[-1][0] == 100


def test_background_start_hides_window_before_constructing_helper_and_reopen_signals_owner(tmp_path, monkeypatch):
    from offline_tiktok import gui
    from offline_tiktok.instance import HelperInstance
    events = []
    class Root:
        def withdraw(self): events.append("hide")
        def mainloop(self): events.append("loop")
        def destroy(self): events.append("destroy")
    class App:
        def __init__(self, root, data_dir=None, instance=None): events.append("app")
        def shutdown(self): events.append("shutdown")
    monkeypatch.setattr(gui.tk, "Tk", Root)
    monkeypatch.setattr(gui, "HelperApp", App)
    gui.main(["--background"], data_dir=tmp_path)
    assert events[:2] == ["hide", "app"]
    events.clear()
    owner = HelperInstance(tmp_path)
    assert owner.acquire()
    try:
        gui.main(["--background"], data_dir=tmp_path)
        assert owner.receive() == []
        gui.main(["--show"], data_dir=tmp_path)
        assert owner.receive() == ["show"]
        assert events == []  # no second Tk root, browser or worker
    finally:
        owner.close()


def test_closing_helper_hides_it_without_cancelling_checks():
    from offline_tiktok.gui import HelperApp
    import queue
    import threading
    app = HelperApp.__new__(HelperApp)
    app.root = SimpleNamespace(withdraw=lambda: None)
    app.commands = queue.Queue()
    app.cancelled = threading.Event()
    app.instance = None
    app._close()
    assert not app.cancelled.is_set()
    assert app.commands.get_nowait() == ("background", None)


def test_automatic_check_uses_background_browser_and_parks_it_even_on_failure():
    from offline_tiktok.gui import run_background_check
    events = []
    browser = SimpleNamespace(set_background=lambda value: events.append(("background", value)),
                              park=lambda: events.append("park"))
    def check(**kwargs):
        events.append(("check", kwargs))
        raise RuntimeError("source failed")
    with pytest.raises(RuntimeError):
        run_background_check(SimpleNamespace(check=check), browser)
    assert events == [("background", True), ("check", {"force": True}), "park"]


def test_browser_stays_minimized_between_checks_and_restores_only_for_manual_sign_in(tmp_path, monkeypatch):
    from offline_tiktok.browser import TikTokBrowser
    import playwright.sync_api
    launches = []
    events = []
    class Page:
        url = "about:blank"
        def goto(self, url, **kwargs):
            self.url = url
            events.append(("goto", url))
        def is_closed(self): return False
    class Session:
        def send(self, method, params=None):
            if method == "Browser.getWindowForTarget": return {"windowId": 7}
            if method == "Browser.setWindowBounds": events.append(("state", params["bounds"]["windowState"]))
        def detach(self): pass
    class Context:
        pages = [Page()]
        closed = False
        def close(self): self.closed = True
        def new_cdp_session(self, page): return Session()
    class Chromium:
        def launch_persistent_context(self, profile, **kwargs):
            launches.append(kwargs)
            return Context()
    runtime = SimpleNamespace(chromium=Chromium(), stop=lambda: None)
    monkeypatch.setattr(playwright.sync_api, "sync_playwright", lambda: SimpleNamespace(start=lambda: runtime))
    browser = TikTokBrowser(tmp_path / "profile", background=True)
    try:
        browser.open()
        assert launches[-1]["headless"] is False
        assert "--mute-audio" in launches[-1]["args"]
        assert "--start-minimized" in launches[-1]["args"]
        assert events.index(("state", "minimized")) < events.index(("goto", "https://www.tiktok.com/"))
        context = browser.context
        browser.park()
        assert events[-1] == ("goto", "about:blank")
        browser.open()
        assert browser.context is context and not context.closed and len(launches) == 1
        assert events[-2:] == [("state", "minimized"), ("goto", "https://www.tiktok.com/")]
        browser.set_background(False)
        assert events[-1] == ("state", "normal")
        assert browser.context is context and len(launches) == 1
        assert launches[-1]["channel"] == "msedge"
    finally:
        browser.close()


def test_parking_failure_reports_error_and_worker_can_still_finish_and_exit(tmp_path, monkeypatch):
    from offline_tiktok import gui
    import queue
    import threading
    browser = SimpleNamespace(collections=lambda: [], set_background=lambda value: None, close=lambda: None)
    def closed_window(): raise RuntimeError("Browser window closed during parking")
    browser.park = closed_window
    monkeypatch.setattr(gui, "TikTokBrowser", lambda *args, **kwargs: browser)
    monkeypatch.setattr(gui, "MediaDownloader", lambda *args, **kwargs: SimpleNamespace())
    app = gui.HelperApp.__new__(gui.HelperApp)
    app.data_dir = tmp_path
    app.commands = queue.Queue()
    app.events = queue.Queue()
    app.cancelled = threading.Event()
    app.quitting = False
    app.commands.put(("scan", None))
    app.commands.put(("close", None))
    app._worker()
    events = list(app.events.queue)
    assert ("error", "Browser window closed during parking") in events
    assert ("done", None) in events
    assert app.commands.empty()
