#!/usr/bin/env python3
"""What a frame of the swipe between spaces costs.

Two fingers sideways over the column move every row of the space with them,
one trackpad event a frame. This drives that gesture a step at a time
(`bench space glide DX STEPS`: one move a turn of the run loop, each timed
until the window rests), over a column of TABS ordinary tabs in the sidebar
with a second space to swipe towards, and lets go as cancelled.

It checks that a cancelled swipe leaves the same space on screen and the
rows back in place, and prints the timings, so the same script measures a
change before and after: run it from each checkout with MEASURE=1 and
ROUNDS=10 on an otherwise idle Mac.

Runs in its own world (ESCALE_WORLD, default "space-glide"), launched
through fresh.sh from build/Escale.app — ./build.sh first — and wiped
afterwards unless KEEP=1. Pages come from a local server on 127.0.0.1;
nothing else is fetched. Exits non-zero, with expected and actual state, on
failure.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import os
import statistics
import subprocess
import sys
import threading
import time

REPO = Path(__file__).resolve().parents[2]
WORLD = os.environ.get("ESCALE_WORLD", "space-glide")
BINARY = str(REPO / "build/probe" / WORLD / "Escale.app/Contents/MacOS/Escale")
SUITE = f"com.kndpt.escale.test.{WORLD}"
ROUNDS = int(os.environ.get("ROUNDS", "3"))
TABS = int(os.environ.get("TABS", "12"))
STEPS = 30


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/") or "home"
        body = f"<title>Glide {name}</title><h1>{name}</h1>".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def run(args, deadline=30, check=True):
    env = dict(os.environ, ESCALE_PROBE=WORLD)
    if os.environ.get("MEASURE") == "1":
        env["ESCALE_MEASURE"] = "1"
    else:
        env.pop("ESCALE_MEASURE", None)
    done = subprocess.run([str(a) for a in args], cwd=REPO, env=env, capture_output=True,
                          text=True, timeout=deadline)
    if check and done.returncode != 0:
        raise AssertionError(f"{' '.join(map(str, args))} exited {done.returncode}: {done.stderr.strip()}")
    return done


def bench(*args, deadline=30, check=True):
    return run([REPO / "bench", "--world", WORLD, *args], deadline=deadline, check=check)


def ask(*args, deadline=30):
    return json.loads(bench("--json", *args, deadline=deadline).stdout)


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


def percentile(values, share):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(len(ordered) * share))]


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
        bench("ui", "sidebar", "on", deadline=10)
        bench("ui", "spaces", "on", deadline=10)

        # A second space to swipe towards, then back to the first, with its rows.
        bench("space", "new", "Other", deadline=15)
        bench("space", "go", "1", deadline=15)
        for i in range(TABS):
            if i:
                bench("press", "17", "t", "cmd", deadline=10)
            bench("field", f"{base}/{i}", "go", deadline=30)
        until(f"{TABS} tabs", lambda: ask("space")["tabs"] >= TABS, 30)
        time.sleep(2)

        before = ask("space")
        times = []
        for _ in range(ROUNDS):
            times += ask("space", "glide", "-120", str(STEPS), deadline=60)["ms"]
            time.sleep(0.5)
        after = ask("space")
        for key in ("current", "tabs", "swipe", "making"):
            if after.get(key) != before.get(key):
                raise AssertionError(f"after a cancelled swipe, {key}: expected {before.get(key)!r}, found {after.get(key)!r}")

        print(f"ok: {ROUNDS} cancelled swipes over {TABS} tabs left space {after['current']!r} "
              f"on screen and the rows in place")
        print(f"steps={len(times)} rested_ms median={statistics.median(times):.2f} "
              f"p95={percentile(times, 0.95):.2f} max={max(times):.2f}")
        print("rested_ms=" + json.dumps([round(t, 3) for t in times]))
        return 0
    except (AssertionError, subprocess.TimeoutExpired, json.JSONDecodeError, KeyError) as failure:
        print(f"FAIL: {failure}", file=sys.stderr)
        return 1
    finally:
        server.shutdown()
        if os.environ.get("KEEP") != "1":
            run([REPO / "fresh.sh", "wipe"], deadline=60, check=False)


if __name__ == "__main__":
    sys.exit(main())
