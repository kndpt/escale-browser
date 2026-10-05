"""Automatic address badges are absent from tabs, pins and bookmarks.

Run after ./build.sh debug. An isolated world and a loopback page supply the
address; bench captures the real sidebar and tab strip, then sips converts
their PNGs for small stdlib pixel assertions. The blue text is unique to
this hint in the tested row area. No external site is used.
"""

import json
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread


REPO = Path(__file__).resolve().parents[2]
WORLD = "environment-badge"


def run(*args, timeout=20, env=None):
    return subprocess.run(args, cwd=REPO, env=env, capture_output=True,
                          text=True, check=True, timeout=timeout).stdout


def bench(*args, timeout=20):
    return run(str(REPO / "bench"), "--world", WORLD, *args, timeout=timeout)


def blue_pixels(png, bmp, area):
    run("sips", "-s", "format", "bmp", str(png), "--out", str(bmp))
    data = bmp.read_bytes()
    offset = struct.unpack_from("<I", data, 10)[0]
    width, height, planes, bits = struct.unpack_from("<iiHH", data, 18)
    assert data[:2] == b"BM" and height < 0 and planes == 1 and bits == 32
    total = 0
    left, top, right, bottom = area
    for y in range(top, min(bottom, -height)):
        for x in range(left, min(right, width)):
            pixel = offset + 4 * (y * width + x)
            blue, green, red = data[pixel:pixel + 3]
            total += blue > red + 45 and green > red + 35 and blue > 145
    return total


def assert_hint(phase, expected, folder):
    png, bmp = folder / "column.png", folder / "column.bmp"
    json.loads(bench("column", str(png)))
    count = blue_pixels(png, bmp, (55, 110, 290, 400))
    assert (count > 25) == expected, f"{phase}: {count} blue hint pixels, expected {'badge' if expected else 'none'}"
    if expected and phase in ("ordinary active tab", "active bookmark tab"):
        right = blue_pixels(png, bmp, (190, 110, 290, 400))
        assert right > 25, f"{phase}: badge is not at the right edge of its row ({right} pixels)"
    if phase != "active pin":
        assert blue_pixels(png, bmp, (55, 40, 290, 105)) == 0, f"{phase}: badge escaped its row"


def assert_strip(phase, expected, folder):
    png, bmp = folder / "strip.png", folder / "strip.bmp"
    json.loads(bench("strip", str(png)))
    count = blue_pixels(png, bmp, (90, 0, 1000, 40))
    assert (count > 25) == expected, f"{phase}: {count} blue badge pixels in tab strip"


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"<!doctype html><title>Badge test</title><h1>Badge test</h1>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def main():
    assert (REPO / "build/Escale.app").exists(), "run ./build.sh debug first"
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    probe = dict(os.environ, ESCALE_PROBE=WORLD)
    try:
        run("./fresh.sh", "wipe", env=probe, timeout=30)
        run("defaults", "write", f"com.kndpt.escale.test.{WORLD}", "bench", "-bool", "YES")
        run("./fresh.sh", "again", env=probe, timeout=30)
        bench("ui", "welcome", "off")
        bench("ui", "sidebar", "on")
        bench("ui", "bar", "off")
        bench("field", f"http://127.0.0.1:{server.server_port}", "go", timeout=30)
        active = next(line for line in bench("tabs").splitlines() if line.startswith("●"))
        tab_id = re.search(r"\b[0-9a-f]{8}\b", active)
        assert tab_id is not None, active
        tab_id = tab_id.group()

        with tempfile.TemporaryDirectory(prefix="escale-badge-") as temporary:
            folder = Path(temporary)
            assert_hint("ordinary active tab", False, folder)
            assert json.loads(bench("pin", tab_id))["pin"]
            # The bench pin action changes Tab.pin directly; entering the
            # sidebar again refreshes the parent grid before its capture.
            bench("ui", "sidebar", "off")
            bench("ui", "sidebar", "on")
            assert_hint("active pin", False, folder)

            assert json.loads(bench("pin", tab_id, "off"))["pin"] == ""
            bench("ui", "sidebar", "off")
            bench("ui", "sidebar", "on")
            rows = json.loads(bench("shelf", "keep"))["rows"]
            assert any(row["title"] == "Badge test" and row["tab"] and row["live"] for row in rows), rows
            assert_hint("active bookmark tab", False, folder)

            bench("ui", "sidebar", "off")
            assert_strip("ordinary top tab", False, folder)
            assert json.loads(bench("pin", tab_id))["pin"]
            assert_strip("pinned top tab", False, folder)
            assert json.loads(bench("pin", tab_id, "off"))["pin"] == ""

            bench("bookmark", "data:text/html,<title>Plain</title>", "new", timeout=30)
            json.loads(bench("select", tab_id))
            bench("field", "data:text/html,<title>Plain again</title>", "go", timeout=30)
            assert_strip("top tab without a hint", False, folder)
            bench("ui", "sidebar", "on")
            assert_hint("tab without a hint", False, folder)
        print("ok: no automatic badge in ordinary, pinned or unconfigured bookmark rows in either layout")
    finally:
        run("./fresh.sh", "wipe", env=probe, timeout=30)
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
