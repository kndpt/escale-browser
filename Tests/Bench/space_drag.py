#!/usr/bin/env python3
"""Sidebar drags switch Spaces only after a rail-door hold, then keep landing.

Run after ./build.sh debug. The named world is erased in finally. The page
fixture is a data URL, so the drag does not depend on a live website.
"""

import json
import os
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[2]
WORLD = "issue76-space-drag"
PAGE = "data:text/html,<title>Dragged</title>"


def run(*args, env=None):
    result = subprocess.run([str(arg) for arg in args], cwd=ROOT, env=env,
                            text=True, capture_output=True, timeout=40)
    if result.returncode:
        raise AssertionError(f"{args}: {result.stdout} {result.stderr}")
    return result.stdout.strip()


def bench(*args):
    return json.loads(run(ROOT / "bench", "--world", WORLD, "--json", *args))


def current():
    return bench("space")["current"]


def titles():
    return [row["title"] for row in bench("shelf")["rows"]]


def main():
    assert (ROOT / "build/Escale.app").exists(), "run ./build.sh debug first"
    env = dict(os.environ, ESCALE_PROBE=WORLD)
    run(ROOT / "fresh.sh", "wipe", env=env)
    try:
        run("defaults", "write", f"com.kndpt.escale.test.{WORLD}", "bench", "-bool", "YES")
        run(ROOT / "fresh.sh", "again", env=env)
        bench("ui", "welcome", "off")
        bench("ui", "sidebar", "on")
        target_id = bench("space", "new", "Target")["spaces"][-1]["id"]
        bench("space", "go", "1")
        source_id = bench("space")["spaces"][0]["id"]
        bench("shelf", "seed")
        bench("bookmark", PAGE, "new")
        source = next(tab for tab in bench("tabs")["tabs"] if "Dragged" in tab["title"])

        # The tab row's horizontal drag and a short icon pass leave the
        # current Space alone. Even the preview pulse cancels on departure.
        assert bench("drag", "120", "252", "55", "252")["heldSpace"] == source_id
        assert current() == "Personal"
        assert bench("drag", "120", "252", "26", "100")["heldSpace"] == source_id
        assert current() == "Personal"
        assert bench("drag", "120", "252", "26", "100", "600", "120", "252")["heldSpace"] == source_id
        assert current() == "Personal"
        assert any(tab["id"] == source["id"] for tab in bench("tabs")["tabs"])

        # Stay on the second door, then carry the still-held tab into its
        # empty bookmark shelf. The new tab uses the target WebKit store.
        assert bench("drag", "120", "252", "26", "100", "900", "120", "123")["heldSpace"] == target_id
        assert current() == "Target"
        moved = next(tab for tab in bench("tabs")["tabs"] if "Dragged" in tab["title"])
        assert moved["id"] != source["id"] and moved["store"] != source["store"], (source, moved)
        assert any(row["tab"] and row["live"] for row in bench("shelf")["rows"])
        bench("space", "go", "1")
        assert all(tab["id"] != source["id"] for tab in bench("tabs")["tabs"])

        # A saved row can cross by the same door, remain saved there, or
        # become an ordinary tab when released below the destination shelf.
        assert titles() == ["WebKit", "Swift", "Reading"], titles()
        assert bench("drag", "120", "123", "26", "100", "900", "120", "143")["heldSpace"] == target_id
        assert current() == "Target" and "WebKit" in titles(), titles()
        bench("space", "go", "1")
        assert "WebKit" not in titles(), titles()

        # Keep a local data page as a bookmark, so the tab conversion has
        # no dependency on an external site from the seeded bookmark list.
        bench("bookmark", "data:text/html,<title>SavedTab</title>", "new")
        bench("shelf", "keep")
        assert any("SavedTab" in title for title in titles()), titles()
        assert bench("drag", "120", "190", "26", "100", "900", "120", "250")["heldSpace"] == target_id
        assert current() == "Target"
        assert any("SavedTab" in tab["title"] and tab["store"] != "default"
                   for tab in bench("tabs")["tabs"]), bench("tabs")
        assert not any("SavedTab" in title for title in titles()), titles()
        bench("space", "go", "1")
        assert not any("SavedTab" in title for title in titles()), titles()
        assert bench("drag", "120", "157", "26", "100", "900", "120", "180")["heldSpace"] == target_id
        assert current() == "Target" and "Reading" in titles(), titles()
        opened = bench("shelf", "open", "Reading")["rows"]
        assert {"Example", "Deeper"} <= {row["title"] for row in opened}, opened
        bench("space", "go", "1")
        assert "Reading" not in titles(), titles()

        # A blank tab has no URL to carry its unsent address; the gesture
        # captures that draft before showing the destination Space.
        draft_id = bench("space", "new", "Drafts")["spaces"][-1]["id"]
        bench("space", "go", "1")
        # This regression needs a real empty page, not an uncommitted search.
        # Closing the fixture's last loaded tab supplies the existing empty state.
        for tab in bench("tabs")["tabs"]:
            if tab["url"]:
                bench("select", tab["id"])
                bench("press", "13", "w", "cmd")
        blank = next(tab for tab in bench("tabs")["tabs"] if tab["active"])
        assert blank["url"] == "", blank
        bench("field", "unsent local address")
        assert bench("drag", "120", "185", "26", "140", "900")["heldSpace"] == draft_id
        assert current() == "Drafts", bench("space")
        assert bench("probe")["typed"] == "unsent local address"
        assert all(tab["id"] != blank["id"] for tab in bench("tabs")["tabs"])
        print("space drag: edge, hover, tabs, bookmarks, folders and blank draft passed")
    finally:
        run(ROOT / "fresh.sh", "wipe", env=env)


if __name__ == "__main__":
    main()
