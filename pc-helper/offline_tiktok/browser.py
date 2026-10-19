from dataclasses import dataclass
from pathlib import Path
import re
from urllib.parse import parse_qs, unquote, urlparse
from .catalog import MediaItem


@dataclass(frozen=True)
class Collection:
    id: str
    name: str
    url: str
    count: int | None = None


@dataclass(frozen=True)
class CollectionAdditions:
    items: tuple
    anchors: tuple[str, ...]
    known_ids: tuple[str, ...]


def collection_from_link(url, label=""):
    parsed = urlparse(url)
    if parsed.hostname not in ("www.tiktok.com", "tiktok.com"):
        return None
    match = re.fullmatch(r"/@[^/]+/collection/(.+)-(\d+)/?", parsed.path)
    if not match:
        return None
    count = re.search(r"([\d,]+)\s+videos?", label)
    return Collection(match[2], unquote(match[1]), f"https://www.tiktok.com{parsed.path}",
                      int(count[1].replace(",", "")) if count else None)


def post_from_link(url, label=""):
    parsed = urlparse(url)
    if parsed.hostname not in ("www.tiktok.com", "tiktok.com"):
        return None
    match = re.fullmatch(r"/@([^/]+)/(video|photo)/(\d+)/?", parsed.path)
    if not match:
        return None
    return MediaItem(match[3], label.strip() or f"TikTok {match[3]}", unquote(match[1]),
                     f"https://www.tiktok.com{parsed.path}", kind="slideshow" if match[2] == "photo" else "video", status="pending")


class CollectionScan:
    def __init__(self):
        self.items = {}

    def add(self, links):
        for link in links:
            if link.get("visible") is False:
                continue
            item = post_from_link(link["href"], link.get("label", ""))
            if item and item.id not in self.items:
                self.items[item.id] = item

    def finish(self, expected_count):
        if expected_count is None:
            raise ValueError("Collection count is missing; refusing to report a complete scan")
        if len(self.items) != expected_count:
            raise ValueError(f"Incomplete collection: found {len(self.items)} of {expected_count} posts. Retry after TikTok finishes loading.")
        return list(self.items.values())

    def additions(self, known_ids):
        """Prove only a new prefix, never claim the source's full membership."""
        known = tuple(known_ids)
        if not known or len(known) != len(set(known)):
            raise ValueError("An archived playlist is required before checking additions")
        positions = {key: index for index, key in enumerate(known)}
        observed = list(self.items)
        first = next((index for index, key in enumerate(observed) if key in positions), None)
        if first is None:
            return None
        start = positions[observed[first]]
        required = min(3, len(known))
        expected = known[start:start + required]
        anchors = tuple(observed[first:first + required])
        if anchors != expected[:len(anchors)]:
            raise ValueError("TikTok collection order changed; no additions were accepted")
        if len(anchors) < required:
            return None
        return CollectionAdditions(tuple(self.items[key] for key in observed[:first]), anchors, known)


