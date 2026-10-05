#!/usr/bin/env python3
"""The bar's extension buttons follow the Space on screen.

The slot in the bar used to look its owner up once and keep it: SwiftUI
reuses a view whose inputs are unchanged. Built in a Space without
extensions, it showed nothing back in the Space that has them until a
relaunch; built in that Space, it showed its buttons everywhere. `bar` in
`bench extensions` lists the anchors the window really holds, so this reads
what is drawn, not the installed list. A local pinned fixture stands in for
Dashlane; the shared runner owns the world, deadlines and cleanup.
"""
from pathlib import Path
import json
import shutil
import tempfile
import suite as h

ROOT = Path(__file__).resolve().parents[2]
FIRST = "00000000-0000-0000-0000-000000000001"
MENU = "__menu"


def obj(*args):
    return json.loads(h.command(str(ROOT / "bench"), "--world", h.WORLD, "--json", *args, seconds=35))


def bar():
    """The drawn buttons: the menu and pinned ids, with their Spaces."""
    anchors = obj("extensions")["bar"]
    for anchor in anchors:
        x, y, width, height = anchor["frame"]
        assert width > 0 and height > 0, anchor
    return {"ids": sorted(a["id"] for a in anchors), "spaces": sorted({a["space"] for a in anchors})}


def shows(label, ids, space):
    expected = {"ids": sorted(ids), "spaces": [space] if ids else []}
    h.wait_for(label, bar, expected, seconds=10)


def current():
    state = obj("space")
    return next(s["id"] for s in state["spaces"] if s["name"] == state["current"])


def main():
    with tempfile.TemporaryDirectory(prefix="escale-extension-bar-") as temp, h.world(None):
        folder = Path(temp) / "fixture"
        shutil.copytree(ROOT / "Tests/Bench/fixtures/shim-extension", folder)
        h.launch()
        obj("ext-folder", str(folder), "--yes")
        row = h.until("fixture loaded", lambda: next(
            (r for r in obj("extensions")["extensions"] if r["name"] == "Escale shim fixture" and r["loaded"]), None), 30)
        ident = row["id"]
        obj("ext-pin", ident, "on")
        shows("pinned button and menu in the first Space", [ident, MENU], FIRST)

        obj("space", "new", "Empty")
        empty = h.until("second Space on screen", lambda: (s if (s := current()) != FIRST else None))
        shows("a Space without extensions shows none of the first one's", [], empty)

        # The reported case: the bar is rebuilt while the empty Space is on
        # screen (here by its layout changing), then the first Space returns.
        for sidebar in ("off", "on"):
            obj("ui", "sidebar", sidebar)
            shows(f"empty Space, sidebar {sidebar}", [], empty)
            obj("space", "go", "1")
            shows(f"first Space back after a rebuild, sidebar {sidebar}", [ident, MENU], FIRST)
            obj("space", "go", "2")
            shows(f"empty Space again, sidebar {sidebar}", [], empty)
        obj("space", "go", "1")
        shows("first Space after the round trips", [ident, MENU], FIRST)

        # A pinned extension that is not loaded loses its button; the menu
        # stays while anything is installed.
        obj("ext-enable", ident, "off")
        shows("menu without a loaded extension", [MENU], FIRST)
        obj("ext-enable", ident, "on")
        shows("pinned button back once loaded", [ident, MENU], FIRST)
        print("extension bar: Space switches, layout rebuilds and an unloaded extension")


if __name__ == "__main__":
    main()
