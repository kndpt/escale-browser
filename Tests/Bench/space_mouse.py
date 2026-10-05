#!/usr/bin/env python3
"""Mouse navigation and tab transfer keep the right WebKit store and draft.

Run after ./build.sh debug. A loopback page supplies an ordinary tab in an
isolated world. `bench drag` exercises the empty sidebar's real mouse path;
`space transfer` exercises the same drop operation without depending on the
system's pointer position. The icon-target drag is checked visually as well.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread
import json
import os
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]
WORLD = "space-mouse"


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"<!doctype html><title>Move this tab</title><h1>Move this tab</h1>"
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


def main():
    assert (ROOT / "build/Escale.app").exists(), "run ./build.sh debug first"
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    Thread(target=server.serve_forever, daemon=True).start()
    env = dict(os.environ, ESCALE_PROBE=WORLD)
    try:
        run("./fresh.sh", "wipe", env=env)
        run("defaults", "write", f"com.kndpt.escale.test.{WORLD}", "bench", "-bool", "YES")
        run("./fresh.sh", "again", env=env)
        bench("ui", "welcome", "off")
        bench("ui", "sidebar", "on")
        bench("space", "new", "Isolated")
        bench("space", "go", "1")
        bench("drag", "140", "300", "40", "300")
        until("mouse swipe to second space", lambda: bench("space")["current"] == "Isolated")
        bench("space", "go", "1")

        url = f"http://127.0.0.1:{server.server_port}/"
        bench("field", url, "go")
        until("ordinary page", lambda: any(t["url"] == url and not t["loading"] for t in bench("tabs")["tabs"]))
        source = next(t for t in bench("tabs")["tabs"] if t["url"] == url)
        assert source["store"] == "default", source
        bench("eval", source["id"], "document.cookie='space-transfer=source; Path=/'; 'set'")
        assert "space-transfer=source" in bench("eval", source["id"], "document.cookie")["value"]
        bench("space", "transfer", source["id"], "2")
        assert bench("space")["current"] == "Isolated"
        moved = next(t for t in bench("tabs")["tabs"] if t["url"] == url)
        assert moved["id"] != source["id"] and moved["store"] != source["store"], (source, moved)
        bench("wait", moved["id"], "20")
        assert "space-transfer" not in bench("eval", moved["id"], "document.cookie")["value"]
        bench("space", "go", "1")
        assert all(t["id"] != source["id"] for t in bench("tabs")["tabs"]), "source tab survived transfer"
        bench("field", url, "go")
        until("second ordinary page", lambda: any(t["url"] == url and not t["loading"] for t in bench("tabs")["tabs"]))
        pinned = next(t for t in bench("tabs")["tabs"] if t["url"] == url)
        bench("pin", pinned["id"])
        bench("space", "transfer", pinned["id"], "2")
        retained = next(t for t in bench("tabs")["tabs"] if t["url"] == url and t["id"] != moved["id"])
        assert retained["pin"] and retained["store"] == moved["store"], retained
        assert bench("tabs")["tabs"][0]["id"] == retained["id"], "transferred pin must lead loose tabs"
        # Each space owns its extensions: a page from one the destination
        # has not loaded stays where it is instead of carrying the source's
        # extension context and storage across.
        bench("space", "go", "1")
        with tempfile.TemporaryDirectory(prefix="escale-space-extension-") as temporary:
            folder = Path(temporary)
            (folder / "manifest.json").write_text(json.dumps({
                "manifest_version": 3, "name": "Space transfer fixture", "version": "1.0"
            }))
            (folder / "page.html").write_text("<title>Extension kept</title><h1>Extension kept</h1>")
            bench("--yes", "ext-folder", str(folder))

            def loaded():
                found = [item for item in bench("extensions")["extensions"]
                         if item["name"] == "Space transfer fixture" and item["loaded"]]
                return found[0] if found else None

            until("extension loaded", loaded)
            page_url = loaded()["base"] + "page.html"
            bench("ext-page", loaded()["id"], "page.html", "--ordinary")
            until("ordinary extension page", lambda: any(
                t["url"] == page_url and not t["loading"] for t in bench("tabs")["tabs"]))
            source_page = next(t for t in bench("tabs")["tabs"] if t["url"] == page_url)
            assert bench("eval", source_page["id"], "document.title")["value"] == "Extension kept"
            bench("space", "transfer", source_page["id"], "2")
            assert bench("space")["current"] != "Isolated", "refused transfer must not switch spaces"
            kept = next(t for t in bench("tabs")["tabs"] if t["url"] == page_url)
            assert kept["id"] == source_page["id"], "extension page left its space"
            saved = bench("shelf", "keep")["rows"]
            assert any(row["tab"] and row["live"] for row in saved), saved
            release = bench("drag", "120", "123", "26", "100", "900", "120", "123", "live")
            assert release["heldSpace"] == bench("space")["spaces"][1]["id"], release
            bench("space", "go", "1")
            assert any(row["tab"] for row in bench("shelf")["rows"]), "extension bookmark left its space"
            assert any(t["id"] == source_page["id"] for t in bench("tabs")["tabs"]), "linked page detached"

        bench("space", "go", "1")
        bench("press", "45", "n", "cmd", "shift")
        assert bench("probe")["searchPrivate"]
        bench("field", url, "go")
        shy = next(t for t in bench("tabs")["tabs"] if t["active"])
        assert shy["shy"], shy
        until("private page", lambda: any(t["id"] == shy["id"] and
              t["url"] == url and not t["loading"] for t in bench("tabs")["tabs"]))
        bench("eval", shy["id"], "document.cookie='private-transfer=kept; Path=/'; 'set'")
        assert "private-transfer=kept" in bench("eval", shy["id"], "document.cookie")["value"]
        bench("space", "transfer", shy["id"], "2")
        private_moved = next(t for t in bench("tabs")["tabs"] if t["active"])
        assert private_moved["shy"] and private_moved["store"] == shy["store"], (shy, private_moved)
        bench("wait", private_moved["id"], "20")
        assert "private-transfer=kept" in bench("eval", private_moved["id"], "document.cookie")["value"]

        bench("space", "go", "1")
        # This regression needs a real empty page, not an uncommitted search.
        # Closing the fixture's last loaded tab supplies the existing empty state.
        for tab in bench("tabs")["tabs"]:
            if tab["url"]:
                bench("select", tab["id"])
                bench("press", "13", "w", "cmd")
        blank = next(t for t in bench("tabs")["tabs"] if t["active"])
        assert blank["url"] == "" and not blank["shy"], blank
        bench("field", "unfinished localhost address")
        assert bench("probe")["typed"] == "unfinished localhost address"
        bench("space", "transfer", blank["id"], "2")
        new_blank = next(t for t in bench("tabs")["tabs"] if t["active"])
        assert new_blank["id"] != blank["id"] and new_blank["url"] == "" and not new_blank["shy"], new_blank
        assert bench("probe")["typed"] == "unfinished localhost address"
        bench("space", "go", "1")
        assert all(t["id"] != blank["id"] for t in bench("tabs")["tabs"])
        print("space mouse: swipe, isolated and private transfers, extension bookmark and page kept, blank draft")
    finally:
        server.shutdown()
        run("./fresh.sh", "wipe", env=env)


if __name__ == "__main__":
    main()
