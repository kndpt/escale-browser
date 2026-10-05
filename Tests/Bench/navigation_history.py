#!/usr/bin/env python3
"""Recent navigation entries lead directly to the selected page, and a load
that fails keeps the address it was sent to.

Run after ./build.sh debug. Three local pages in one ordinary tab provide a
back and forward list. The test checks nearest-first order, a two-step jump
in each direction, and the tab's resulting address in an isolated world.
A port with nothing listening then fails a navigation from the last page: the
tab must name that address, not the page before it, and Retry must load it.
The shared runner owns a unique world, its diagnostics and cleanup.
The native menu's position and held-button gesture need a visual app check.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
import json
import socket
import time
import suite as harness

class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/")
        body = f"<title>{name.title()} page</title><h1>{name.title()} page</h1>".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


class Slow(Page):
    """Answers late, so a second reload lands while the first is still loading."""
    def do_GET(self):
        time.sleep(1.5)
        super().do_GET()


def bench(*args):
    return json.loads(harness.command(str(harness.ROOT / "bench"), "--world", harness.WORLD,
                                      "--json", *args, seconds=30))


def active():
    return next(tab for tab in bench("tabs")["tabs"] if tab["active"])


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    with harness.world(server):
        harness.launch()
        bench("ui", "sidebar", "on")
        base = f"http://127.0.0.1:{server.server_port}"
        tab_id = active()["id"]
        for name in ("first", "second", "third"):
            url = f"{base}/{name}"
            bench("field", url, "go")
            harness.wait_for(name, active, {"url": url, "loading": False})

        prior = bench("history", tab_id, "back")
        harness.require("backward history order", [item["title"] for item in prior["items"]],
                        ["Second page", "First page"])
        bench("history", tab_id, "back", "2")
        harness.wait_for("jump back two", active, {"url": f"{base}/first", "loading": False})

        ahead = bench("history", tab_id, "forward")
        harness.require("forward history order", [item["title"] for item in ahead["items"]],
                        ["Second page", "Third page"])
        bench("history", tab_id, "forward", "2")
        harness.wait_for("jump forward two", active, {"url": f"{base}/third", "loading": False})
        print("ok: recent pages are nearest first; selecting the second entry jumps directly in both directions")

        # Nothing listens here yet, as a site whose address was typed ahead of its deploy.
        with socket.socket() as spare:
            spare.bind(("127.0.0.1", 0))
            dead = f"http://127.0.0.1:{spare.getsockname()[1]}/soon"
        bench("field", dead, "go")
        harness.until("failure shown", lambda: active().get("failure", "") != "", 15)
        harness.wait_for("failed navigation settles", active, {"url": dead, "loading": False})
        harness.require("address stays on the failed load", active()["url"], dead)
        harness.require("the view still holds the page before", active()["view"], f"{base}/third")
        late = ThreadingHTTPServer(("127.0.0.1", int(dead.rsplit(":", 1)[1].split("/")[0])), Slow)
        Thread(target=late.serve_forever, daemon=True).start()
        try:
            # Twice in a row: the second must not send the view back to the page before.
            bench("press", "15", "r", "cmd")
            bench("press", "15", "r", "cmd")
            harness.until("retry reaches the failed address",
                          lambda: (lambda t: t["url"] == dead and t["view"] == dead and not t["loading"]
                                   and "failure" not in t)(active()), 15)
        finally:
            late.shutdown()
            late.server_close()
        print("ok: a failed load keeps its address and Retry loads it, not the page before")


if __name__ == "__main__":
    main()
