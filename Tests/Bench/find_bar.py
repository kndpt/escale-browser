#!/usr/bin/env python3
"""Find on page, driven by real keys.

What is looked for and whether the page holds it are held by the find bar's
own owner (Find in Sources/Escale/Page/Find.swift); Browser keeps whether
the bar is up. Keys are posted to the app as a whole (`bench press`), so they
reach the bar's own text field as a hand's would, and the state is read back
with `bench probe`:

1. ⌘F on a page: the bar comes up.
2. A word the page holds, a key at a time: found. One more letter it
   doesn't hold: missed. A backspace: found again. ⌘G: still found.
3. Another tab (⌃Tab) with the bar up, and Escape: the bar goes, with what
   was asked and missed.
4. ⌘F while New Tab search is pending: no find bar behind search.
5. Opening and cancelling New Tab closes find without building a page.

Runs in its own world (ESCALE_WORLD, default "find-bar"), launched through
fresh.sh from build/Escale.app — ./build.sh first — and wiped afterwards
unless KEEP=1. Pages come from a local server on 127.0.0.1; nothing else is
fetched. Exits non-zero, with expected and actual state for every failed check.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import os
import subprocess
import sys
import threading
import time

REPO = Path(__file__).resolve().parents[2]
WORLD = os.environ.get("ESCALE_WORLD", "find-bar")
BINARY = str(REPO / "build/probe" / WORLD / "Escale.app/Contents/MacOS/Escale")
SUITE = f"com.kndpt.escale.test.{WORLD}"

# Key codes as a keyboard sends them.
KEYS = {"b": "11", "a": "0", "n": "45", "q": "12", "f": "3", "g": "5", "t": "17"}
ESCAPE, BACKSPACE, TAB = ("53", "\x1b"), ("51", "\x7f"), ("48", "\t")

failures = []


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/") or "home"
        body = f"<title>Find {name}</title><p>an apple and a banana on {name}</p>".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def run(args, deadline=30, check=True):
    env = dict(os.environ, ESCALE_PROBE=WORLD)
    env.pop("ESCALE_MEASURE", None)
    done = subprocess.run([str(a) for a in args], cwd=REPO, env=env, capture_output=True,
                          text=True, timeout=deadline)
    if check and done.returncode != 0:
        raise AssertionError(f"{' '.join(map(str, args))} exited {done.returncode}: {done.stderr.strip()}")
    return done


def bench(*args, deadline=30, check=True):
    return run([REPO / "bench", "--world", WORLD, *args], deadline=deadline, check=check)


def press(key, *mods):
    bench("press", *key, *mods, deadline=10)


def letter(ch, *mods):
    press((KEYS[ch], ch), *mods)


def running():
    lines = subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True, text=True).stdout
    return [line.split(None, 1)[0] for line in lines.splitlines()
            if line.strip().split(None, 1)[-1] == BINARY]


def until(what, check, deadline=10):
    end = time.monotonic() + deadline
    while time.monotonic() < end:
        try:
            if check():
                return
        except (subprocess.TimeoutExpired, AssertionError, OSError, ValueError):
            pass
        time.sleep(0.2)
    raise AssertionError(f"timed out after {deadline}s waiting for {what}")


def settle(what, **expected):
    """The probe, once every field named holds its value (or 5 s pass)."""
    state = {}
    end = time.monotonic() + 5
    while time.monotonic() < end:
        state = json.loads(bench("--json", "probe").stdout)
        if all(state.get(key) == value for key, value in expected.items()):
            return
        time.sleep(0.2)
    for key, value in expected.items():
        if state.get(key) != value:
            failures.append(f"{what}: {key} expected {value!r}, found {state.get(key)!r}")


def active():
    for line in bench("tabs", deadline=5).stdout.splitlines():
        if line.startswith("●"):
            return line.rstrip().rstrip("…").split()[-1]
    return None


def go(url):
    bench("field", url, "go", deadline=30)
    until(f"{url} on screen", lambda: active() == url, 15)


def exercise(base):
    go(f"{base}/one")
    press(("17", "t"), "cmd")
    go(f"{base}/two")

    # 1. ⌘F: the bar.
    letter("f", "cmd")
    settle("⌘F", finding=True, needle="", missed=False)

    # 2. Found, missed, found again, and ⌘G.
    for ch in "banana":
        letter(ch)
    settle("typed a word the page holds", needle="banana", missed=False)
    letter("q")
    settle("a letter too many", needle="bananaq", missed=True)
    press(BACKSPACE)
    settle("a backspace", needle="banana", missed=False)
    letter("g", "cmd")
    settle("⌘G", needle="banana", missed=False)

    # 3. Another tab with the bar up, then Escape.
    letter("q")
    settle("missed again before leaving", missed=True)
    press(TAB, "ctrl")
    until("the other tab", lambda: active() == f"{base}/one", 10)
    press(ESCAPE)
    settle("Escape", finding=False, needle="", missed=False)

    # 4. New Tab search owns the keyboard; no page find bar behind it.
    press(("17", "t"), "cmd")
    letter("f", "cmd")
    time.sleep(0.5)
    settle("⌘F on a blank tab", finding=False)

    # 5. Opening and cancelling search closes find without building a page.
    press(ESCAPE)
    until("back on a page", lambda: active() == f"{base}/one", 10)
    letter("f", "cmd")
    for ch in "ban":
        letter(ch)
    settle("the bar up again", finding=True, needle="ban")
    before = len(json.loads(bench("--json", "space").stdout)["pages"])
    press(("17", "t"), "cmd")
    time.sleep(1)
    press(ESCAPE)
    settle("Escape from a blank tab", finding=False, needle="")
    time.sleep(1)
    after = len(json.loads(bench("--json", "space").stdout)["pages"])
    if after != before:
        failures.append(f"Escape from a blank tab: pages expected {before}, found {after}")


def main():
    if not (REPO / "build/Escale.app").exists():
        raise SystemExit("no build/Escale.app: run ./build.sh first")
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://localhost:{server.server_address[1]}"
    try:
        if running():
            raise AssertionError(f"world {WORLD} is already running")
        run([REPO / "fresh.sh", "wipe"], deadline=60)
        run(["defaults", "write", SUITE, "bench", "-bool", "YES"])
        run([REPO / "fresh.sh", "again"], deadline=60)
        until("the bench to answer", lambda: bench("tabs", deadline=5, check=False).returncode == 0, 60)
        exercise(base)
    except (AssertionError, subprocess.TimeoutExpired, json.JSONDecodeError) as failure:
        failures.append(str(failure))
    finally:
        server.shutdown()
        if os.environ.get("KEEP") != "1":
            run([REPO / "fresh.sh", "wipe"], deadline=60, check=False)
    if failures:
        for failure in failures:
            print(f"FAIL: {failure}", file=sys.stderr)
        return 1
    print("ok: ⌘F, found, missed, found again, ⌘G, another tab and Escape, no bar on a blank tab, "
          "and closing the bar from a blank tab built it no page")
    return 0


if __name__ == "__main__":
    sys.exit(main())
