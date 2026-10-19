#!/usr/bin/env python3
"""Screens lays a real page out at a device's size and gives it back whole.

Run after ./build.sh debug. ⌥⌘R on an ordinary tab of a loopback page: the
page reads the default device's width, height and density, its media queries
and layout follow, a script listening for resize is told the final size, and
the tab's zoom is kept. ⌥⌘R again, and Developer mode turned off, each give
the page its frame back. The ruler, the edges, the overflow outline and the
phone's code are not driven here (ScreensTests covers what screens.js reads).
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
import json
import suite as s

PAGE = b"""<!doctype html><meta charset="utf-8"><title>Screens fixture</title>
<style>
body { margin: 0 }
.g { display: grid; grid-template-columns: 1fr }
@media (min-width: 640px) { .g { grid-template-columns: 1fr 1fr } }
</style>
<h1>screens</h1><div class="g"><div>a</div><div>b</div></div>
<script>
window.told = '';
addEventListener('resize', () => { told = innerWidth + 'x' + innerHeight + '@' + devicePixelRatio; });
</script>"""


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(PAGE)))
        self.end_headers()
        self.wfile.write(PAGE)

    def log_message(self, *args):
        pass


def read(ident):
    return json.loads(s.ask("eval", id=ident, js="""JSON.stringify({
        width: innerWidth, layout: document.documentElement.clientWidth,
        height: document.documentElement.clientHeight, density: devicePixelRatio,
        columns: getComputedStyle(document.querySelector('.g')).gridTemplateColumns.split(' ').length,
        wide: matchMedia('(min-width: 640px)').matches, told})""")["value"])


def screens():
    s.ask("press", code=15, chars="r", mods=["cmd", "opt"])


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{server.server_port}/screens"
    with s.world(server):
        s.launch()
        ident = s.open_ordinary(url)
        whole = read(ident)
        s.require("a whole page is wider than a phone", whole["width"] > 640, True)

        screens()
        # The default device, iPhone 17: 402 × 874 at 3x.
        s.wait_for("the page at a phone's size", lambda: read(ident),
                   {"width": 402, "layout": 402, "height": 874, "density": 3})
        phone = read(ident)
        s.require("media queries at a phone's width", (phone["wide"], phone["columns"]), (False, 1))
        s.until("resize told the final size", lambda: read(ident)["told"].startswith("402x"))
        s.require("the tab keeps its zoom", next(t for t in s.tabs() if t["id"] == ident)["zoom"], 1)

        screens()
        s.wait_for("the page back at its frame", lambda: read(ident),
                   {"width": whole["width"], "density": whole["density"]})
        s.require("the tab's zoom back on its page", abs(next(t for t in s.tabs() if t["id"] == ident)["pageZoom"] - 1 / 1.1) < 1e-6, True)

        screens()
        s.wait_for("Screens again", lambda: read(ident), {"width": 402})
        # Developer mode off (⇧⌘I) lets its tools go, Screens with them.
        s.ask("press", code=34, chars="i", mods=["cmd", "shift"])
        s.wait_for("the page back with Developer mode off", lambda: read(ident), {"width": whole["width"]})
        print("ok: device size, density, media queries, resize, zoom kept; closed by its key and by Developer mode")


if __name__ == "__main__":
    main()
