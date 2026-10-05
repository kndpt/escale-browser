#!/usr/bin/env python3
"""The update's door, panels and relaunch, in one isolated test world.

Run after ./build.sh (the bundle must carry NOTES.txt). A development build
cannot swap itself, so the waiting stage is stood by hand (`bench update`);
the relaunch and the launch after it are the real ones. A loopback server
supplies the pages and the feed address, which answers no appcast, so the
browser makes no request beyond it.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread
import json
import os
import subprocess
import time


ROOT = Path(__file__).resolve().parents[2]
# The runner's own world when it gives one, so campaigns beside each other never share it.
WORLD = os.environ.get("ESCALE_VERIFY_WORLD", "update-gate")


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/").split(".")[0].capitalize() or "Home"
        body = f"<!doctype html><title>{name}</title><h1>{name}</h1>".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def run(*args, env=None):
    result = subprocess.run(args, cwd=ROOT, env=env, capture_output=True,
                            text=True, timeout=40)
    if result.returncode:
        raise AssertionError(f"{args}: {result.stdout} {result.stderr}")
    return result.stdout


def bench(*args):
    return json.loads(run(str(ROOT / "bench"), "--world", WORLD, "--json", *args))


def until(label, predicate, seconds=20):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        try:
            if predicate():
                return
        except (AssertionError, json.JSONDecodeError, subprocess.TimeoutExpired):
            pass  # between two processes during a relaunch
        time.sleep(0.25)
    raise AssertionError(f"timed out: {label}")


def titles():
    return sorted(tab["title"] for tab in bench("tabs")["tabs"] if not tab.get("bench"))


def main():
    app = Path(os.environ.get("ESCALE_TEST_APP", ROOT / "build/Escale.app"))
    assert (app / "Contents/Resources/NOTES.txt").exists(), "run ./build.sh first: the bundle carries no note"
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    env = dict(os.environ, ESCALE_PROBE=WORLD, ESCALE_FEED=f"{base}/appcast.json")
    try:
        run("./fresh.sh", "wipe", env=env)
        run("defaults", "write", f"com.kndpt.escale.test.{WORLD}", "bench", "-bool", "YES")
        run("./fresh.sh", "again", env=env)
        until("bench", lambda: bool(bench("update")))
        bench("ui", "welcome", "off")

        state = bench("update")
        assert state["gate"] == "", f"a first launch showed an update panel: {state}"
        assert not state["door"], state

        # The door shows from the first byte; the panel follows the stage, and
        # a build that lands turns it from its download to its relaunch.
        fetching = bench("update", "fetching", json.dumps({"version": "9.9", "fraction": 0.4}))
        assert fetching["door"] and fetching["fraction"] == 0.4, fetching
        assert bench("update", "open")["gate"] == "boarding"
        landed = bench("update", "ready", json.dumps({"version": "9.9", "notes": "What 9.9 brings."}))
        assert landed["door"] and landed["fraction"] is None, landed
        time.sleep(0.5)
        assert bench("update")["gate"] == "boarding", "the build landing closed its panel"
        bench("press", "53", "\u001b")
        until("Escape closes the panel", lambda: bench("update")["gate"] == "")
        assert bench("update")["door"], "closing the panel took the door away"
        bench("update", "open")
        until("the panel leaves with its build", lambda: bench("update", "none")["gate"] == "")
        assert not bench("update", "offered", json.dumps({"version": "9.9"}))["gate"]
        assert bench("update")["door"], "an offered build has no door"

        # The relaunch keeps the tabs, and the next launch is an arrival.
        for page in ("alpha", "bravo"):
            if page == "bravo":
                bench("press", "17", "t", "cmd")
            bench("field", f"{base}/{page}.html", "go")
            until(f"open {page}", lambda: page.capitalize() in titles())
        bench("update", "ready", json.dumps({"version": "9.9"}))
        bench("update", "forget")
        bench("update", "relaunch")
        # While the old process closes, `bench update` can answer `{}` before the new one listens.
        until("relaunched as an arrival", lambda: bench("update").get("gate") == "arrived", seconds=40)
        assert titles() == ["Alpha", "Bravo"], f"the relaunch lost tabs: {titles()}"
        assert not bench("update")["door"], "the relaunched copy still offers the build"

        # Once: a quit and a plain launch of the same build show nothing.
        bench("update", "close")
        bench("press", "12", "q", "cmd")
        time.sleep(2)
        run("./fresh.sh", "again", env=env)
        until("reopened", lambda: bool(bench("update")))
        assert bench("update")["gate"] == "", "the same build arrived twice"
        print("update gate: the door from the first byte, a landing keeps the panel, Escape and a lost stage close it, "
              "the updater's relaunch keeps both tabs and arrives once")
    finally:
        server.shutdown()
        run("./fresh.sh", "wipe", env=env)


if __name__ == "__main__":
    main()
