#!/usr/bin/env python3
"""Exercise the real import owner, disk and keychain in one disposable world.

Synthetic profiles live in a temporary directory, never in personal browser
folders. Preview, resize, cancellation, captured destination, durable replay
and a duplicate CSV account cross the app boundary. Secrets are compared by
the test process without printing them. The shared harness bounds every wait.
"""
from datetime import datetime, timedelta, timezone
from pathlib import Path
import hashlib
import json
import sqlite3
import subprocess
import sys
import tempfile

import suite as h


def bench(*args):
    return json.loads(h.command(str(h.ROOT / "bench"), "--world", h.WORLD, "--json", *map(str, args), seconds=35))


def state():
    return bench("migration")


def phase(expected):
    def ready():
        current = state()
        if expected != "stopped" and current["phase"] == "stopped":
            raise AssertionError(f"{expected}: {current['message']}")
        return current["phase"] == expected
    h.until(expected, ready, 20)


def choose(path, browser=None):
    args = ["migration", "choose", path]
    if browser:
        args += [browser, "folder"]
    bench(*args)
    h.until("discovery", lambda: not state()["discovering"], 20)
    h.require("discovery readable", state()["message"], "")


def preview():
    bench("migration", "preview")
    phase("preview")


def confirm():
    bench("migration", "confirm")
    phase("finished")
    return state()


def read(path):
    return json.loads(path.read_text()) if path.exists() else []


