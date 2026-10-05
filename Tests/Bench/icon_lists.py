#!/usr/bin/env python3
"""A long list shows site icons without reading them while it is drawn.

500 bookmarks on synthetic hosts, each with its icon already on disk and none
in memory — the first time a long shelf is shown after a launch. The shelf is
unfolded from a folded state and timed until the window rests; then the run
waits for every icon to be held, and checks the shelf reached its icons
without a tap or a fetch. Reports the milliseconds to rest and to settle.

Run after ./build.sh debug. Its own world, wiped at the end. Nothing is fetched:
the hosts are `siteN.localhost` and the icons are written beforehand.
"""

from pathlib import Path
import json
import os
import struct
import subprocess
import time
import zlib

ROOT = Path(__file__).resolve().parents[2]
# The runner's own world when it gives one, so campaigns beside each other never share it.
WORLD = os.environ.get("ESCALE_VERIFY_WORLD", "icon-lists")
SUITE = f"com.kndpt.escale.test.{WORLD}"
FOLDER = Path.home() / "Library/Application Support" / f"Escale ({WORLD})"
COUNT = 500


def png(seed):
    colour = bytes(((seed * 67) % 256, (seed * 131) % 256, (seed * 29) % 256, 255))
    raw = b"".join(b"\x00" + colour * 32 for _ in range(32))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 32, 32, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def run(*args, env=None):
    result = subprocess.run([str(arg) for arg in args], cwd=ROOT, env=env, capture_output=True,
                            text=True, timeout=60)
    if result.returncode:
        raise AssertionError(f"{args}: {result.stdout} {result.stderr}")
    return result.stdout


def bench(*args):
    return json.loads(run(ROOT / "bench", "--world", WORLD, "--json", *args))


def until(label, predicate, seconds=20):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        try:
            if predicate():
                return
        except (AssertionError, json.JSONDecodeError, subprocess.TimeoutExpired):
            pass
        time.sleep(0.1)
    raise AssertionError(f"timed out: {label}")


def main():
    env = dict(os.environ, ESCALE_PROBE=WORLD)
    try:
        run("./fresh.sh", "wipe", env=env)
        (FOLDER / "icons").mkdir(parents=True)
        for index in range(COUNT):
            (FOLDER / "icons" / f"site{index}.localhost.png").write_bytes(png(index))
        run("defaults", "write", SUITE, "bench", "-bool", "YES")
        run("./fresh.sh", "again", env=env)
        until("bench", lambda: bool(bench("caches")))
        bench("ui", "welcome", "off")
        bench("ui", "shelf", "on")
        bench("shelf", "fold")
        bench("shelf", "many", str(COUNT))
        assert bench("caches")["icons"]["memory"] == 0, "icons were held before the shelf was shown"

        shown = bench("shelf", "unfold", "rest")
        started = time.monotonic()
        until("every icon held", lambda: bench("caches")["icons"]["memory"] >= COUNT)
        settled = time.monotonic() - started
        held = bench("caches")["icons"]
        assert held["fetching"] == 0 and held["waiting"] == 0, f"a fetch was started: {held}"
        print(json.dumps({"rows": len(shown["rows"]), "restedMs": round(shown["rested"], 1),
                          "settledAfterMs": round(settled * 1000), "icons": held}))
    finally:
        run("./fresh.sh", "wipe", env=env)


if __name__ == "__main__":
    main()
