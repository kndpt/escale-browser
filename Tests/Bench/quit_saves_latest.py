#!/usr/bin/env python3
"""Quitting writes the latest state, and the next launch restores it.

The ordering itself is proven by the Swift tests on the real writer
(Tests/EscaleTests/WriterTests.swift). This checks the wiring they can't: that
⌘Q hands every debounced store to its writer and waits for it. A tab is
sent to a new page and the app quit as soon as it has loaded, inside the
session's 1.2 s and the history's 1.5 s debounces; the session and history
files must hold that page after the quit, and the relaunched world must
restore it.

Runs in its own world (ESCALE_WORLD, default "a02-quit"), launched through
fresh.sh from build/Escale.app — ./build.sh first — and wiped afterwards
unless KEEP=1. Pages come from a local server on 127.0.0.1; nothing else is
fetched. Exits non-zero, with expected and actual state, on failure.
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
WORLD = os.environ.get("ESCALE_WORLD", "a02-quit")
FOLDER = Path.home() / "Library/Application Support" / f"Escale ({WORLD})"
BINARY = str(REPO / "build/probe" / WORLD / "Escale.app/Contents/MacOS/Escale")
SUITE = f"com.kndpt.escale.test.{WORLD}"


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/") or "home"
        body = f"<title>A02 {name}</title><h1>{name}</h1>".encode()
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


def running():
    lines = subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True, text=True).stdout
    return [line.split(None, 1)[0] for line in lines.splitlines()
            if line.strip().split(None, 1)[-1] == BINARY]


def until(what, check, deadline):
    end = time.monotonic() + deadline
    while time.monotonic() < end:
        try:
            if check():
                return
        except (subprocess.TimeoutExpired, AssertionError, OSError, ValueError):
            pass
        time.sleep(0.2)
    raise AssertionError(f"timed out after {deadline}s waiting for {what}")


def listening():
    return bench("tabs", deadline=5, check=False).returncode == 0


def loaded(url):
    """The active tab is at url and done loading, per `bench tabs`."""
    for line in bench("tabs", deadline=5).stdout.splitlines():
        if line.startswith("●"):
            return line.rstrip().endswith(url)
    return False


def saved(name):
    return json.loads((FOLDER / name).read_text())


def session_urls():
    return [tab["url"] for tab in saved("session.json")["tabs"]]


def history_urls():
    return [visit["url"] for visit in saved("history.json")]


def launch():
    if running():
        raise AssertionError(f"world {WORLD} is already running")
    run([REPO / "fresh.sh", "again"], deadline=60)
    until("the bench to answer", listening, 60)


def main():
    if not (REPO / "build/Escale.app").exists():
        raise AssertionError("no build/Escale.app: run ./build.sh first")
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://localhost:{server.server_address[1]}"
    first, latest = f"{base}/first", f"{base}/latest"
    try:
        run([REPO / "fresh.sh", "wipe"], deadline=60)
        run(["defaults", "write", SUITE, "bench", "-bool", "YES"])
        launch()

        # A settled state, written by the debounces on their own.
        bench("bookmark", first, "new", deadline=60)
        until("the first page in session.json and history.json",
              lambda: first in session_urls() and first in history_urls(), 10)

        # The same tab sent on through the address field, and ⌘Q as soon as
        # the page has loaded: inside both debounces.
        bench("field", latest, "go", deadline=30)
        until("the latest page to load", lambda: loaded(latest), 10)
        bench("press", "12", "q", "cmd", deadline=10, check=False)
        until("the app to quit", lambda: not running(), 30)

        urls = session_urls()
        if urls != [latest]:
            raise AssertionError(f"session.json after quit: expected [{latest}], found {urls}")
        visits = history_urls()
        if first not in visits or latest not in visits:
            raise AssertionError(f"history.json after quit: expected {first} and {latest}, found {visits}")

        launch()
        tabs = bench("tabs").stdout
        if latest not in tabs or first in tabs:
            raise AssertionError(f"restored tabs: expected only {latest}:\n{tabs}")
        print(f"ok: quit wrote the latest tab and {len(visits)} visits, and the world restored it")
        return 0
    except (AssertionError, subprocess.TimeoutExpired) as failure:
        print(f"FAIL: {failure}", file=sys.stderr)
        return 1
    finally:
        server.shutdown()
        if os.environ.get("KEEP") != "1":
            run([REPO / "fresh.sh", "wipe"], deadline=60, check=False)


if __name__ == "__main__":
    sys.exit(main())