def main():
    if h.SOCKET.parent.exists():
        raise AssertionError("refusing to reuse occupied test world")
    with tempfile.TemporaryDirectory(prefix="escale-migration-") as directory:
        fixture = Path(directory)
        profile = fixture / "Profile 7"
        profile.mkdir()
        (fixture / "Local State").write_text(json.dumps({"profile": {"info_cache": {"Profile 7": {"name": "Work — preserved profile name"}}}}))
        (profile / "Bookmarks").write_text(json.dumps({"version": 1, "roots": {"bookmark_bar": {
            "type": "folder", "guid": "root", "name": "Imported", "children": [
                {"type": "url", "guid": "site", "name": "Synthetic", "url": "https://migration.invalid/bookmark"}]}}}))
        with sqlite3.connect(profile / "History") as db:
            db.execute("CREATE TABLE urls(url TEXT,title TEXT,visit_count INTEGER,last_visit_time INTEGER,hidden INTEGER)")
            db.execute("INSERT INTO urls VALUES (?,?,?,?,?)", ("https://migration.invalid/history", "Synthetic history", 7, 13434292800000000, 0))
        hashes = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in profile.iterdir()}
        csv = fixture / "passwords.csv"
        user = h.WORLD
        # Unique host + account, and a new Space's keychain path, avoid every
        # installed browser item even though internet-password labels aren't keys.
        host = f"{h.WORLD}.invalid"
        original, replacement = "synthetic-import-value", "synthetic-replacement-value"
        csv.write_text(f"url,username,password\nhttps://{host},{user},{original}\n")
        empty = fixture / "empty.html"
        empty.write_text('<!DOCTYPE NETSCAPE-Bookmark-file-1><DL></DL>')
        broken = fixture / "broken.csv"
        broken.write_text('url,username,password\n"unterminated')
        try:
            h.command(str(h.ROOT / "fresh.sh"), "wipe")
            h.command("defaults", "write", h.SUITE, "bench", "-bool", "YES")
            h.command("defaults", "write", h.SUITE, "welcomed", "-bool", "YES")
            h.command("defaults", "write", h.SUITE, "spaces", "-bool", "YES")
            checked = (datetime.now(timezone.utc) + timedelta(days=1)).strftime("%Y-%m-%d %H:%M:%S +0000")
            h.command("defaults", "write", h.SUITE, "update.checked", "-date", checked)
            h.launch()
            bench("space", "new", "Migration destination", "fresh")
            spaces = bench("space")["spaces"]
            target = spaces[-1]["id"]
            target_index = len(spaces) - 1
            books = h.SOCKET.parent / f"bookmarks-{target}.json"
            history = h.SOCKET.parent / f"history-{target}.json"
            bench("migration", "open")
            initial_pages = state()["pages"]
            choose(fixture, "Edge")
            h.require("profile name", state()["sources"][0]["profile"], "Work — preserved profile name")
            bench("migration", "destination", target_index)
            preview()
            h.require("preview bookmarks", state()["previewBookmarks"], 2)
            h.require("preview history", state()["previewHistory"], 1)
            h.require("preview writes no bookmarks", read(books), [])
            h.require("preview writes no history", read(history), [])
            bench("resize", 720, 520)
            bench("ui", "size", "large")
            h.require("adaptive layout preserves preview", state()["phase"], "preview")
            bench("migration", "cancel")
            phase("stopped")
            h.require("cancel before confirm writes nothing", read(books), [])
            print("ok: named profile, read-only preview, resize and cancellation")

            bench("migration", "reset")
            choose(fixture, "Edge")
            # Choose another Space without switching the visible browser. The
            # plan is bound to target, never the currently displayed owner.
            bench("migration", "destination", 0)
            preview()
            confirm()
            h.require("captured destination leaves current Space empty", read(books), [])
            h.require("first Space bookmarks written", len(read(h.SOCKET.parent / "bookmarks.json")), 1)
            bench("migration", "reset")
            choose(fixture, "Edge")
            bench("migration", "destination", target_index)
            preview()
            first = confirm()
            h.require("saved categories", set(first["completed"]), {"bookmarks", "history"})
            before_books, before_history = read(books), read(history)
            h.require("history visit count", before_history[0]["count"], 7)
            h.require("no page created by import", state()["pages"], initial_pages)
            h.require("source bytes unchanged", {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in hashes}, hashes)
            h.ask("press", code=12, chars="q", mods=["cmd"])
            h.until("quit", lambda: not h.running(), 30)
            h.launch()
            bench("migration", "open")
            choose(fixture, "Edge")
            bench("migration", "destination", target_index)
            preview()
            second = confirm()
            h.require("replay adds no bookmarks", second["addedBookmarks"], 0)
            h.require("replay keeps bookmarks", read(books), before_books)
            h.require("replay does not inflate history", read(history), before_history)
            print("ok: captured destination, durable restart/replay, unchanged source and page count")

            bench("migration", "reset")
            choose(csv)
            bench("migration", "destination", target_index)
            preview()
            h.require("password preview count", state()["previewPasswords"], 1)
            h.require("real isolated keychain add", confirm()["passwordAdds"], 1)
            csv.write_text(f"url,username,password\nhttps://{host},{user},{replacement}\n")
            bench("migration", "reset")
            choose(csv)
            preview()
            h.require("existing keychain account kept", confirm()["passwordKeeps"], 1)
            digest = hashlib.sha256(original.encode()).hexdigest()
            h.require("existing secret unchanged", bench("migration", "password-matches", digest)["matches"], True)
            journal = (h.SOCKET.parent / "migration.json").read_text()
            h.require("receipt excludes secrets", any(word in journal for word in (original, replacement, host, user)), False)
            print("ok: real keychain duplicate is preserved, receipt contains no secret")

            bench("migration", "reset")
            choose(empty)
            preview()
            h.require("empty preview", state()["previewBookmarks"], 0)
            bench("migration", "cancel")
            bench("migration", "reset")
            choose(broken)
            bench("migration", "preview")
            phase("stopped")
            h.require("malformed source diagnosed", bool(state()["message"]), True)
            bench("migration", "reset")
            choose(fixture, "Edge")
            bench("migration", "destination", target_index)
            preview()
            # Space navigation dismisses Settings: any outstanding preview is
            # discarded, never silently retargeted or applied to the new Space.
            bench("space", "go", 1)
            phase("stopped")
            h.require("switch keeps saved bookmarks", read(books), before_books)
            print("ok: empty/malformed data and leaving the destination preserve saved work")
            bench("migration", "open")
            bench("ui", "welcome", "on")
            panels = bench("probe")
            h.require("welcome replaces Settings", (panels["welcome"], panels["settings"]), (True, False))
            bench("migration", "open")
            panels = bench("probe")
            h.require("Settings replaces welcome", (panels["welcome"], panels["settings"]), (False, True))
            print("ok: welcome and Settings never host two simultaneous import surfaces")
        finally:
            h.command(str(h.ROOT / "fresh.sh"), "wipe")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
