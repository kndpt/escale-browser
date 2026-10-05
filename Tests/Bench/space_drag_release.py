#!/usr/bin/env python3
"""A Space switch must not strand the mouse gesture that began on a row.

Run after ./build.sh debug. Each case uses a fresh, isolated app identity.
The data pages and seeded bookmarks require no network connection.
"""

import json
import os
from pathlib import Path
import subprocess
import time


ROOT = Path(__file__).resolve().parents[2]


def run(*args, env=None):
    result = subprocess.run([str(arg) for arg in args], cwd=ROOT, env=env,
                            text=True, capture_output=True, timeout=40)
    if result.returncode:
        raise AssertionError(f"{args}: {result.stdout} {result.stderr}")
    return result.stdout.strip()


def case(kind):
    world = f"issue76-release-{kind}"
    env = dict(os.environ, ESCALE_PROBE=world)

    def bench(*args):
        return json.loads(run(ROOT / "bench", "--world", world, "--json", *args))

    run(ROOT / "fresh.sh", "wipe", env=env)
    try:
        run("defaults", "write", f"com.kndpt.escale.test.{world}", "bench", "-bool", "YES")
        run(ROOT / "fresh.sh", "again", env=env)
        bench("ui", "welcome", "off")
        bench("ui", "sidebar", "on")
        target = bench("space", "new", "Target")["spaces"][-1]["id"]
        if kind == "bookmark-merge":
            bench("shelf", "seed")
        bench("space", "go", "1")

        if kind in ("bookmark", "bookmark-merge"):
            bench("shelf", "seed")
            start = (120, 123)
            end = (120, 157) if kind == "bookmark-merge" else (120, 123)
        else:
            if kind == "loose":
                bench("shelf", "seed")
            if kind == "pin-draft":
                bench("press", "17", "t", "cmd")
                source = next(tab for tab in bench("tabs")["tabs"] if tab["active"])
                assert source["url"] == "", source
            else:
                bench("bookmark", f"data:text/html,<title>{kind}</title>", "new")
                source = next(tab for tab in bench("tabs")["tabs"] if kind in tab["title"])
            if kind in ("pin", "pin-draft"):
                bench("pin", source["id"], "on")
                if kind == "pin-draft":
                    bench("field", "unsent pinned address")
                time.sleep(0.5)  # Let the pinned grid replace the loose row.
                start = (100, 95)
            else:
                start = (120, 252)
            end = (120, 210)

        time.sleep(0.6)  # Let the sidebar layout settle before using window points.
        ready = Path(f"/tmp/{world}-ready.png")
        bench("picture", ready)  # Force the actual window and rail to finish layout.
        ready.unlink(missing_ok=True)

        args = (*start, 26, 100, 900, *end)
        release = bench("drag", *args, 900, "live") if kind == "bookmark-merge" else bench("drag", *args, "live")
        assert release["heldSpace"] == target, (kind, release)
        assert bench("space")["current"] == "Target"

        if kind == "bookmark-merge":
            rows = bench("shelf")["rows"]
            assert rows[1]["title"] == "New Folder" and rows[1]["folder"], (release, rows)
            assert {row["title"] for row in rows if row["depth"] == 1} >= {"Swift", "WebKit"}, rows
            bench("space", "go", "1")
            assert "WebKit" not in [row["title"] for row in bench("shelf")["rows"]]
        elif kind == "bookmark":
            rows = bench("shelf")["rows"]
            assert "WebKit" in [row["title"] for row in rows], (release, rows)
            bench("space", "go", "1")
            assert "WebKit" not in [row["title"] for row in bench("shelf")["rows"]]
        else:
            destination_tabs = bench("tabs")["tabs"]
            moved = next((tab for tab in destination_tabs if (tab["active"] if kind == "pin-draft" else kind in tab["title"])), None)
            assert moved is not None, (kind, release, destination_tabs)
            assert moved["id"] != source["id"] and moved["store"] != source["store"], moved
            if kind in ("pin", "pin-draft"):
                assert moved["pin"] != "", moved
            if kind == "pin-draft":
                assert moved["url"] == "" and bench("probe")["typed"] == "unsent pinned address", moved
            bench("space", "go", "1")
            assert all(tab["id"] != source["id"] for tab in bench("tabs")["tabs"])
    finally:
        run(ROOT / "fresh.sh", "wipe", env=env)


if __name__ == "__main__":
    assert (ROOT / "build/Escale.app").exists(), "run ./build.sh debug first"
    for kind in ("loose", "bookmark", "pin", "bookmark-merge", "pin-draft"):
        case(kind)
    print("space drag release: loose tab, bookmark, pin, cross-Space merge and pinned draft passed through AppKit")
