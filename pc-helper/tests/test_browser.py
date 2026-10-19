import pytest
from offline_tiktok.browser import Collection, CollectionScan, collection_from_link, post_from_link


def test_collection_identity_preserves_unicode_and_slashes():
    collection = collection_from_link("https://www.tiktok.com/@fixture_creator_8/collection/Music%20%F0%9F%8E%B5%2FLive-12345")
    assert collection.id == "12345"
    assert collection.name == "Music 🎵/Live"


def test_post_identity_accepts_photos_and_rejects_external_hosts():
    assert post_from_link("https://www.tiktok.com/@fixture_creator_8/photo/12345", "Caption").kind == "slideshow"
    assert post_from_link("https://attacker.example/@fixture_creator_8/video/12345", "Caption") is None


def test_scroll_snapshots_deduplicate_without_reordering():
    scan = CollectionScan()
    scan.add([{"href": "https://www.tiktok.com/@fixture_creator_1/video/2", "label": "Second"}, {"href": "https://www.tiktok.com/@fixture_creator_1/photo/1", "label": "First"}])
    scan.add([{"href": "https://www.tiktok.com/@fixture_creator_1/photo/1", "label": "First"}, {"href": "https://www.tiktok.com/@fixture_creator_1/video/3", "label": "Third"}])
    assert [item.id for item in scan.finish(expected_count=3)] == ["2", "1", "3"]


def test_stalled_or_partial_scroll_is_not_reported_complete():
    scan = CollectionScan()
    scan.add([{"href": "https://www.tiktok.com/@fixture_creator_1/video/2", "label": "Second"}])
    with pytest.raises(ValueError, match="1 of 3"):
        scan.finish(expected_count=3)


def test_empty_collection_has_a_complete_empty_result():
    assert CollectionScan().finish(expected_count=0) == []


def test_hidden_background_feed_does_not_enter_a_collection():
    scan = CollectionScan()
    scan.add([{"href": "https://www.tiktok.com/@fixture_creator_3/video/999", "visible": False},
              {"href": "https://www.tiktok.com/@fixture_creator_7/video/100", "visible": True}])
    assert [item.id for item in scan.finish(expected_count=1)] == ["100"]


def test_slow_favorites_loading_cannot_be_reported_as_an_empty_library(tmp_path):
    from types import SimpleNamespace
    from offline_tiktok.browser import TikTokBrowser

    class Locator:
        def wait_for(self, **kwargs):
            pass

        def click(self, **kwargs):
            pass

        def get_attribute(self, name):
            return "/@fixture_creator_8"

        def inner_text(self):
            return "Collections 1" if page.elapsed_ms >= 4000 else "Collections 0"

    class SlowPage:
        elapsed_ms = 0

        def get_by_role(self, *args, **kwargs):
            return Locator()

        def wait_for_timeout(self, milliseconds):
            self.elapsed_ms += milliseconds

    page = SlowPage()
    browser = TikTokBrowser(tmp_path / "profile")
    browser.page = page
    browser.open = lambda: browser
    browser._links = lambda **kwargs: ([{"href": "https://www.tiktok.com/@fixture_creator_8/collection/Music-1", "label": "Music 3 videos"}]
                              if page.elapsed_ms >= 4000 else [])
    page.mouse = SimpleNamespace(wheel=lambda *args: page.wait_for_timeout(500))
    result = browser.collections()
    assert [collection.id for collection in result] == ["1"]


def test_zero_loading_placeholder_cannot_erase_a_previously_nonempty_collection(tmp_path):
    from types import SimpleNamespace
    from offline_tiktok.browser import TikTokBrowser

    class Heading:
        def wait_for(self, **kwargs):
            pass

        def inner_text(self):
            return "1 video" if page.elapsed_ms >= 4000 else "0 videos"

    class SlowPage:
        elapsed_ms = 0

        def goto(self, *args, **kwargs):
            pass

        def get_by_role(self, *args, **kwargs):
            return Heading()

        def wait_for_timeout(self, milliseconds):
            self.elapsed_ms += milliseconds

    page = SlowPage()
    browser = TikTokBrowser(tmp_path / "profile")
    browser.page = page
    browser.open = lambda: browser
    browser._links = lambda **kwargs: ([{"href": "https://www.tiktok.com/@fixture_creator_1/video/2", "label": "Second"}]
                              if page.elapsed_ms >= 4000 else [])
    page.mouse = SimpleNamespace(wheel=lambda *args: page.wait_for_timeout(500))
    result = browser.items(Collection("1", "Music", "https://www.tiktok.com/@fixture_creator_8/collection/Music-1", 1))
    assert [item.id for item in result] == ["2"]


