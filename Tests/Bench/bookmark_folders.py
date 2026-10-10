#!/usr/bin/env python3
"""Bookmark folders: real sidebar drags, folder persistence and visible open
pages; the Bookmarks panel by real key presses: ↑ and ↓ over the rows on
show, Return and ⌘Return on a site, → and ← on a folder, ⌫ on a row, Escape,
also once the page under the panel has taken the keyboard back; then each
right-click action of the column and the Bookmarks panel, chosen from the real
context menu: Open in New Tab, Copy Link, Edit… (an
empty or invalid address refused), New Folder named in place, and Open All in
Tabs, asked first above its threshold and private from a private tab.

Run after ./build.sh debug, in front: the menus need the pointer. The world is
unique to this scenario (ESCALE_WORLD) and wiped in finally. Pages use a data
URL or a *.localhost site, so the test makes no request beyond this Mac. Copy
Link writes the clipboard; its text is put back at the end. Coordinates assume
the fresh world's 1180×780 window. Not covered: the panel's Edit… saving (the
column's covers the shared action) and opening a folder past the threshold
from the panel (asked, then cancelled).
"""

import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
WORLD = os.environ.get("ESCALE_WORLD", "issue76-folders-regression")
KEYMARK = "data:text/html,<title>KeyMark</title><textarea></textarea>"
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


def launch(env):
    run(ROOT / "fresh.sh", "wipe", env=env)
    run("defaults", "write", f"com.kndpt.escale.test.{WORLD}", "bench", "-bool", "YES")
    run(ROOT / "fresh.sh", "again", env=env)


def wait_for(check, what, seconds=5):
    limit = time.monotonic() + seconds
    while True:
        found = check()
        if found:
            return found
        if time.monotonic() > limit:
            raise AssertionError(f"timed out waiting for {what}")
        time.sleep(0.1)


def column_y(title):
    """A column row's middle: 34 points a row, the first at 124."""
    return str(124 + 34 * titles().index(title))


def panel_y(index):
    """The Bookmarks panel's row at that place: 28 points a row, from 196."""
    return str(196 + 28 * index)


def menu(x, y):
    state = bench("pointer", "menu", x, y)
    assert state["tracking"], state
    return [item["title"] for item in state["items"]]


def choose(x, y, title):
    items = menu(x, y)
    assert title in items, items
    bench("pointer", "choose", str(items.index(title)))


def keys(*presses):
    # A key reaches the sheet only while the app is in front; another app
    # coming forward meanwhile would take it to the window instead.
    for code, chars, *mods in presses:
        if not bench("probe")["appActive"]:
            bench("pointer", "move", "590", "12")
        bench("press", str(code), chars, *mods)


def finish(key, check, what):
    """The key that ends a step; pressed again if another app had the
    keyboard, as the Macs these run on are shared."""
    for _ in range(3):
        keys(key)
        try:
            return wait_for(check, what, seconds=2)
        except AssertionError:
            pass
    raise AssertionError(f"timed out waiting for {what}")


def typed(text):
    codes = {"a": 0, "s": 1, "d": 2, "c": 8, "e": 14, "o": 31, "p": 35, "l": 37, "n": 45}
    keys(*((codes[letter], letter) for letter in text))


TAB, RIGHT, RETURN, DELETE, ESCAPE = (48, "\t"), (124, "\uf703"), (36, "\r"), (51, "\x7f"), (53, "\x1b")
DOWN, UP, LEFT = (125, "\uf701"), (126, "\uf700"), (123, "\uf702")
# A posted Return or Escape in the sheet's field goes to the field before
# the sheet's buttons; Enter and ⌘. reach the buttons, as by hand.
ENTER, CANCEL = (76, "\x03"), (47, ".", "cmd")


def sheet():
    """The alert on the window, by its window number, or 0."""
    windows = bench("probe")["windows"]
    return next((w["number"] for w in windows if w["kind"] == "_NSAlertPanel" and w["visible"]), 0)


def row(title):
    return next((r for r in shelf() if r["title"] == title), None)


def tabs():
    return bench("tabs")["tabs"]


def active():
    return next((t for t in tabs() if t["active"]), None)


def clipboard():
    return subprocess.run(["pbpaste"], text=True, capture_output=True, timeout=5).stdout


def drags(env):
    launch(env)
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
    print("bookmark folders: drag delay, cancellation, merge, insertion, collapse and restart passed")


def press(key, times=1, *mods):
    for _ in range(times):
        bench("press", str(key[0]), key[1], *mods)


