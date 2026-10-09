#!/usr/bin/env python3
"""Bookmark folders: real sidebar drags, folder persistence and visible open
pages; then the Bookmarks panel by real key presses: ↑ and ↓ over the rows on
show, Return and ⌘Return on a site, → and ← on a folder, ⌫ on a row, Escape.

Run after ./build.sh debug. The world is unique to this scenario and wiped in
finally. Pages use a data URL, so the test makes no network request.
"""

import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
WORLD = "issue76-folders-regression"
DOWN, UP, LEFT, RIGHT = ("125", "\uf701"), ("126", "\uf700"), ("123", "\uf702"), ("124", "\uf703")
RETURN, DELETE, ESCAPE = ("36", "\r"), ("51", "\x7f"), ("53", "\x1b")
KEYMARK = "data:text/html,<title>KeyMark</title>"
ELSEWHERE = "data:text/html,<title>Elsewhere</title>"


def run(*args, env=None):
    result = subprocess.run([str(arg) for arg in args], cwd=ROOT, env=env,
                            text=True, capture_output=True, timeout=30)
    if result.returncode:
        raise AssertionError(f"{args}: {result.stderr.strip()}")
    return result.stdout.strip()


def bench(*args):
    return json.loads(run(ROOT / "bench", "--world", WORLD, "--json", *args))


def shelf():
    return bench("shelf")["rows"]


def titles():
    return [row["title"] for row in shelf()]


def press(key, times=1, *mods):
    for _ in range(times):
        bench("press", *key, *mods)


def active():
    return next(tab for tab in bench("tabs")["tabs"] if tab["active"])


def until(what, condition, seconds=10):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if condition():
            return
        time.sleep(0.15)
    raise AssertionError(f"{what}: timed out after {seconds}s")


def panel():
    bench("ui", "bookmarks", "on")
    until("Bookmarks open", lambda: bench("probe")["bookmarks"])


def roots():
    return [row["title"] for row in shelf() if row["depth"] == 0]


def reading():
    """The titles in Reading, opened in the column to be read."""
    rows = bench("shelf", "open", "Reading")["rows"]
    at = next(i for i, row in enumerate(rows) if row["title"] == "Reading")
    inside = []
    for row in rows[at + 1:]:
        if row["depth"] == 0:
            break
        if row["depth"] == 1:
            inside.append(row["title"])
    return inside


def keyboard():
    """Reopened before its closing has finished, the panel keeps its last
    selection, so each step but the first starts from the top: ↑ is held there."""
    bench("bookmark", KEYMARK, "new")
    bench("shelf", "keep")
    bench("bookmark", ELSEWHERE, "new")
    top = roots()
    # Kept before its page has loaded, the bookmark is named by its address.
    mark = next(i for i, title in enumerate(top) if "KeyMark" in title)
    folder = top.index("Reading")
    assert folder + 1 < len(top), top
    tabs = len(bench("tabs")["tabs"])

    # Nothing chosen yet: the first ↓ takes the top row. Return opens the
    # site in the tab on screen.
    panel()
    press(DOWN, mark + 1)
    press(RETURN)
    until("KeyMark in the tab on screen", lambda: "KeyMark" in active()["url"])
    assert len(bench("tabs")["tabs"]) == tabs and not bench("probe")["bookmarks"]

    # ⌘Return opens it apart.
    panel()
    press(UP, len(top) + 1)
    press(DOWN, mark)
    press(RETURN, 1, "cmd")
    until("KeyMark in a new tab", lambda: len(bench("tabs")["tabs"]) == tabs + 1)
    assert "KeyMark" in active()["url"], active()

    # → opens Reading, ↓ steps into it, ⌫ takes its first row.
    inside = reading()
    panel()
    press(UP, len(top) + 1)
    press(DOWN, folder)
    press(RIGHT)
    press(DOWN)
    press(DELETE)
    assert reading() == inside[1:], (inside, reading())
    assert roots() == top, roots()

    # Back up to Reading, ← shuts it: ↓ now lands on the next top row.
    press(UP)
    press(LEFT)
    press(DOWN)
    press(DELETE)
    assert roots() == top[:folder + 1] + top[folder + 2:], roots()
    assert reading() == inside[1:], reading()

    press(ESCAPE)
    until("Escape closes Bookmarks", lambda: not bench("probe")["bookmarks"])


