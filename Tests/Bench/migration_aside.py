#!/usr/bin/env python3
"""Aside discovery and per-category actions against synthetic test-world data.

The automatic route only sees migration-aside inside this disposable world's
Store. Assert destination isolation, replay, errors, export fallback, cancellation
and source preservation through the same actions used by the checklist. Every
automatic Chromium brand shares this journey: `run` takes the brand and its seed
(migration_chrome.py), so a brand adds its layout, not a second scenario.
"""
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import sqlite3
import subprocess
import sys

import suite as h
from migration import bench, state, phase, read


def seed(root, host="aside.invalid"):
    root.mkdir(parents=True)
    (root / "Local State").write_text(json.dumps({"profile": {"info_cache": {
        "Default": {"name": "Personal fixture"}, "Profile 1": {"name": "Work fixture"}}}}))
    for index, name in enumerate(["Default", "Profile 1"]):
        profile = root / name
        profile.mkdir()
        (profile / "Bookmarks").write_text(json.dumps({"version": 1, "roots": {"bookmark_bar": {
            "type": "folder", "guid": "root", "name": "Project", "children": [
                {"type": "url", "guid": "site", "name": "Documentation", "url": f"https://{host}/{index}"}]}}}))
        if index == 0:
            with sqlite3.connect(profile / "History") as db:
                db.execute("CREATE TABLE urls(url TEXT,title TEXT,visit_count INTEGER,last_visit_time INTEGER,hidden INTEGER)")
                db.execute("INSERT INTO urls VALUES (?,?,?,?,?)", (f"https://{host}/history", "History", 4, 13434292800000000, 0))


def discover(brand):
    bench("migration", "automatic", brand)
    h.until(f"{brand} discovery", lambda: not state()["discovering"], 20)
    h.require("discovery message", state()["message"], "")


def run_step(category):
    bench("migration", "step", category)
    phase("finished")
    h.require("single category", state()["categories"], [category])
    h.require("category acknowledged", state()["completed"], [category])
    h.require("visible row result", category in state()["stepResults"], True)


def run(brand, layout):
    if h.SOCKET.parent.exists():
        raise AssertionError("refusing to reuse occupied world")
    try:
        h.command(str(h.ROOT / "fresh.sh"), "wipe")
        root = h.SOCKET.parent / f"migration-{brand.lower()}"
        layout(root)
        hashes = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob("*") if p.is_file()}
        h.command("defaults", "write", h.SUITE, "bench", "-bool", "YES")
        h.command("defaults", "write", h.SUITE, "welcomed", "-bool", "YES")
        h.command("defaults", "write", h.SUITE, "spaces", "-bool", "YES")
        checked = (datetime.now(timezone.utc) + timedelta(days=1)).strftime("%Y-%m-%d %H:%M:%S +0000")
        h.command("defaults", "write", h.SUITE, "update.checked", "-date", checked)
        h.launch()
        bench("space", "new", f"{brand} destination", "fresh")
        spaces = bench("space")["spaces"]
        target = spaces[-1]["id"]
        books = h.SOCKET.parent / f"bookmarks-{target}.json"
        history = h.SOCKET.parent / f"history-{target}.json"
        bench("migration", "open")
        h.require("opening does not discover", state()["sources"], [])
        h.require("no browser preselected", state()["browser"], "")
        pages = state()["pages"]
        discover(brand)
        h.require("two named profiles", [x["profile"] for x in state()["sources"]], ["Personal fixture", "Work fixture"])
        h.require("no password dependency", state()["sources"][1]["categories"], ["bookmarks"])
        bench("migration", "destination", len(spaces) - 1)
        h.require(f"{brand} explicitly chosen", state()["browser"], brand)
        run_step("bookmarks")
        bench("resize", 720, 520)
        h.require("resize keeps saved result", state()["phase"], "finished")
        results = state()["stepResults"]
        bench("migration", "pause")
        h.require("Back retains sources", len(state()["sources"]), 2)
        h.require("Back retains results", state()["stepResults"], results)
        discover(brand)
        h.require("refresh retains results", state()["stepResults"], results)
        first = read(books)
        h.require("only chosen category written", read(history), [])
        run_step("history")
        h.require("history volume acknowledged", state()["historyPlaces"], len(read(history)))
        h.require("previous row result retained", set(state()["stepResults"]), {"bookmarks", "history"})
        run_step("bookmarks")
        h.require("repeat adds nothing", state()["addedBookmarks"], 0)
        h.require("repeat preserves data", read(books), first)
        print("ok: automatic discovery, single-click import, retained results and replay")

        bench("migration", "select", 1)
        h.require("profile change clears results", state()["stepResults"], {})
        bench("migration", "step", "history")
        h.require("missing category cannot start", state()["phase"], "choosing")
        run_step("bookmarks")
        h.require("profiles remain distinct", len(read(books)), 2)
        bench("migration", "destination", 0)
        h.require("destination change clears results", state()["stepResults"], {})
        h.require("other Space untouched", read(h.SOCKET.parent / "bookmarks.json"), [])
        bench("migration", "destination", len(spaces) - 1)

        csv = h.SOCKET.parent / f"{brand.lower()}-passwords.csv"
        csv.write_text(f"url,username,password\nhttps://{h.WORLD}.invalid,{h.WORLD},synthetic-{brand.lower()}-value\n")
        bench("migration", "step-export", csv)
        phase("finished")
        h.require(f"CSV keeps {brand} profiles", len(state()["sources"]), 2)
        h.require("isolated password written", state()["passwordAdds"], 1)
        h.require("password result visible", "passwords" in state()["stepResults"], True)
        bench("migration", "step", "passwords")
        h.require("password source released after use", state()["phase"], "finished")
        print("ok: profile and destination isolation, missing category, CSV fallback and secret-source release")

        saved = (root / "Profile 1/Bookmarks").read_bytes()
        (root / "Profile 1/Bookmarks").write_text("malformed")
        bench("migration", "step", "bookmarks")
        phase("stopped")
        h.require("failure visible", bool(state()["message"]), True)
        (root / "Profile 1/Bookmarks").write_bytes(saved)
        run_step("bookmarks")
        h.require("retry adds nothing", state()["addedBookmarks"], 0)
        h.require("source unchanged", {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in hashes}, hashes)
        h.require("no web view created", state()["pages"], pages)
        bench("space", "go", 1)
        h.require("dismiss clears row state", state()["activeStep"], "")
        h.ask("press", code=12, chars="q", mods=["cmd"])
        h.until("quit", lambda: not h.running(), 30)
        h.launch()
        bench("migration", "open")
        discover(brand)
        bench("migration", "destination", len(spaces) - 1)
        run_step("bookmarks")
        h.require("restart replay adds nothing", state()["addedBookmarks"], 0)
        print("ok: corrupt source, retry, dismissal, source preservation and restart replay")
    finally:
        h.command(str(h.ROOT / "fresh.sh"), "wipe")


def main():
    run("Aside", seed)


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
