#!/usr/bin/env python3
"""A link's right-click menu: Open Link in Split View and Copy Link as Markdown.

In an owned world, on a loopback page, by real right-clicks: plain text gets
neither entry; a link gets both, after WebKit's own Copy Link. Copied as
Markdown, a link's brackets are escaped, a link with no text gives its
address, and a link in another origin's frame is named too. A page that
dispatches its own contextmenu on another link during a right-click can't
change the link named. Each right-click
names its own link, never the one before. Open Link in Split View puts the
link to the right of the page, up to three pages; a fourth is refused with the
limit message and no new tab. The clipboard is put back at the end. Run after
./build.sh debug, in front: the menus need the pointer. Not covered: how the
menu looks in light and dark (a native menu, reviewed by eye), a private tab,
and a page that cancels its own contextmenu event.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
import json
import subprocess
import suite as h

SPLIT = "Open Link in Split View"
MARKDOWN = "Copy Link as Markdown"
REFUSED = "Up to 3 panels in one Space and website store — enlarge the window if needed"
BOX = "display:block;width:200px;height:50px;margin:0 0 20px"


class Page(BaseHTTPRequestHandler):
    frame = ""

    def do_GET(self):
        if self.path == "/page":
            body = (f"<title>Links</title><body style='margin:20px'>"
                    f"<p id='plain' style='{BOX}'>Plain words</p>"
                    f"<a id='named' href='/target?x=1' style='{BOX}'>Docs [v2] page</a>"
                    f"<a id='bare' href='/bare' style='{BOX};background:#39f'><span></span></a>"
                    f"<a id='forged' href='/forged' style='{BOX}'>Forged</a><a id='evil' href='/evil' hidden>Evil</a>"
                    "<script>document.getElementById('forged').addEventListener('contextmenu', () =>"
                    " document.getElementById('evil').dispatchEvent(new MouseEvent('contextmenu', {bubbles: true})))</script>"
                    f"<iframe id='frame' src='{Page.frame}/inner' style='border:0;width:220px;height:60px'></iframe>")
        elif self.path == "/inner":
            body = f"<body style='margin:0'><a id='deep' href='/deep' style='{BOX}'>Deep link</a>"
        else:
            body = f"<title>{self.path}</title><h1>{self.path}</h1>"
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


def bench(*args):
    return json.loads(h.command(str(h.ROOT / "bench"), "--world", h.WORLD, "--json", *map(str, args)))


def clipboard():
    return subprocess.run(["pbpaste"], text=True, capture_output=True, timeout=5).stdout


def spot(page, element):
    """The middle of an element of the page, in window points from the top
    left: its CSS box scaled to the view, from wherever the view is drawn."""
    frame = h.until(f"page {page} drawn", lambda: next(
        (p.get("frame") for p in bench("panels")["pages"] if p["id"].lower().startswith(page)), None))
    js = ("(() => { const r = document.getElementById('%s').getBoundingClientRect();"
          " return [r.left + r.width / 2, r.top + r.height / 2, innerWidth]; })()")
    if element == "deep":
        # Inside the other origin's frame: the frame's box, then the link at its top left.
        x, y, width = bench("eval", page, js % "frame")["value"]
        x, y = x - 110 + 100, y - 30 + 25
    else:
        x, y, width = bench("eval", page, js % element)["value"]
    scale = frame[2] / width
    return frame[0] + x * scale, frame[1] + y * scale


def menu(page, element):
    x, y = spot(page, element)
    bench("pointer", "move", x, y)
    state = bench("pointer", "menu", x, y)
    h.require(f"{element}: a menu opened", state["tracking"], True)
    return [item["title"] for item in state["items"]]


def choose(page, element, title):
    titles = menu(page, element)
    if title not in titles:
        bench("pointer", "cancel")
        raise AssertionError(f"{element}: no {title} in {titles}")
    bench("pointer", "choose", titles.index(title))


def markdown(page, element, expected):
    choose(page, element, MARKDOWN)
    h.until(f"{element} as Markdown", lambda: clipboard() == expected, 10)


def group():
    groups = bench("panels")["groups"]
    return [[m[:8].lower() for m in g["members"]] for g in groups]


def main():
    servers = [ThreadingHTTPServer(("127.0.0.1", 0), Page) for _ in range(2)]
    for server in servers:
        Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{servers[0].server_port}"
    # Another port is another origin: the frame's document is out of the page's reach.
    Page.frame = f"http://127.0.0.1:{servers[1].server_port}"
    kept = clipboard()
    try:
        with h.world(servers[0]):
            h.launch()
            bench("resize", 1400, 900)
            page = h.open_ordinary(f"{base}/page")[:8].lower()

            titles = menu(page, "plain")
            bench("pointer", "cancel")
            h.require("plain text: no link entries", [t for t in titles if t in (SPLIT, MARKDOWN)], [])

            titles = menu(page, "named")
            bench("pointer", "cancel")
            ours = [t for t in titles if t in (SPLIT, MARKDOWN)]
            h.require("a link: both entries, in order", ours, [SPLIT, MARKDOWN])
            h.require("after WebKit's own", "Copy Link" in titles and titles.index("Copy Link") < titles.index(SPLIT), True)

            markdown(page, "named", f"[Docs \\[v2\\] page]({base}/target?x=1)")
            h.require("the copy is said", bench("probe")["announcement"], "Link copied")
            markdown(page, "bare", f"[{base}/bare]({base}/bare)")
            markdown(page, "deep", f"[Deep link]({Page.frame}/deep)")
            markdown(page, "forged", f"[Forged]({base}/forged)")
            markdown(page, "named", f"[Docs \\[v2\\] page]({base}/target?x=1)")

            before = len(h.tabs())
            choose(page, "named", SPLIT)
            h.until("the link in a split", lambda: len(group()) == 1 and len(group()[0]) == 2)
            members = group()[0]
            h.require("the page on the left", members[0], page)
            new = next(t for t in h.tabs() if t["id"][:8].lower() == members[1])
            h.require("the link on the right", new["url"], f"{base}/target?x=1")
            choose(page, "bare", SPLIT)
            h.until("a third page", lambda: len(group()) == 1 and len(group()[0]) == 3)
            h.require("three pages, two new tabs", len(h.tabs()), before + 2)

            choose(page, "named", SPLIT)
            h.until("the refusal said", lambda: bench("probe")["announcement"] == REFUSED, 10)
            h.require("no fourth page", (len(group()[0]), len(h.tabs())), (3, before + 2))
            print("link menu: entries only on links, Markdown escaped and addressed, frames named, forged events ignored, split to three and refused")
    finally:
        servers[1].shutdown()
        servers[1].server_close()
        subprocess.run(["pbcopy"], input=kept, text=True, timeout=5)


if __name__ == "__main__":
    main()