def main():
    env = dict(os.environ, ESCALE_PROBE=WORLD)
    run(ROOT / "fresh.sh", "wipe", env=env)
    try:
        run("defaults", "write", f"com.kndpt.escale.test.{WORLD}", "bench", "-bool", "YES")
        run(ROOT / "fresh.sh", "again", env=env)
        bench("ui", "welcome", "off")
        bench("ui", "sidebar", "on")
        bench("shelf", "seed")
        time.sleep(0.6)  # the sidebar's 500 ms fold animation has finished
        assert titles() == ["WebKit", "Swift", "Reading"]

        # The lower edge remains a reorder zone, even between two sites.
        bench("drag", "120", "123", "120", "169")
        assert titles() == ["Swift", "WebKit", "Reading"], titles()
        bench("drag", "120", "123", "120", "169")
        assert titles() == ["WebKit", "Swift", "Reading"], titles()

        # Releasing too soon, then leaving after the preview pulse, creates no
        # folder. The destination's middle is the merge zone in both drags.
        bench("drag", "120", "123", "120", "157")
        assert "New Folder" not in titles(), titles()
        bench("drag", "120", "123", "120", "157", "600", "120", "123")
        assert "New Folder" not in titles(), titles()

        bench("drag", "120", "123", "120", "157", "1000")
        assert titles() == ["New Folder", "Swift", "WebKit", "Reading"], titles()
        assert shelf()[0]["open"] is True

        # Moving a child to an existing folder opens the destination.
        bench("drag", "120", "157", "120", "225")
        rows = shelf()
        assert rows[2]["title"] == "Reading" and rows[2]["open"] is True, rows
        assert rows[-1]["title"] == "Swift" and rows[-1]["depth"] == 1, rows

        # A loose tab becomes a bookmark in that folder and remains a live tab.
        bench("bookmark", "data:text/html,<title>FolderTab</title>", "new")
        bench("drag", "125", "352", "125", "191")
        rows = shelf()
        assert any(row["title"] == "FolderTab" and row["tab"] for row in rows), rows
        closed = bench("shelf", "close", "Reading")["rows"]
        assert [row["title"] for row in closed] == ["New Folder", "WebKit", "Reading", "FolderTab"], closed
        assert closed[-1]["tab"] and closed[-1]["live"], closed
        bench("press", "13", "w", "cmd")
        assert "FolderTab" not in titles(), titles()
        opened = bench("shelf", "open", "Reading")["rows"]
        assert {row["title"] for row in opened} >= {"Example", "Swift", "FolderTab"}, opened
        assert not next(row for row in opened if row["title"] == "FolderTab")["tab"], opened

        # An orderly quit flushes the folder tree; the tab it owned is a
        # bookmark on the next launch, not a restored extra tab.
        bench("press", "12", "q", "cmd")
        run(ROOT / "fresh.sh", "again", env=env)
        persisted = shelf()
        assert any(row["title"] == "New Folder" and row["folder"] for row in persisted), persisted
        assert any(row["title"] == "Reading" and row["folder"] for row in persisted), persisted
        bench("shelf", "open", "Reading")
        assert "FolderTab" in titles(), titles()

        keyboard()
        print("bookmark folders: drag delay, cancellation, merge, insertion, collapse and restart passed")
        print("bookmark panel keys: ↑ ↓ held in bounds, Return, ⌘Return, → ←, ⌫ and Escape passed")
    finally:
        run(ROOT / "fresh.sh", "wipe", env=env)


if __name__ == "__main__":
    main()
