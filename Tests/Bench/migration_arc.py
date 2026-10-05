#!/usr/bin/env python3
"""Arc Spaces and per-category actions against a synthetic test-world sidebar.

The automatic route only sees migration-arc inside this disposable world's
Store. The sidebar follows the structure observed in Arc 1.166.0 with
synthetic values. Assert Spaces as sources, pinned folders and Favorites,
announced losses, shared-profile history, replay, corruption, the copied-links
fallback, restart and unchanged source bytes.
"""
import hashlib
import json
import sqlite3
import subprocess
import sys

import suite as h
from migration import bench, state, phase, read

DEFAULT = {"default": True}
CLIENT = {"custom": {"_0": {"directoryBasename": "Profile 1"}}}


def seed(root):
    items, spaces = [], []

    def item(id, parent, data, title=None, children=()):
        items.extend([id, {"id": id, "parentID": parent, "childrenIds": list(children), "title": title,
                           "data": data, "createdAt": 0, "isUnread": False, "originatingDevice": "fixture"}])

    def tab(id, parent, url, saved="Saved", title=None):
        item(id, parent, {"tab": {"savedURL": url, "savedTitle": saved, "timeLastActiveAt": 0}}, title)

    def space(id, title, profile, pinned, today=()):
        for kind, children in (("pin", pinned), ("day", today)):
            item(f"{kind}-{id}", None, {"itemContainer": {"containerType": {"spaceItems": {"_0": id}}}}, children=children)
        spaces.extend([id, {"id": id, "title": title, "profile": profile,
                            "containerIDs": ["pinned", f"pin-{id}", "unpinned", f"day-{id}"]}])

    space("work", "Work fixture", DEFAULT, ["docs", "same-1", "same-2", "extension"], ["today"])
    item("docs", "pin-work", {"list": {}}, "Docs", ["guide"])
    tab("guide", "docs", "https://arc.invalid/guide", title="Guide")
    tab("same-1", "pin-work", "https://arc.invalid/same")
    tab("same-2", "pin-work", "https://arc.invalid/same")
    tab("extension", "pin-work", "chrome-extension://fixture/page.html")
    tab("today", "day-work", "https://arc.invalid/today")
    space("home", "Home fixture", DEFAULT, ["recipe"])
    tab("recipe", "pin-home", "https://arc.invalid/recipe")
    space("client", "Client fixture", CLIENT, ["ticket"])
    tab("ticket", "pin-client", "https://arc.invalid/ticket")
    item("fav", None, {"itemContainer": {"containerType": {"topApps": {"_0": DEFAULT}}}}, children=["mail"])
    tab("mail", "fav", "https://arc.invalid/mail")

    (root / "User Data/Default").mkdir(parents=True)
    (root / "StorableSidebar.json").write_text(json.dumps({"version": 1, "sidebar": {"containers": [
        {"global": {}}, {"spaces": spaces, "items": items, "topAppsContainerIDs": [DEFAULT, "fav"]}]}}))
    (root / "User Data/Local State").write_text(json.dumps({"profile": {"info_cache": {
        "Default": {"name": "Personal"}, "Profile 1": {"name": "Client"}}}}))
    with sqlite3.connect(root / "User Data/Default/History") as db:
        db.execute("CREATE TABLE urls(url TEXT,title TEXT,visit_count INTEGER,last_visit_time INTEGER,hidden INTEGER)")
        db.execute("INSERT INTO urls VALUES (?,?,?,?,?)", ("https://arc.invalid/history", "History", 4, 13434292800000000, 0))


def discover():
    bench("migration", "automatic", "Arc")
    h.until("Arc discovery", lambda: not state()["discovering"], 20)
    h.require("discovery message", state()["message"], "")


def run_step(category):
    bench("migration", "step", category)
    phase("finished")
    h.require("single category", state()["categories"], [category])
    h.require("category acknowledged", state()["completed"], [category])


def titles(nodes):
    return [n["title"] for n in nodes]


