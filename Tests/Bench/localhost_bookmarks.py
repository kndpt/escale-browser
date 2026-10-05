#!/usr/bin/env python3
"""A Localhost entry returns to its bookmark's tab, on the local environment.

Run after ./build.sh debug. Two loopback servers stand for DEV and STAGING of
two bookmarks in one isolated test world. The count on the door is the list's
length, so it is read from the same list the hub draws.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread
import json
import os
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
WORLD = "localhost-bookmarks"
requests = {"dev": 0, "staging": 0}


def handler(name):
    class Page(BaseHTTPRequestHandler):
        def do_GET(self):
            requests[name] += 1
            body = f"<!doctype html><title>{name}</title><h1>{name}</h1>".encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass
    return Page


def run(*args, env=None):
    result = subprocess.run([str(x) for x in args], cwd=ROOT, env=env,
                            capture_output=True, text=True, timeout=40)
    if result.returncode:
        raise AssertionError(f"{args}: {result.stdout} {result.stderr}")
    return result.stdout


def bench(*args):
    return json.loads(run(ROOT / "bench", "--world", WORLD, "--json", *args))


def environments(name, *args):
    return bench("environments", name, *args)


def until(label, predicate):
    end = time.monotonic() + 15
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(0.15)
    raise AssertionError(f"timed out: {label}")


def tabs():
    return bench("tabs")["tabs"]


def tab(identity):
    return next(t for t in tabs() if identity.lower().startswith(t["id"].lower()))


def main():
    assert (ROOT / "build/Escale.app").exists(), "run ./build.sh debug first"
    servers = {name: ThreadingHTTPServer(("127.0.0.1", 0), handler(name)) for name in requests}
    for server in servers.values():
        Thread(target=server.serve_forever, daemon=True).start()
    dev = f"http://127.0.0.1:{servers['dev'].server_port}"
    staging = f"http://127.0.0.1:{servers['staging'].server_port}"
    both = json.dumps([{"name": "dev", "url": dev + "/"}, {"name": "staging", "url": staging + "/"}])
    env = dict(os.environ, ESCALE_PROBE=WORLD)
    try:
        run(ROOT / "fresh.sh", "wipe", env=env)
        run("defaults", "write", f"com.kndpt.escale.test.{WORLD}", "bench", "-bool", "YES")
        run(ROOT / "fresh.sh", "again", env=env)
        bench("ui", "welcome", "off")
        bench("ui", "sidebar", "on")
        bench("shelf", "seed")
        assert bench("localhost")["count"] == 0

        # Visit DEV then STAGING through the bookmark, leaving it on STAGING.
        environments("WebKit", "set", both)
        first = environments("WebKit", "open", "DEV")
        bench("wait", first["tab"], "10")
        until("dev visited", lambda: bench("localhost")["count"] == 1)
        bench("wait", environments("WebKit", "open", "STAGING")["tab"], "10")
        until("staging visited", lambda: bench("localhost")["count"] == 2)
        assert environments("WebKit")["badge"] == "STAGING"
        before = len(tabs())

        bench("localhost", "open", dev)
        assert len(tabs()) == before, "a second tab opened instead of the bookmark's"
        there = environments("WebKit")
        assert there["tab"] == first["tab"] and there["address"] == dev + "/" and there["badge"] == "DEV", there
        print("ok: bookmark on STAGING returns to its own tab, now on DEV, and the count reads 2")

        # Already on DEV: a click selects it and loads nothing.
        until("dev loaded", lambda: requests["dev"] >= 2)
        seen = dict(requests)
        bench("localhost", "open", dev)
        time.sleep(1)
        assert len(tabs()) == before and requests == seen, (requests, seen)
        print("ok: a tab already on the endpoint is selected without a request")

        # A sleeping linked tab wakes on DEV in place.
        bench("wait", environments("WebKit", "open", "STAGING")["tab"], "10")
        bench("bookmark", "data:text/html,<title>Other</title>", "new")
        before = len(tabs())
        bench("sleep", first["tab"])
        assert tab(first["tab"])["asleep"]
        bench("localhost", "open", dev)
        assert len(tabs()) == before
        woken = tab(first["tab"])
        assert not woken["asleep"] and woken["url"] == dev + "/", woken
        print("ok: a sleeping linked tab wakes on the local destination")

        # Two bookmarks own DEV. The active one is preferred; with neither
        # active, nothing is hijacked and an ordinary tab opens.
        environments("Swift", "set", both)
        bench("wait", environments("WebKit", "open", "STAGING")["tab"], "10")
        swift = environments("Swift", "open", "STAGING")
        bench("wait", swift["tab"], "10")
        bench("localhost", "open", dev)
        assert environments("Swift")["badge"] == "DEV" and environments("WebKit")["badge"] == "STAGING"
        bench("wait", environments("Swift", "open", "STAGING")["tab"], "10")
        bench("bookmark", "data:text/html,<title>Neutral</title>", "new")
        before = len(tabs())
        bench("localhost", "open", dev)
        assert len(tabs()) == before + 1, "an ambiguous click should open an ordinary tab"
        assert environments("WebKit")["badge"] == environments("Swift")["badge"] == "STAGING"
        print("ok: several bookmarks on one endpoint: the active one wins, otherwise no tab is taken")

        # Another Space has its own list and its own count.
        bench("space", "new", "Other")
        bench("space", "go", "2")
        assert bench("localhost")["count"] == 0
        bench("space", "go", "1")
        assert bench("localhost")["count"] == 2
        print("ok: the count follows the Space")
    finally:
        run(ROOT / "fresh.sh", "wipe", env=env)
        for server in servers.values():
            server.shutdown()


if __name__ == "__main__":
    main()
