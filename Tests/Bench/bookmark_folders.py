#!/usr/bin/env python3
"""Bookmark folders: real sidebar drags, folder persistence and visible open
pages.

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
        print("bookmark folders: drag delay, cancellation, merge, insertion, collapse and restart passed")
    finally:
        run(ROOT / "fresh.sh", "wipe", env=env)


if __name__ == "__main__":
    main()
