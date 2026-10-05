#!/usr/bin/env python3
"""The three chrome sizes persist and leave the WebKit page zoom alone.

Run after ./build.sh debug. A local page in an isolated world reports its CSS
font size and viewport. Growing the sidebar must give the page less width;
growing the top tab row must give it less height. The page zoom remains 1.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread
import json
import os
import subprocess
import time


ROOT = Path(__file__).resolve().parents[2]
WORLD = os.environ.get("ESCALE_SIZE_WORLD", "issue70-size-test")
SUITE = f"com.kndpt.escale.test.{WORLD}"


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"<title>Interface size</title><style>body{font-size:20px}</style><p>Page zoom stays independent.</p>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def run(*args, env=None):
    done = subprocess.run(args, cwd=ROOT, env=env, capture_output=True, text=True, timeout=35)
    if done.returncode:
        raise AssertionError(f"{args}: {done.stderr.strip()} {done.stdout.strip()}")
    return done.stdout


def bench(*args):
    return json.loads(run(str(ROOT / "bench"), "--world", WORLD, "--json", *args))


def until(label, condition):
    end = time.monotonic() + 15
    while time.monotonic() < end:
        try:
            if condition():
                return
        except (AssertionError, OSError):
            pass
        time.sleep(0.15)
    raise AssertionError(f"{label}: timed out")


def active():
    return next(tab for tab in bench("tabs")["tabs"] if tab["active"])


def value(tab_id, script):
    return bench("eval", tab_id, script)["value"]


def settled_value(tab_id, script):
    end = time.monotonic() + 15
    previous = None
    unchanged = 0
    while time.monotonic() < end:
        current = value(tab_id, script)
        unchanged = unchanged + 1 if current == previous else 0
        if unchanged >= 3:
            return current
        previous = current
        time.sleep(0.15)
    raise AssertionError(f"{script}: viewport never settled")


def main():
    assert (ROOT / "build/Escale.app").exists(), "run ./build.sh debug first"
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    probe = dict(os.environ, ESCALE_PROBE=WORLD)
    try:
        run("./fresh.sh", "wipe", env=probe)
        run("defaults", "write", SUITE, "bench", "-bool", "YES")
        run("defaults", "write", SUITE, "sidebar", "-bool", "YES")
        run("./fresh.sh", "again", env=probe)
        until("bench socket", lambda: bool(bench("tabs")))
        bench("ui", "welcome", "off")
        assert bench("probe")["interfaceSize"] == "standard", "default size must be standard"
        url = f"http://127.0.0.1:{server.server_port}/"
        bench("field", url, "go")
        until("local page", lambda: active()["url"] == url and not active()["loading"])
        tab_id = active()["id"]
        bench("space", "new", "Swipe target", "fresh")
        bench("space", "go", "1")

        def swipe_follows_fingers(size):
            bench("space", "hold", "-10")
            offset = bench("space")["swipe"]
            assert abs(offset + 10) < 0.01, (size, offset)
            bench("space", "release")

        widths = []
        for size in ("compact", "standard", "large"):
            bench("ui", "size", size)
            until(f"{size} selection", lambda: bench("probe")["interfaceSize"] == size)
            widths.append(settled_value(tab_id, "window.innerWidth"))
            assert abs(active()["pageZoom"] - 1 / 1.1) < 1e-8, (size, active())
            assert value(tab_id, "getComputedStyle(document.body).fontSize") == "20px", size
            swipe_follows_fingers(size)
        assert widths[0] > widths[1] > widths[2], widths

        bench("ui", "sidebar", "off")
        heights = []
        for size in ("compact", "standard", "large"):
            bench("ui", "size", size)
            until(f"{size} selection", lambda: bench("probe")["interfaceSize"] == size)
            heights.append(settled_value(tab_id, "window.innerHeight"))
            assert abs(active()["pageZoom"] - 1 / 1.1) < 1e-8, (size, active())
            swipe_follows_fingers(size)
        assert heights[0] > heights[1] > heights[2], heights

        bench("press", "12", "q", "cmd")
        run("./fresh.sh", "again", env=probe)
        until("saved size", lambda: bench("probe")["interfaceSize"] == "large")
        print(f"ok: sidebar widths {widths}, page heights {heights}, page zoom 1 / 1.1, swipes follow fingers, size large restored")
    finally:
        run("./fresh.sh", "wipe", env=probe)
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