def test_incomplete_import_scan_checkpoints_only_collection_members(tmp_path):
    from types import SimpleNamespace
    from offline_tiktok.browser import TikTokBrowser

    class Heading:
        def wait_for(self, **kwargs):
            pass

        def inner_text(self):
            return "3 videos"

    class Page:
        def goto(self, *args, **kwargs):
            pass

        def get_by_role(self, *args, **kwargs):
            return Heading()

        def wait_for_timeout(self, milliseconds):
            pass

    page = Page()
    page.mouse = SimpleNamespace(move=lambda *args: None, wheel=lambda *args: None)
    browser = TikTokBrowser(tmp_path / "profile")
    browser.page = page
    browser.open = lambda: browser
    member = {"href": "https://www.tiktok.com/@fixture_creator_7/video/100", "label": "Music"}
    background = {"href": "https://www.tiktok.com/@fixture_creator_3/video/999", "label": "For You"}
    browser._links = lambda **kwargs: [member] if kwargs.get("collection_only") else [member, background]
    checkpoints = []
    with pytest.raises(ValueError, match="1 of 3"):
        browser.items(Collection("1", "Music", "https://www.tiktok.com/@fixture_creator_8/collection/Music-1", 3),
                      observed=lambda items, expected, complete: checkpoints.append((tuple(item.id for item in items), expected, complete)))
    assert checkpoints
    assert all(ids == ("100",) and expected == 3 and not complete for ids, expected, complete in checkpoints)


def test_collection_dom_members_remain_in_the_scan_while_their_cards_are_hidden(tmp_path):
    from offline_tiktok.browser import TikTokBrowser
    links = [{"href": "https://www.tiktok.com/@fixture_creator_7/video/100", "label": "Visible"},
             {"href": "https://www.tiktok.com/@fixture_creator_7/video/200", "label": "Temporarily hidden card"}]

    class Locator:
        visible_only = False

        def filter(self, **kwargs):
            self.visible_only = kwargs.get("visible", False)
            return self

        def evaluate_all(self, script):
            return links[:1] if self.visible_only else links

    class Page:
        def locator(self, selector):
            assert selector == '[data-e2e="collection-item-list"] a[href]'
            return Locator()

    browser = TikTokBrowser(tmp_path / "profile")
    browser.page = Page()
    scan = CollectionScan()
    scan.add(browser._links(collection_only=True))
    assert [item.id for item in scan.finish(2)] == ["100", "200"]


def test_server_end_with_missing_members_is_reported_as_a_source_gap(tmp_path):
    from types import SimpleNamespace
    from offline_tiktok.browser import TikTokBrowser

    class Heading:
        def wait_for(self, **kwargs):
            pass

        def inner_text(self):
            return "5 videos"

    class Page:
        def on(self, event, callback):
            self.callback = callback

        def remove_listener(self, event, callback):
            assert callback is self.callback
            self.callback = None

        def goto(self, *args, **kwargs):
            self.callback(SimpleNamespace(
                url="https://www.tiktok.com/api/collection/item_list/?collectionId=1&token=PRIVATE",
                json=lambda: dict(cursor="5", hasMore=False, statusCode=0, itemList=[{}, {}, {}])))

        def get_by_role(self, *args, **kwargs):
            return Heading()

        def wait_for_timeout(self, milliseconds):
            pass

    page = Page()
    page.mouse = SimpleNamespace(move=lambda *args: None, wheel=lambda *args: None)
    browser = TikTokBrowser(tmp_path / "profile")
    browser.page = page
    browser.open = lambda: browser
    browser._links = lambda **kwargs: [dict(href=f"https://www.tiktok.com/@fixture_creator_1/video/{key}") for key in (10, 20, 30)]
    with pytest.raises(ValueError, match="finished pagination.*3 of 5"):
        browser.items(Collection("1", "Music", "https://www.tiktok.com/@fixture_creator_8/collection/Music-1", 5))
    assert page.callback is None
    assert "PRIVATE" not in str(browser.pagination_observations)
