#!/usr/bin/env python3
"""The tab you were on comes back, with the tabs a session leaves out.

A session keeps no private tab and no blank one, so the tab you were looking
at has to be counted among the ones it keeps. Which index a row of kept and
left-out tabs saves is proven by the Swift tests on the rule itself
(Tests/EscaleTests/SessionTests.swift); this checks that the save uses it,
and that a relaunch follows it in the space on screen and in a parked one:

- space A: [private, /a, /b, /c] looking at /a. Counted in the whole row,
  it came back as /b.
- space B: [/d, /e, private] looking at the private tab, which is not kept:
  its nearest kept neighbour before it, /e, stands in. Counted in the whole
  row, its index was past the end and B came back on /d.

The world is quit from A with B parked, then relaunched: A must be on /a and
B, once shown, on /e, each file's `active` pointing at that tab, and no other
tab of either row given a page (`space.pages` counts the views).

Runs in its own world (ESCALE_WORLD, default "a05-selection"), launched
through fresh.sh from build/Escale.app — ./build.sh first — and wiped
afterwards unless KEEP=1. Pages come from a local server on 127.0.0.1;
nothing else is fetched. Exits non-zero, with expected and actual state for
every failed check, on failure.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import os
import socket
import subprocess
import sys
import threading
import time

REPO = Path(__file__).resolve().parents[2]
WORLD = os.environ.get("ESCALE_WORLD", "a05-selection")
FOLDER = Path.home() / "Library/Application Support" / f"Escale ({WORLD})"
BINARY = str(REPO / "build/probe" / WORLD / "Escale.app/Contents/MacOS/Escale")
SUITE = f"com.kndpt.escale.test.{WORLD}"


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/") or "home"
        body = f"<title>A05 {name}</title><h1>{name}</h1>".encode()
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


def tabs():
    """The row on screen as the bench describes it, private flag included:
    `./bench tabs` prints no `shy`, so the socket is asked directly."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(5)
        s.connect(str(FOLDER / "bench.sock"))
        s.sendall(b'{"do": "tabs"}\n')
        chunks = []
        while chunk := s.recv(1 << 16):
            chunks.append(chunk)
    return json.loads(b"".join(chunks).split(b"\n", 1)[0])["tabs"]


def tab_at(url):
    return next((tab for tab in tabs() if tab["url"] == url), None)


def active():
    return next((tab for tab in tabs() if tab["active"]), None)


def space():
    return json.loads(bench("space", deadline=10).stdout)


def running():
    lines = subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True, text=True).stdout
    return [line.split(None, 1)[0] for line in lines.splitlines()
            if line.strip().split(None, 1)[-1] == BINARY]


def wait_for(check, deadline):
    """Whether check() came true before the deadline."""
    end = time.monotonic() + deadline
    while time.monotonic() < end:
        try:
            if check():
                return True
        except (subprocess.TimeoutExpired, AssertionError, OSError, ValueError, KeyError, TypeError):
            pass
        time.sleep(0.2)
    return False


def until(what, check, deadline):
    if not wait_for(check, deadline):
        raise AssertionError(f"timed out after {deadline}s waiting for {what}")


def launch():
    if running():
        raise AssertionError(f"world {WORLD} is already running")
    run([REPO / "fresh.sh", "again"], deadline=60)
    until("the bench to answer", lambda: bench("tabs", deadline=5, check=False).returncode == 0, 60)


def open_tab(url):
    """An ordinary tab at url, at the end of the row on screen, once loaded."""
    bench("bookmark", url, "new", deadline=30)
    until(f"{url} to load", lambda: tab_at(url)["title"].startswith("A05") and not tab_at(url)["loading"], 10)
    return tab_at(url)["id"]


def open_private(url):
    """A private tab (⌘⇧N) at url: it is the one looked at."""
    before = {tab["id"] for tab in tabs()}
    bench("press", "45", "n", "cmd", "shift", deadline=10)
    until("private search", lambda: json.loads(bench("probe").stdout)["searchPrivate"], 10)
    assert {tab["id"] for tab in tabs()} == before
    bench("field", url, "go", deadline=30)
    until(f"the private tab at {url}", lambda: active()["shy"] and active()["url"] == url
          and not active()["loading"], 10)
    return active()["id"]


