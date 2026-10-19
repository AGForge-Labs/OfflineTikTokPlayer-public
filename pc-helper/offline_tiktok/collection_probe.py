"""Live selected-collection acceptance probe for the Windows importer."""
import argparse
import json
from pathlib import Path
import re
from .audit_auth import load_session
from .browser import Collection, TikTokBrowser, collection_from_link
from .cost_audit import AuditLedger, atomic_json
from .gui import data_directory


def run_probe(browser, ledger, collection):
    result = dict(playlistId=collection.id, name=collection.name, advertisedCount=collection.count,
                  scannedPosts=0, complete=False)

    def observed(items, expected, complete):
        result.update(advertisedCount=expected, scannedPosts=len(items), complete=complete)
        if complete:
            # A proven full refresh replaces membership/order, preserving media
            # belonging to other playlists in the account ledger.
            ledger.data["collections"][collection.id]["itemIds"] = []
        ledger.record(dict(kind="collection", id=collection.id, advertisedCount=expected, finished=complete,
                           links=[dict(href=item.source_url, label=item.title) for item in items]))

    try:
        browser.items(collection, observed=observed)
    except Exception as error:
        result["complete"] = False
        result["failure"] = re.sub(r"https?://\S+", "[source URL]", str(error))[:900]
        if hasattr(browser, "collection_diagnostics"):
            try:
                result["domDiagnostics"] = browser.collection_diagnostics()
            except Exception:
                pass
    result["checkpointedPosts"] = len(ledger.data["collections"][collection.id]["itemIds"])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--playlist-id", required=True)
    parser.add_argument("--persistent-profile", action="store_true", help="Use the exact browser profile signed into in the helper")
    parser.add_argument("--inspect-profile", action="store_true", help="Check the signed-in public profile link without scanning posts")
    parser.add_argument("--membership", type=Path, default=data_directory() / "cost-audit" / "membership.json")
    parser.add_argument("--output", type=Path, default=data_directory() / "cost-audit" / "collection-proof.json")
    args = parser.parse_args()
    ledger = AuditLedger(args.membership)
    value = ledger.data["collections"].get(args.playlist_id)
    if not value:
        parser.error("That playlist has not been discovered in the audit")
    parsed = collection_from_link(value["url"])
    if not parsed or parsed.id != args.playlist_id:
        parser.error("The saved collection URL does not match its ID")
    collection = Collection(parsed.id, value["name"], parsed.url, value["advertisedCount"])
    browser = TikTokBrowser(data_directory() / "tiktok-browser", progress=lambda message: print(message, flush=True))
    try:
        # Application-owned, four-hour authorization; no browser credential
        # extraction and no session contents in logs or the proof report.
        if args.persistent_profile:
            browser.open()
        else:
            browser.open_authorized(load_session(data_directory() / "cost-audit" / "tiktok-session.bin"))
            browser.page.goto("https://www.tiktok.com/", wait_until="domcontentloaded")
        profile = browser.page.get_by_role("link", name="Profile", exact=True)
        profile.wait_for(timeout=20000)
        profile_href = profile.get_attribute("href") or ""
        if args.inspect_profile:
            result = dict(playlistId=collection.id, complete=False, authenticatedProfile=profile_href,
                          profileMode="persistent" if args.persistent_profile else "authorized-session")
        else:
            result = run_probe(browser, ledger, collection)
            result["authenticatedProfile"] = profile_href
    except Exception as error:
        result = dict(playlistId=collection.id, name=collection.name, complete=False,
                      failure=re.sub(r"https?://\S+", "[source URL]", str(error))[:900])
    finally:
        browser.close()
    atomic_json(args.output, result)
    print(json.dumps(result, indent=2), flush=True)
    return 0 if result["complete"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
