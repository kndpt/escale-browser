#!/usr/bin/env python3
"""Escale's glass and the page's frame change nothing about the page.

Run after ./build.sh debug. In an isolated world, a local page with a typed
draft, a scroll position and a JavaScript marker stays the same page while
the Transparency setting, Escale's own Increase Contrast, the Colours choice, the look, the layout, the interface size, the fold and the address
bar change: no reload, same draft, same scroll, page zoom 1 / 1.1,
no extra web view. The window is opaque only when Solid (or when macOS
reduces transparency). The envelope round the page takes no press meant for
the page and the page takes none in the envelope. The setting survives a
restart, as does the Colours choice, and an unknown stored value reads as
the default. The shared runner
owns a unique world, restart identity, diagnostics and cleanup.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
import json
import time
import suite as harness


PAGE = (b"<!doctype html><meta charset=utf-8><title>Glass frame</title>"
        b"<body style='margin:0;font:16px -apple-system'>"
        b"<input id=draft style='margin:40px;font-size:16px'>"
        b"<div style='height:4000px;background:linear-gradient(#fff,#ddd)'></div>"
        b"<script>window.marker = Math.random().toString(36).slice(2)</script>")


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(PAGE)))
        self.end_headers()
        self.wfile.write(PAGE)

    def log_message(self, *_):
        pass


def bench(*args):
    return json.loads(harness.command(str(harness.ROOT / "bench"), "--world", harness.WORLD,
                                      "--json", *args, seconds=35))


def active():
    return next(tab for tab in bench("tabs")["tabs"] if tab["active"])


def value(tab_id, script):
    return bench("eval", tab_id, script)["value"]


def quit_app():
    bench("press", "12", "q", "cmd")
    harness.until("quit", lambda: not harness.running(), 20)


def main_window(probe):
    return next(w for w in probe["windows"] if w["kind"] == "AppKitWindow" and w["visible"] and w["frame"][2] > 600)


def state(tab_id):
    probe = bench("probe")
    return {
        "marker": value(tab_id, "window.marker"),
        "draft": value(tab_id, "document.getElementById('draft').value"),
        "scroll": value(tab_id, "Math.round(window.scrollY)"),
        "zoom": active()["pageZoom"],
        "tabs": len(bench("tabs")["tabs"]),
        "opaque": main_window(probe)["opaque"],
        "depth": probe["depth"],
        "reducing": probe["reduceTransparency"],
        "lightsHidden": probe["lightsHidden"],
    }


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    Thread(target=server.serve_forever, daemon=True).start()
    with harness.world(server):
        harness.command("defaults", "write", harness.SUITE, "sidebar", "-bool", "YES")
        harness.launch()
        bench("resize", "1180", "780")
        url = f"http://127.0.0.1:{server.server_port}/"
        bench("field", url, "go")
        harness.wait_for("local page", active, {"url": url, "loading": False})
        tab_id = active()["id"]
        harness.until("marker", lambda: bool(value(tab_id, "window.marker")))
        bench("tap", tab_id, "#draft")
        bench("key", tab_id, "draft kept")
        harness.until("typed draft", lambda: value(tab_id, "document.getElementById('draft').value") == "draft kept")
        value(tab_id, "window.scrollTo(0, 900), 0")
        # WebKit quantizes scroll at the page's zoom (100% is now 1 / 1.1).
        # Allow one unzoomed pixel only when preparing the fixture; every
        # subsequent preservation assertion still compares the exact value.
        tolerance = 1 / active()["pageZoom"]
        harness.until("scroll near 900 CSS px", lambda: abs(value(tab_id, "window.scrollY") - 900) <= tolerance)

        first = state(tab_id)
        assert first["depth"] == "subtle", first
        assert first["opaque"] == first["reducing"], ("the default lets the desktop through", first)

        # The envelope round the page is not the page, and the page ends
        # where its frame does (standard size: an inset of 8 × 1.04).
        width, height = bench("resize", "1180", "780")["size"]
        assert bench("hit", str(width - 3), str(height // 2))["view"] != "PageView", "right inset"
        assert bench("hit", str(width // 2), str(height - 3))["view"] != "PageView", "bottom inset"
        assert bench("hit", str(width - 14), str(height // 2))["view"] == "PageView", "page's right edge"
        assert bench("hit", str(width // 2), str(height - 14))["view"] == "PageView", "page's bottom edge"

        changes = [
            ("depth", "clear"), ("depth", "solid"), ("depth", "subtle"),
            ("look", "dark"), ("look", "light"),
            ("sidebar", "off"), ("sidebar", "on"),
            ("size", "large"), ("size", "standard"),
            ("folded", "on"), ("folded", "off"),
            ("bar", "off"), ("bar", "on"),
            ("contrast", "on"), ("contrast", "off"),
            ("tone", "escale"), ("look", "dark"), ("tone", "neutral"), ("look", "light"),
        ]
        seen = []
        for key, wanted in changes:
            bench("ui", key, wanted)
            # Preserve the late-state assertion after the 500 ms fold/window
            # transition; observing the preference alone would finish too soon.
            time.sleep(0.6)
            now = state(tab_id)
            for field in ("marker", "draft", "scroll", "zoom", "tabs"):
                assert now[field] == first[field], (key, wanted, field, first[field], now[field])
            if key == "depth":
                harness.until(f"depth {wanted}", lambda: bench("probe")["depth"] == wanted)
                opaque = main_window(bench("probe"))["opaque"]
                assert opaque == (wanted == "solid" or now["reducing"]), (wanted, opaque)
            if key == "contrast":
                # The window is rebuilt; the page must come through untouched.
                assert bench("probe")["increasesContrast"] == (wanted == "on"), wanted
            if key == "tone":
                # Rebuilt as for contrast: the page must come through untouched.
                assert bench("probe")["tone"] == wanted, wanted
            if key == "folded" and wanted == "on":
                # In sidebar mode the rail and native title-bar lights remain
                # present while only the tab column folds away.
                assert not now["lightsHidden"], "sidebar fold hid the title-bar lights"
            seen.append(f"{key} {wanted}")

        # Settings stand in for the page, in its frame. Opening them must
        # leave the WebKit document in place, block page hits and leave the
        # column and the bar above the page where they are, title-bar drag
        # included.
        bench("ui", "settings", "on")
        assert bench("probe")["settings"], "Settings did not open"
        assert bench("probe")["bar"], "Settings took the address bar away"
        # Stay beyond Settings' label at the current interface scale. The old
        # x=500 landed on its text after layout settled, not on the drag strip.
        harness.wait_for("drag strip beside Settings", lambda: bench("hit", "700", "20"), {"view": "Strip"})
        assert bench("hit", "700", "500")["view"] != "PageView", "Settings exposed the page"
        for wanted in ("solid", "clear", "subtle"):
            bench("ui", "depth", wanted)
            now = state(tab_id)
            for field in ("marker", "draft", "scroll", "zoom", "tabs"):
                assert now[field] == first[field], ("Settings", wanted, field, first[field], now[field])
            assert now["opaque"] == (wanted == "solid" or now["reducing"]), (wanted, now)
        bench("ui", "sidebar", "off")
        # The tab row stays: its one tab at the left, free row to the right.
        assert bench("probe")["settings"], "Changing the layout closed Settings"
        harness.wait_for("top tabs' drag strip beside Settings", lambda: bench("hit", "900", "20"), {"view": "Strip"})
        assert bench("hit", "700", "500")["view"] != "PageView", "Settings exposed the page in top tabs"
        bench("ui", "sidebar", "on")
        harness.wait_for("sidebar's drag strip beside Settings", lambda: bench("hit", "700", "20"), {"view": "Strip"})
        bench("ui", "settings", "off")
        assert not bench("probe")["settings"], "Settings did not close"
        assert state(tab_id)["marker"] == first["marker"], "Settings rebuilt the page"
        # Picking the tab on screen, from the column beside Settings, brings
        # its page back.
        bench("ui", "settings", "on")
        bench("select", tab_id)
        assert not bench("probe")["settings"], "Picking the tab left Settings in its place"
        assert state(tab_id)["marker"] == first["marker"], "Picking the tab rebuilt the page"

        bench("ui", "depth", "clear")
        bench("ui", "tone", "escale")
        # ⌘Q is pressed on the app; the draft's caret is let go first, as the
        # other quitting scenarios never have one in a page.
        value(tab_id, "document.activeElement.blur(), 0")
        quit_app()
        harness.launch()
        harness.until("saved depth", lambda: bench("probe")["depth"] == "clear")
        assert bench("probe")["tone"] == "escale", "the Colours choice did not survive a restart"

        quit_app()
        harness.command("defaults", "write", harness.SUITE, "depth", "-string", "frosted")
        harness.command("defaults", "write", harness.SUITE, "tone", "-string", "warm")
        harness.launch()
        harness.until("unknown depth reads as default", lambda: bench("probe")["depth"] == "subtle")
        assert bench("probe")["tone"] == "neutral", "an unknown tone did not read as neutral"
        print(f"ok: page kept (marker, draft, scroll {first['scroll']}, zoom {first['zoom']}, {first['tabs']} tab) across "
              f"{len(seen)} changes and Settings; Settings in the page's frame keep the bar and drag strip, "
              "not the page, and give way to the tab picked; "
              "envelope and page hit-tested apart; window opaque only when solid; "
              f"depth clear and tone escale restored; unknown values read as subtle and neutral")


if __name__ == "__main__":
    main()