def saved(name):
    return json.loads((FOLDER / name).read_text())


def selected(name):
    """The address a session file says was looked at, or what's wrong with it."""
    shape = saved(name)
    if not 0 <= shape["active"] < len(shape["tabs"]):
        return f"active {shape['active']} of {len(shape['tabs'])} tabs"
    return shape["tabs"][shape["active"]]["url"]


def main():
    if not (REPO / "build/Escale.app").exists():
        raise AssertionError("no build/Escale.app: run ./build.sh first")
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    a, b, c, d, e = (f"{base}/{name}" for name in "abcde")
    failures = []

    def check(what, ok, found):
        if not ok:
            failures.append(f"{what}; found {found}")

    try:
        run([REPO / "fresh.sh", "wipe"], deadline=60)
        run(["defaults", "write", SUITE, "bench", "-bool", "YES"])
        launch()
        bench("ui", "spaces", "on")
        until("spaces on", lambda: space()["on"], 10)
        first = space()["current"]

        # Space A: a private tab ahead of the one looked at.
        for url in (a, b, c):
            open_tab(url)
        private = open_private(f"{base}/private-a")
        bench("place", private, "0")
        bench("select", tab_at(a)["id"])
        until(f"{a} looked at", lambda: active()["url"] == a, 10)
        row_a = [("private" if t["shy"] else t["url"] or "blank") for t in tabs()]

        # Space B: the one looked at is private, after the kept ones.
        bench("space", "new", "B")
        until("space B on screen", lambda: space()["current"] == "B", 10)
        for url in (d, e):
            open_tab(url)
        open_private(f"{base}/private-b")
        row_b = [("private" if t["shy"] else t["url"] or "blank") for t in tabs()]
        b_file = f"session-{next(s['id'] for s in space()['spaces'] if s['name'] == 'B')}.json"

        # Back in A, with B parked, and quit from there.
        bench("space", "go", "1")
        until("space A on screen", lambda: space()["current"] == first, 10)
        bench("press", "12", "q", "cmd", deadline=10, check=False)
        until("the app to quit", lambda: not running(), 30)

        check(f"A's row before the quit was [private, {a}, {b}, {c}]", row_a == ["private", a, b, c], row_a)
        check(f"B's row before the quit was [{d}, {e}, private]", row_b == [d, e, "private"], row_b)
        check(f"session.json keeps {a}, {b}, {c}", [t["url"] for t in saved("session.json")["tabs"]] == [a, b, c],
              saved("session.json"))
        check(f"session.json selects {a}", selected("session.json") == a, selected("session.json"))
        check(f"{b_file} keeps {d}, {e}", [t["url"] for t in saved(b_file)["tabs"]] == [d, e], saved(b_file))
        check(f"{b_file} selects {e}, the kept tab before the private one", selected(b_file) == e, selected(b_file))

        launch()
        until("A restored", lambda: len(tabs()) == 3, 10)
        check(f"A comes back on {a}", wait_for(lambda: active()["url"] == a, 5), active())
        check("A's other tabs not given a page", wait_for(lambda: len(space()["pages"]) == 1, 5), space()["pages"])

        bench("space", "go", "2")
        until("space B on screen", lambda: space()["current"] == "B", 10)
        check(f"B comes back on {e}", wait_for(lambda: active()["url"] == e, 5), active())
        check(f"B's {d} not given a page: two pages, A's and B's",
              wait_for(lambda: len(space()["pages"]) == 2, 5), space()["pages"])

        if failures:
            raise AssertionError("\n  " + "\n  ".join(failures))
        print("ok: both spaces came back on the tab looked at, around private tabs, "
              "and no other tab was given a page")
        return 0
    except (AssertionError, subprocess.TimeoutExpired) as failure:
        if failures and not str(failure).startswith("\n"):
            failure = f"{failure}\n  " + "\n  ".join(failures)
        print(f"FAIL: {failure}", file=sys.stderr)
        return 1
    finally:
        server.shutdown()
        if os.environ.get("KEEP") != "1":
            run([REPO / "fresh.sh", "wipe"], deadline=60, check=False)


if __name__ == "__main__":
    sys.exit(main())
