#!/usr/bin/env python3
"""Real local navigation feeds the hub; bench pages and other spaces do not.
A server that stops is told apart from one that runs, kept, and counted only
while it may still load.

Run after ./build.sh debug. Two loopback servers supply different ports in
one isolated test world. The browser makes no requests beyond these servers.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread
import json
import os
import subprocess
import time


ROOT = Path(__file__).resolve().parents[2]
WORLD = "localhost-hub"


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        body = f"<!doctype html><title>Local {self.server.server_port}</title><h1>Local</h1>".encode()
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


def until(label, predicate):
    end = time.monotonic() + 15
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(0.15)
    raise AssertionError(f"timed out: {label}")


def origins():
    return [entry["origin"] for entry in bench("localhost")["entries"]]


def states():
    return {entry["origin"]: entry["state"] for entry in bench("localhost")["entries"]}


def check():
    """Read the listening ports as opening the panel does; wait for the answer."""
    bench("localhost", "check")
    until("ports read", lambda: (lambda a: a["read"] and not a["reading"])(bench("localhost")))
    return bench("localhost")


def main():
    assert (ROOT / "build/Escale.app").exists(), "run ./build.sh debug first"
    servers = [ThreadingHTTPServer(("127.0.0.1", 0), Page) for _ in range(2)]
    for server in servers:
        Thread(target=server.serve_forever, daemon=True).start()
    env = dict(os.environ, ESCALE_PROBE=WORLD)
    try:
        run("./fresh.sh", "wipe", env=env)
        run("defaults", "write", f"com.kndpt.escale.test.{WORLD}", "bench", "-bool", "YES")
        run("./fresh.sh", "again", env=env)
        bench("ui", "welcome", "off")
        assert origins() == [], origins()
        first, second = [f"http://127.0.0.1:{s.server_port}/" for s in servers]
        bench("open", first)
        assert origins() == [], "bench tab entered the personal hub"
        for url in (first, second):
            bench("field", url, "go")
            until(f"visit {url}", lambda: url[:-1] in origins())
        assert set(origins()) == {first[:-1], second[:-1]}, origins()
        assert all(entry["title"].startswith("Local ") for entry in bench("localhost")["entries"])
        # Visited just now and never read: both may load.
        assert set(states().values()) == {"unconfirmed"}, states()
        assert bench("localhost")["reachable"] == 2
        read = check()
        assert set(states().values()) == {"running"} and read["reachable"] == 2, states()
        # The second server stops: its entry stays, as stopped, and leaves the count.
        stopped = servers[1]
        port = stopped.server_port
        stopped.shutdown()
        stopped.server_close()
        read = check()
        assert states() == {first[:-1]: "running", second[:-1]: "stopped"}, states()
        assert read["count"] == 2 and read["reachable"] == 1, read
        # The same origin serves again: running, counted, no new visit.
        servers[1] = ThreadingHTTPServer(("127.0.0.1", port), Page)
        Thread(target=servers[1].serve_forever, daemon=True).start()
        read = check()
        assert set(states().values()) == {"running"} and read["reachable"] == 2, states()
        # Stopped across a quit and reopen: kept, unconfirmed until read, then stopped.
        servers[1].shutdown()
        servers[1].server_close()
        bench("field", "about:blank", "go")
        bench("press", "12", "q", "cmd")
        run("./fresh.sh", "again", env=env)
        until("reopened hub", lambda: bool(bench("localhost")))
        assert set(origins()) == {first[:-1], second[:-1]}, "a stopped server's entry was dropped"
        assert set(states().values()) == {"unconfirmed"}, states()
        read = check()
        assert states() == {first[:-1]: "running", second[:-1]: "stopped"}, states()
        assert read["reachable"] == 1, read
        bench("ui", "welcome", "off")
        bench("space", "new", "Other")
        bench("space", "go", "2")
        assert origins() == [], "another space inherited local endpoints"
        bench("space", "go", "1")
        assert set(origins()) == {first[:-1], second[:-1]}, origins()
        bench("ui", "clearHistory", "on")
        assert origins() == [], "Clear History kept visited local addresses"
        # Leave the local page before reopening; a restored live server is a
        # new visit and should legitimately enter the hub again.
        bench("field", "about:blank", "go")
        assert origins() == []
        bench("press", "12", "q", "cmd")
        run("./fresh.sh", "again", env=env)
        until("reopened hub", lambda: bool(bench("localhost")))
        assert origins() == [], "cleared local addresses returned after restart"
        print("localhost hub: two visited ports, stopped and restarted servers told apart and kept, no bench visit, space isolation, Clear History persists")
    finally:
        for server in servers:
            server.shutdown()
        run("./fresh.sh", "wipe", env=env)


if __name__ == "__main__":
    main()
