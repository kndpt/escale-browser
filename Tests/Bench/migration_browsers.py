#!/usr/bin/env python3
"""Every new brand's real import flow against one disposable synthetic world.

Shared Chromium data exercises every brand hook; distinct Orion, Firefox, Zen
and Safari formats prove dispatch. Tabs must persist in a parked destination,
remain unbuilt, and replay after restart. Hashes include active SQLite WAL
files; no installed browser or personal profile participates.
"""
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import sqlite3
import struct
import subprocess
import sys
import time
import zipfile

import suite as h
from migration import bench, state, phase, read
from migration_aside import seed, run_step

BRANDS = ["Chromium", "Edge", "Brave", "Vivaldi", "Opera", "Opera GX", "Dia"]
FIREFOX = "Firefox / ESR / Developer / Beta / Nightly"


def slug(name):
    return "".join(c.lower() for c in name if c.isalnum())


def moz(value):
    data = json.dumps(value).encode()
    size = len(data)
    block = bytes([min(size, 15) << 4])
    if size >= 15:
        extra = size - 15
        block += bytes([255]) * (extra // 255) + bytes([extra % 255])
    return b"mozLz40\0" + struct.pack("<I", size) + block + data


def tab(url, **fields):
    return {"entries": [{"url": url, "title": "Synthetic tab"}], "index": 1, **fields}


def discover(brand):
    bench("migration", "automatic", brand)
    h.until("discover " + brand, lambda: not state()["discovering"], 20)
    h.require("readable " + brand, state()["message"], "")


def seed_all(root):
    for brand in BRANDS:
        folder = root / ("migration-" + slug(brand))
        seed(folder, host=slug(brand) + ".invalid")
        if brand in ("Opera", "Opera GX"):
            # Opera also supports a profile directly at its home, alongside
            # newer named profiles. It must remain a separate source.
            (folder / "Bookmarks").write_bytes((folder / "Default/Bookmarks").read_bytes())
    firefox = root / ("migration-" + slug(FIREFOX))
    firefox.mkdir()
    (firefox / "profiles.ini").write_text("[Profile0]\nName=Work — été\nIsRelative=1\nPath=Profiles/work\n")
    profile = firefox / "Profiles/work"
    profile.mkdir(parents=True)
    (profile / "sessionstore.jsonlz4").write_bytes(moz({"version": ["sessionrestore", 1], "windows": [{"tabs": [tab("https://firefox.invalid/1", pinned=True), tab("https://firefox.invalid/2")]}]}))
    zen = root / "migration-zen"
    zen.mkdir()
    (zen / "zen-sessions.jsonlz4").write_bytes(moz({"lastCollected": 1, "spaces": [{"uuid": "one", "name": "Work", "position": 0}, {"uuid": "two", "name": "Personal", "position": 1}], "folders": [{"id": "folder", "name": "Project", "workspaceId": "one", "parentId": None}], "tabs": [tab("https://zen.invalid/pin", zenSyncId="pin", zenWorkspace="one", pinned=True, groupId="folder"), tab("https://zen.invalid/essential", zenSyncId="essential", zenEssential=True), tab("https://zen.invalid/other", zenSyncId="other", zenWorkspace="two")]}))
    orion = root / "migration-orion"
    (orion / "Defaults").mkdir(parents=True)
    (orion / "profiles").write_bytes(plistlib.dumps({"defaults": {"name": "Orion work"}, "profiles": []}, fmt=plistlib.FMT_BINARY))
    (orion / "Defaults/favourites.plist").write_bytes(plistlib.dumps({"root": {"id": "root", "parentId": "0", "title": "Favorites", "type": "folder", "index": 0}, "site": {"id": "site", "parentId": "root", "title": "Orion", "type": "bookmark", "url": "https://orion.invalid", "index": 0}}, fmt=plistlib.FMT_BINARY))
    db = sqlite3.connect(orion / "Defaults/history")
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("CREATE TABLE history_items (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, last_visit_time REAL)")
    db.execute("INSERT INTO history_items VALUES (1, 'https://orion.invalid/history', 'History', 3, 800000000)")
    db.commit()
    safari = root / "safari.zip"
    with zipfile.ZipFile(safari, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("Favoris.html", '<!DOCTYPE NETSCAPE-Bookmark-file-1><DL><DT><A HREF="https://safari.invalid">Safari</A></DL>')
        archive.writestr("historique.json", json.dumps({"metadata": {"schema_version": 1, "browser_name": "Safari", "browser_version": "18.2-fixture", "data_type": "history"}, "history": [{"url": "https://safari.invalid/history", "title": "Safari history", "time_usec": 1700000000000000, "visits_count": 3}]}))
    return db


def main():
    if h.SOCKET.parent.exists():
        raise AssertionError("refusing to reuse occupied world")
    connection = None
    try:
        h.command(str(h.ROOT / "fresh.sh"), "wipe")
        h.SOCKET.parent.mkdir(parents=True)
        connection = seed_all(h.SOCKET.parent)
        sources = [p for p in h.SOCKET.parent.rglob("*") if p.is_file()]
        hashes = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
        for key in ["bench", "welcomed", "spaces"]:
            h.command("defaults", "write", h.SUITE, key, "-bool", "YES")
        checked = (datetime.now(timezone.utc) + timedelta(days=1)).strftime("%Y-%m-%d %H:%M:%S +0000")
        h.command("defaults", "write", h.SUITE, "update.checked", "-date", checked)
        h.launch()
        bench("space", "new", "Imports", "fresh")
        spaces = bench("space")["spaces"]
        target = spaces[-1]["id"]
        bench("space", "go", 0)
        bench("migration", "open")
        bench("migration", "destination", len(spaces) - 1)
        initial_pages = bench("space")["pages"]
        for brand in BRANDS:
            discover(brand)
            h.require("source count " + brand, len(state()["sources"]), 3 if brand in ("Opera", "Opera GX") else 2)
            if brand in ("Opera", "Opera GX"):
                bench("migration", "select", 1)
            run_step("bookmarks")
            run_step("history")
            run_step("bookmarks")
            h.require("replay " + brand, state()["addedBookmarks"], 0)
            print("ok: " + brand + " profiles, bookmarks, history, replay", flush=True)
        discover("Orion")
        run_step("bookmarks"); run_step("history")
        h.require("Orion active-WAL history", state()["historyPlaces"], 8)
        discover(FIREFOX)
        h.require("named Firefox profile", state()["sources"][0]["profile"], "Work — été")
        run_step("tabs")
        h.require("Firefox tabs acknowledged", state()["addedTabs"], 2)
        run_step("tabs")
        h.require("Firefox replay", (state()["addedTabs"], state()["keptTabs"]), (0, 2))
        discover("Zen")
        h.require("Zen workspace count", len(state()["sources"]), 2)
        run_step("bookmarks"); run_step("tabs")
        h.require("Zen pins and essentials", state()["addedTabs"], 2)
        if os.environ.get("ESCALE_MIGRATION_SHOTS"):
            shots = Path(os.environ["ESCALE_MIGRATION_SHOTS"])
            shots.mkdir(parents=True, exist_ok=True)
            for look in ["light", "dark"]:
                bench("ui", "look", look)
                bench("resize", 720, 520)
                time.sleep(0.5)
                bench("picture", shots / f"zen-{look}.png")
                bench("resize", 960, 980)
                time.sleep(0.5)
                bench("picture", shots / f"zen-full-{look}.png")
        session = read(h.SOCKET.parent / f"session-{target}.json")
        h.require("captured destination has all four tabs", len(session["tabs"]), 4)
        h.require("current Space not used as destination", read(h.SOCKET.parent / "session.json").get("tabs", []) if (h.SOCKET.parent / "session.json").exists() else [], [])
        h.require("imported pages asleep", bench("space")["pages"], initial_pages)
        bench("migration", "choose", h.SOCKET.parent / "safari.zip", "Safari")
        h.until("Safari discovery", lambda: not state()["discovering"], 20)
        run_step("bookmarks")
        bench("migration", "select", 1); run_step("history")
        h.require("Safari history", state()["historyPlaces"], 9)
        if os.environ.get("ESCALE_MIGRATION_SHOTS"):
            for look in ["light", "dark"]:
                bench("ui", "look", look)
                time.sleep(0.5)
                bench("picture", Path(os.environ["ESCALE_MIGRATION_SHOTS"]) / f"safari-{look}.png")
        h.require("all sources unchanged including active WAL", {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in hashes}, hashes)
        print("ok: Orion WAL, Firefox and Zen sleeping tabs, Safari category actions, source equality", flush=True)
        h.ask("press", code=12, chars="q", mods=["cmd"])
        h.until("quit", lambda: not h.running(), 30)
        h.launch()
        bench("migration", "open"); discover(FIREFOX)
        bench("migration", "destination", len(spaces) - 1)
        run_step("tabs")
        h.require("restart replay", (state()["addedTabs"], state()["keptTabs"]), (0, 2))
        h.require("persisted session", len(read(h.SOCKET.parent / f"session-{target}.json")["tabs"]), 4)
        # The visible row takes a different owner hook from an unloaded Space.
        # Pins go before loose tabs and importing does not change selection.
        before_tabs = bench("tabs")["tabs"]
        visible_pages = bench("space")["pages"]
        selected = next((tab["id"] for tab in before_tabs if tab.get("active")), None)
        bench("migration", "destination", 0)
        run_step("tabs")
        time.sleep(1.5)
        current = read(h.SOCKET.parent / "session.json")["tabs"]
        h.require("visible import persists", len(current), 2)
        h.require("pin monogram and prefix", [tab.get("pin") for tab in current], ["F", None])
        h.require("selection retained", next((tab["id"] for tab in bench("tabs")["tabs"] if tab.get("active")), None), selected)
        h.require("visible import creates no pages", bench("space")["pages"], visible_pages)
        bench("migration", "destination", len(spaces) - 1)
        # Corrupt sessions fail without overwriting the destination.
        broken = h.SOCKET.parent / ("migration-" + slug(FIREFOX)) / "Profiles/work/sessionstore.jsonlz4"
        broken.write_bytes(b"truncated")
        bench("migration", "step", "tabs"); phase("stopped")
        h.require("failed source keeps tabs", len(read(h.SOCKET.parent / f"session-{target}.json")["tabs"]), 4)
        print("ok: restart replay and corrupted-session preservation", flush=True)
    finally:
        if connection is not None:
            connection.close()
        h.command(str(h.ROOT / "fresh.sh"), "wipe")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
