#!/usr/bin/env python3
"""⌘-click on the native navigation doors opens a background tab.

Three loopback pages give WebKit a real back/forward list. AppKit delivers
mouse events with Command held to both chrome layouts, while request counts
show that the source page did not navigate or reload.
"""

from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Lock, Thread
import json
import suite as harness


hits = Counter()
lock = Lock()


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        with lock:
            hits[self.path] += 1
        body = f"<title>{self.path}</title><h1>{self.path}</h1>".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def bench(*args):
    return json.loads(harness.command(str(harness.ROOT / "bench"), "--world", harness.WORLD,
                                      "--json", *args, seconds=30))


def active():
    return next(tab for tab in bench("tabs")["tabs"] if tab["active"])


def tab_with(tab_id):
    return next(tab for tab in bench("tabs")["tabs"] if tab["id"] == tab_id)


def click(which, sidebar, command=True):
    probe = bench("probe")
    y = probe["lights"][0][1]
    x = (112 if sidebar else 126) + (32 * which)
    if command:
        return bench("hit", str(x), str(y), "command", "live")
    return bench("pointer", "click", str(x), str(y))


def opened(which, sidebar, source, url):
    before = {tab["id"] for tab in bench("tabs")["tabs"]}
    click(which, sidebar)
    def new_tab():
        added = [tab for tab in bench("tabs")["tabs"] if tab["id"] not in before]
        return added[0] if len(added) == 1 and added[0]["url"] == url and not added[0]["loading"] else None
    result = harness.until(f"⌘-click {which} opens {url}", new_tab, 15)
    harness.require("source remains active", active()["id"], source)
    harness.require("new tab stays in source Space", result["space"], tab_with(source)["space"])
    harness.require("new tab keeps source privacy", result["shy"], tab_with(source)["shy"])
    return result


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    Thread(target=server.serve_forever, daemon=True).start()
    with harness.world(server):
        harness.launch()
        base = f"http://127.0.0.1:{server.server_port}"
        first = base + "/first?x=1#part"
        second = base + "/second"
        third = base + "/third"
        for sidebar in (False, True):
            bench("ui", "sidebar", "on" if sidebar else "off")
            bench("ui", "bar", "off")
            for url in (first, second, third):
                bench("field", url, "go")
                harness.wait_for("page loads", active, {"url": url, "loading": False})
            source = active()["id"]
            with lock:
                third_before = hits["/third"]
            opened(0, sidebar, source, second)
            harness.require("Back leaves source at third", tab_with(source)["url"], third)
            with lock:
                harness.require("Back does not reload source", hits["/third"], third_before)
            opened(2, sidebar, source, third)
            with lock:
                harness.require("Reload does not reload source", hits["/third"], third_before + 1)
            click(0, sidebar, command=False)
            harness.wait_for("ordinary Back", active, {"url": second, "loading": False})
            opened(1, sidebar, source, third)
            harness.require("Forward leaves source at second", tab_with(source)["url"], second)
            click(1, sidebar, command=False)
            harness.wait_for("ordinary Forward", active, {"url": third, "loading": False})
            click(0, sidebar, command=False)
            harness.wait_for("ordinary Back to second", active, {"url": second, "loading": False})
            opened(0, sidebar, source, first)

        bench("press", "45", "n", "cmd", "shift")
        for url in (base + "/private-first", base + "/private-second"):
            bench("field", url, "go")
            harness.wait_for("private page loads", active, {"url": url, "loading": False})
        private = active()["id"]
        harness.require("private source", active()["shy"], True)
        opened(0, True, private, base + "/private-first")

        bench("ui", "spaces", "on")
        bench("space", "new", "Other navigation")
        for url in (base + "/space-first", base + "/space-second"):
            bench("field", url, "go")
            harness.wait_for("other Space page loads", active, {"url": url, "loading": False})
        opened(0, True, active()["id"], base + "/space-first")
        print("ok: native ⌘-click opens background Back, Forward and Reload tabs in both layouts, private tabs and Spaces")


if __name__ == "__main__":
    main()