def show_panel():
    bench("ui", "bookmarks", "on")
    wait_for(lambda: bench("probe")["bookmarks"], "Bookmarks open")


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
    count = len(tabs())

    # Nothing chosen yet: the first ↓ takes the top row. Return opens the
    # site in the tab on screen.
    show_panel()
    press(DOWN, mark + 1)
    press(RETURN)
    wait_for(lambda: "KeyMark" in active()["url"], "KeyMark in the tab on screen", seconds=10)
    assert len(tabs()) == count and not bench("probe")["bookmarks"]

    # ⌘Return opens it apart.
    show_panel()
    press(UP, len(top) + 1)
    press(DOWN, mark)
    press(RETURN, 1, "cmd")
    wait_for(lambda: len(tabs()) == count + 1, "KeyMark in a new tab", seconds=10)
    assert "KeyMark" in active()["url"], active()

    # The page under the panel takes the keyboard back with a real click:
    # the panel's keys still walk its list. → opens Reading, ↓ steps into it,
    # ⌫ takes its first row.
    inside = reading()
    show_panel()
    bench("tap", active()["id"], "textarea")
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
    wait_for(lambda: not bench("probe")["bookmarks"], "Escape closes Bookmarks", seconds=10)
    print("bookmark panel keys: ↑ ↓ held in bounds, Return, ⌘Return, → ←, ⌫ and Escape passed")


def column(x="120"):
    # A site: its own items, Edit… in place of Rename.
    items = menu(x, column_y("Site 0"))
    bench("pointer", "cancel")
    assert {"Open in New Tab", "Copy Link", "Edit…", "New Folder"} <= set(items), items
    assert "Rename" not in items and "Open All in Tabs" not in items, items

    before = len(tabs())
    choose(x, column_y("Site 0"), "Open in New Tab")
    wait_for(lambda: len(tabs()) == before + 1, "a new tab")
    assert active()["url"] == "http://site0.localhost/", active()
    assert not row("Site 0")["tab"], "an ordinary tab, not the bookmark's own"

    choose(x, column_y("Site 0"), "Copy Link")
    wait_for(lambda: clipboard() == "http://site0.localhost/", "the link on the clipboard")

    # Edit…: the title and the address together.
    choose(x, column_y("Site 0"), "Edit…")
    wait_for(sheet, "the edit sheet")
    typed("local")
    keys(TAB, RIGHT, (0, "a"))
    edited = finish(ENTER, lambda: row("local"), "the edited row")
    assert edited["url"] == "http://site0.localhost/a", edited
    wait_for(lambda: not sheet(), "the sheet to close")

    # An empty address, then one that is not a place: each refused, the sheet
    # back again with a new window, the bookmark unchanged.
    choose(x, column_y("local"), "Edit…")
    first = wait_for(sheet, "the edit sheet")
    keys(TAB, DELETE)
    second = finish(ENTER, lambda: sheet() not in (0, first) and sheet(), "the sheet back after an empty address")
    typed("nope")
    finish(ENTER, lambda: sheet() not in (0, second), "the sheet back after an invalid address")
    finish(CANCEL, lambda: not sheet(), "the sheet to close")
    assert row("local")["url"] == "http://site0.localhost/a", row("local")

    # New Folder beside a site, named in place.
    choose(x, column_y("local"), "New Folder")
    made = wait_for(lambda: row("New Folder"), "the new folder")
    assert made["folder"] and made["naming"] and made["depth"] == 1, made
    assert titles().index("New Folder") == titles().index("local") + 1, titles()
    typed("docs")
    named = finish(RETURN, lambda: row("docs"), "the folder named")
    assert named["folder"] and not named["naming"], named

    # A folder: its own items; New Folder inside it, which opens it.
    items = menu(x, column_y("Reading"))
    bench("pointer", "cancel")
    assert {"Open All in Tabs", "Rename", "New Folder"} <= set(items), items
    assert not {"Edit…", "Copy Link", "Open in New Tab"} & set(items), items
    choose(x, column_y("Reading"), "New Folder")
    inside = wait_for(lambda: row("New Folder"), "the folder inside Reading")
    assert inside["naming"] and inside["depth"] == 1 and row("Reading")["open"], inside
    finish(RETURN, lambda: not row("New Folder")["naming"], "the name kept")
    bench("shelf", "close", "Reading")
    time.sleep(0.6)  # the folder's rows have finished leaving

    # Open All in Tabs: its folder included, only the first page built.
    before = len(tabs())
    choose(x, column_y("Bench"), "Open All in Tabs")
    wait_for(lambda: len(tabs()) == before + 2, "two tabs")
    row_tabs = tabs()
    lead = active()
    rest = row_tabs[row_tabs.index(lead) + 1]
    assert lead["url"] == "http://site0.localhost/a" and not lead["asleep"], lead
    assert rest["url"] == "http://site1.localhost/" and rest["asleep"] and not rest["view"], rest

    # From a private tab, every one of them private, the waiting one too.
    keys((45, "n", "cmd", "shift"))
    bench("field", "data:text/html,<title>Private</title>", "go")
    wait_for(lambda: (active() or {}).get("shy"), "a private tab")
    before = len(tabs())
    choose(x, column_y("Bench"), "Open All in Tabs")
    wait_for(lambda: len(tabs()) == before + 2, "two private tabs")
    row_tabs = tabs()
    lead = active()
    rest = row_tabs[row_tabs.index(lead) + 1]
    assert lead["shy"] and rest["shy"] and rest["asleep"], (lead, rest)

    # Past the threshold it asks: Cancel opens nothing, Open All every one.
    bench("shelf", "many", "16")
    time.sleep(0.6)
    before = len(tabs())
    choose(x, column_y("Bench"), "Open All in Tabs")
    wait_for(sheet, "the question")
    finish(ESCAPE, lambda: not sheet(), "the question to close")
    assert len(tabs()) == before, len(tabs())
    choose(x, column_y("Bench"), "Open All in Tabs")
    wait_for(sheet, "the question")
    finish(RETURN, lambda: len(tabs()) == before + 16, "sixteen tabs")
    assert sum(t["asleep"] for t in tabs()) >= 15, tabs()