class TikTokBrowser:
    """User-owned persistent Edge profile; no TikTok credentials leave the PC."""

    def __init__(self, profile, progress=lambda message: None, cancelled=lambda: False, *, background=False):
        self.profile = Path(profile)
        self.progress = progress
        self.cancelled = cancelled
        self.runtime = None
        self.context = None
        self.transient_browser = None
        self.pagination_observations = []
        self.background = background

    def set_background(self, value):
        self.background = value
        if self.context and not value:
            self._window_state("normal")

    def _window_state(self, state):
        # Control only this helper-owned browser, never unrelated Edge windows.
        windows = set()
        for page in self.context.pages:
            if page.is_closed():
                continue
            session = self.context.new_cdp_session(page)
            try:
                window = session.send("Browser.getWindowForTarget")["windowId"]
                if window not in windows:
                    session.send("Browser.setWindowBounds", {"windowId": window, "bounds": {"windowState": state}})
                    windows.add(window)
            finally:
                session.detach()

    def park(self):
        if self.context:
            try:
                self._window_state("minimized")
                if not self.page.is_closed():
                    self.page.goto("about:blank", wait_until="domcontentloaded")
            except Exception:
                self.close()
                raise

    def open(self):
        from playwright.sync_api import sync_playwright
        if self.context and self.page.is_closed():
            self.close()
        created = not self.context
        if not self.context:
            self.profile.mkdir(parents=True, exist_ok=True)
            self.runtime = sync_playwright().start()
            self.context = self.runtime.chromium.launch_persistent_context(str(self.profile), channel="msedge", headless=False,
                args=["--mute-audio"] + (["--start-minimized"] if self.background else []), viewport={"width": 1280, "height": 900})
            self.page = self.context.pages[0] if self.context.pages else self.context.new_page()
        if self.background:
            self._window_state("minimized")
        if created or self.page.url == "about:blank":
            self.page.goto("https://www.tiktok.com/", wait_until="domcontentloaded")
        return self

    def open_authorized(self, cookies):
        """Bounded importer proof using the helper's authorized session in memory."""
        if self.context:
            raise RuntimeError("A browser is already open")
        if not cookies:
            raise ValueError("Authorize video checks in the helper before running the collection proof")
        from playwright.sync_api import sync_playwright
        self.runtime = sync_playwright().start()
        self.transient_browser = self.runtime.chromium.launch(channel="msedge", headless=False)
        self.context = self.transient_browser.new_context(viewport={"width": 1280, "height": 900})
        self.context.add_cookies(cookies)
        self.page = self.context.new_page()
        return self

    def close(self):
        if self.context:
            self.context.close()
            self.context = None
        if self.transient_browser:
            self.transient_browser.close()
            self.transient_browser = None
        if self.runtime:
            self.runtime.stop()
            self.runtime = None

    def _check_cancel(self):
        if self.cancelled():
            raise InterruptedError("Paused. Completed files and checkpoints are retained.")

    def _links(self, *, collection_only=False):
        # TikTok also mounts an invisible, prefetched For You feed in this DOM.
        selector = '[data-e2e="collection-item-list"] a[href]' if collection_only else "a[href]"
        links = self.page.locator(selector)
        if not collection_only:
            links = links.filter(visible=True)
        return links.evaluate_all("nodes => nodes.map(a => ({href:a.href,label:a.getAttribute('aria-label') || a.querySelector('img')?.getAttribute('alt') || a.innerText || ''}))")

    def _loaded_count(self, locator, *, allow_zero=False):
        # TikTok renders zero placeholders before its asynchronous data arrives.
        # A zero is only accepted for a collection already enumerated as empty.
        for _ in range(40):
            self._check_cancel()
            match = re.search(r"[\d,]+", locator.inner_text())
            if match:
                count = int(match[0].replace(",", ""))
                if count > 0 or allow_zero:
                    return count
            self.page.wait_for_timeout(500)
        raise ValueError("TikTok's count is still zero or missing. No saved playlists were replaced. If collections should be present, wait for TikTok to load and retry.")

    def collections(self):
        self.open()
        profile = self.page.get_by_role("link", name="Profile", exact=True)
        profile.wait_for(timeout=15000)
        href = profile.get_attribute("href") or ""
        if not re.search(r"/@[^/?]+", href):
            raise RuntimeError("Sign in to TikTok in the helper's browser, then scan again.")
        profile.click()
        self.page.get_by_role("tab", name="Favorites", exact=True).click(timeout=20000)
        tab = self.page.get_by_role("button", name=re.compile(r"^Collections\s+[\d,]+$"))
        tab.wait_for(timeout=20000)
        tab.click()
        expected = self._loaded_count(tab)
        self.page.wait_for_timeout(1000)
        result = {}
        idle = 0
        for _ in range(2500):
            self._check_cancel()
            previous = len(result)
            for link in self._links():
                collection = collection_from_link(link["href"], link["label"])
                if collection:
                    result.setdefault(collection.id, collection)
            self.progress(f"Found {len(result)} of {expected} collections")
            if len(result) == expected:
                return list(result.values())
            idle = idle + 1 if len(result) == previous else 0
            if idle >= 8:
                break
            self.page.mouse.wheel(0, 1800)
            self.page.wait_for_timeout(700)
        raise ValueError(f"Incomplete discovery: found {len(result)} of {expected} collections; retry the scan.")

    def items(self, collection, observed=lambda items, expected, complete: None):
        self.open()
        self.pagination_observations = []

        def pagination_response(response):
            parsed = urlparse(response.url)
            if parsed.hostname not in ("www.tiktok.com", "tiktok.com") or "collection" not in parsed.path:
                return
            try:
                data = response.json()
                if not isinstance(data, dict):
                    return
                query = parse_qs(parsed.query)
                record = dict(endpoint=parsed.path, selectedCollection=any(collection.id in values for values in query.values()))
                for key in ("hasMore", "has_more", "cursor", "statusCode", "status_code", "total", "totalCount"):
                    value = data.get(key)
                    if isinstance(value, (bool, int)) or isinstance(value, str) and value.isdecimal():
                        record[key] = value
                record["responseKeys"] = list(data.keys())
                for key in ("itemList", "item_list", "aweme_list", "itemIdList"):
                    if isinstance(data.get(key), list):
                        record[key + "Count"] = len(data[key])
                if len(self.pagination_observations) < 1000:
                    self.pagination_observations.append(record)
            except Exception:
                pass

        if hasattr(self.page, "on"):
            self.page.on("response", pagination_response)
        try:
            self.page.goto(collection.url, wait_until="domcontentloaded")
            heading = self.page.get_by_role("heading", name=re.compile(r"^[\d,]+ videos?$"))
            heading.wait_for(timeout=20000)
            expected = self._loaded_count(heading, allow_zero=collection.count == 0)
            scan = CollectionScan()
            idle = 0
            for _ in range(2500):
                self._check_cancel()
                previous = len(scan.items)
                scan.add(self._links(collection_only=True))
                self.progress(f"{collection.name}: discovered {len(scan.items)} of {expected} posts")
                if len(scan.items) != previous or len(scan.items) == expected:
                    observed(list(scan.items.values()), expected, len(scan.items) == expected)
                if len(scan.items) == expected:
                    return scan.finish(expected)
                idle = idle + 1 if len(scan.items) == previous else 0
                pages = [value for value in self.pagination_observations
                         if value["selectedCollection"] and value["endpoint"] == "/api/collection/item_list/"]
                if idle >= 2 and pages:
                    last = pages[-1]
                    if (last.get("hasMore") is False and str(last.get("cursor")) == str(expected)
                            and last.get("statusCode", last.get("status_code")) == 0):
                        raise ValueError(f"TikTok finished pagination but returned {len(scan.items)} of {expected} posts. "
                                         "Full collection membership is required; no playlist was published.")
                if idle >= 40:
                    break
                self.page.mouse.move(900, 700)
                self.page.mouse.wheel(0, 1800)
                self.page.wait_for_timeout(700)
            return scan.finish(expected)
        finally:
            if hasattr(self.page, "remove_listener"):
                self.page.remove_listener("response", pagination_response)

    def additions(self, collection, known_ids):
        parsed = collection_from_link(collection.url)
        if not parsed or parsed.id != collection.id:
            raise ValueError("Use the selected TikTok collection's original URL")
        self.open()

        def prefix():
            self._check_cancel()
            self.page.goto(collection.url, wait_until="domcontentloaded")
            heading = self.page.get_by_role("heading", name=re.compile(r"^[\d,]+ videos?$"))
            heading.wait_for(timeout=20000)
            self._loaded_count(heading)
            scan, idle = CollectionScan(), 0
            for _ in range(200):
                self._check_cancel()
                previous = len(scan.items)
                scan.add(self._links(collection_only=True))
                proof = scan.additions(known_ids)
                if proof is not None:
                    return proof
                idle = idle + 1 if len(scan.items) == previous else 0
                if idle >= 8:
                    break
                self.page.mouse.move(900, 700)
                self.page.mouse.wheel(0, 1800)
                self.page.wait_for_timeout(700)
            raise ValueError("Could not match archived collection anchors. Sign in or retry after TikTok finishes loading; saved videos are unchanged.")

        first = prefix()
        self.page.wait_for_timeout(700)
        second = prefix()
        if ([item.id for item in first.items], first.anchors) != ([item.id for item in second.items], second.anchors):
            raise ValueError("TikTok collection changed during the check; retry without replacing the archive")
        self.progress(f"{collection.name}: verified {len(second.items)} new additions")
        return second

    def collection_diagnostics(self):
        """DOM counters only; no cookies, storage state or response headers."""
        links = self._links(collection_only=True)
        ids = {item.id for link in links if (item := post_from_link(link["href"], link.get("label", "")))}
        return dict(collectionCards=self.page.locator('[data-e2e="collection-item-list"] [data-e2e="collection-item"]').count(),
                    collectionPostIds=len(ids),
                    pagination=self.pagination_observations,
                    page=self.page.evaluate("() => ({top:document.scrollingElement.scrollTop,height:document.scrollingElement.scrollHeight,viewportHeight:document.scrollingElement.clientHeight})"))

    def cookies(self):
        self.open()
        return self.context.cookies("https://www.tiktok.com/")