def main():
    if h.SOCKET.parent.exists():
        raise AssertionError("refusing to reuse occupied world")
    try:
        h.command(str(h.ROOT / "fresh.sh"), "wipe")
        root = h.SOCKET.parent / "migration-arc"
        seed(root)
        hashes = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob("*") if p.is_file()}
        h.command("defaults", "write", h.SUITE, "bench", "-bool", "YES")
        h.command("defaults", "write", h.SUITE, "welcomed", "-bool", "YES")
        h.command("defaults", "write", h.SUITE, "spaces", "-bool", "YES")
        h.launch()
        bench("space", "new", "Arc destination", "fresh")
        spaces = bench("space")["spaces"]
        target = spaces[-1]["id"]
        books = h.SOCKET.parent / f"bookmarks-{target}.json"
        history = h.SOCKET.parent / f"history-{target}.json"
        bench("migration", "open")
        h.require("opening does not discover", state()["sources"], [])
        pages = state()["pages"]
        discover()
        h.require("Arc Spaces as sources", [x["profile"] for x in state()["sources"]],
                  ["Work fixture · Personal", "Home fixture · Personal", "Client fixture · Client"])
        h.require("custom profile without history", state()["sources"][2]["categories"], ["bookmarks"])
        bench("migration", "destination", len(spaces) - 1)
        run_step("bookmarks")
        saved = read(books)
        h.require("Favorites first, then pinned order", titles(saved), ["Favorites", "Docs", "Saved", "Saved"])
        h.require("folder kept", titles(saved[1]["children"]), ["Guide"])
        h.require("only chosen category written", read(history), [])
        notices = state()["stepNotices"]["bookmarks"]
        h.require("Today loss announced", "1 Today tab is not imported" in notices, True)
        h.require("extension loss announced", "1 sidebar item is not imported" in notices, True)
        run_step("history")
        h.require("history volume acknowledged", state()["historyPlaces"], len(read(history)))
        h.require("shared profile explained", "shared by 2 Spaces" in state()["stepNotices"]["history"], True)
        run_step("bookmarks")
        h.require("repeat adds nothing", state()["addedBookmarks"], 0)
        h.require("repeat preserves data", read(books), saved)
        print("ok: Spaces as sources, pinned folders, Favorites, losses, shared history and replay")

        sidebar = root / "StorableSidebar.json"
        original = sidebar.read_bytes()
        sidebar.write_text(json.dumps({"version": 2, "sidebar": {"containers": []}}))
        bench("migration", "step", "bookmarks")
        phase("stopped")
        h.require("unknown version refused", bool(state()["message"]), True)
        sidebar.write_bytes(original)
        run_step("bookmarks")
        h.require("retry adds nothing", state()["addedBookmarks"], 0)

        links = h.SOCKET.parent / "arc-links.txt"
        links.write_text("https://arc.invalid/copied\n[Named](https://arc.invalid/named)\n")
        bench("migration", "step-export", links, "bookmarks")
        phase("finished")
        h.require("copied links become the source", state()["sources"][0]["format"], "links")
        h.require("copied links added", state()["addedBookmarks"], 2)
        discover()
        h.require("refresh returns to Spaces", len(state()["sources"]), 3)
        h.require("source unchanged", {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in hashes}, hashes)
        h.require("no web view created", state()["pages"], pages)
        print("ok: unknown version, retry, copied links fallback and source preservation")

        h.ask("press", code=12, chars="q", mods=["cmd"])
        h.until("quit", lambda: not h.running(), 30)
        h.launch()
        bench("migration", "open")
        discover()
        bench("migration", "destination", len(spaces) - 1)
        run_step("bookmarks")
        h.require("restart replay adds nothing", state()["addedBookmarks"], 0)
        print("ok: restart replay")
    finally:
        h.command(str(h.ROOT / "fresh.sh"), "wipe")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, ValueError, subprocess.TimeoutExpired, KeyError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