def panel(x="400"):
    # WebKit, Swift, Reading, Bench; Bench's sites once it is opened there.
    bench("ui", "bookmarks", "on")
    wait_for(lambda: bench("probe")["bookmarks"], "the panel")
    items = menu(x, panel_y(1))
    bench("pointer", "cancel")
    assert {"Open", "Open in New Tab", "Copy Link", "Edit…", "New Folder"} <= set(items), items
    assert "Rename" not in items, items
    choose(x, panel_y(1), "Copy Link")
    wait_for(lambda: clipboard() == "https://www.swift.org/", "the panel's link on the clipboard")
    choose(x, panel_y(1), "Edit…")
    wait_for(sheet, "the panel's edit sheet")
    finish(CANCEL, lambda: not sheet(), "the sheet to close")
    assert row("Swift")["url"] == "https://www.swift.org/", row("Swift")

    items = menu(x, panel_y(3))
    bench("pointer", "cancel")
    assert {"Open All in Tabs", "Rename", "New Folder"} <= set(items), items
    assert "Edit…" not in items, items
    choose(x, panel_y(3), "Open All in Tabs")
    wait_for(sheet, "the panel's question")
    finish(ESCAPE, lambda: not sheet(), "the question to close")

    bench("pointer", "click", x, panel_y(3))  # Bench opens in place
    choose(x, panel_y(4), "New Folder")
    typed("panel")
    finish(RETURN, lambda: bench("shelf", "open", "Bench") and "panel" in titles(), "the panel's folder named")
    assert titles().index("panel") == titles().index("Site 0") + 1, titles()

    before = len(tabs())
    choose(x, panel_y(4), "Open in New Tab")
    wait_for(lambda: len(tabs()) == before + 1, "a tab from the panel")
    assert active()["url"] == "http://site0.localhost/", active()
    assert not bench("probe")["bookmarks"], "the panel closes on opening a page"


def menus(env):
    launch(env)
    bench("ui", "welcome", "off")
    bench("ui", "sidebar", "on")
    bench("shelf", "seed")
    bench("shelf", "many", "2")
    bench("shelf", "open", "Bench")
    time.sleep(0.6)  # the sidebar's 500 ms fold animation has finished
    assert titles() == ["WebKit", "Swift", "Reading", "Bench", "Site 0", "Site 1"], titles()
    column()
    bench("shelf", "close", "Bench")
    time.sleep(0.6)
    panel()
    print("bookmark menus: new tab, copy, edit and its refusals, new folder and open all passed in the column and the panel")


def main():
    env = dict(os.environ, ESCALE_PROBE=WORLD)
    kept = clipboard()
    try:
        drags(env)
        keyboard()
        menus(env)
    finally:
        run(ROOT / "fresh.sh", "wipe", env=env)
        subprocess.run(["pbcopy"], input=kept, text=True, timeout=5)


if __name__ == "__main__":
    main()
