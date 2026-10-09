#!/usr/bin/env python3
"""The bookmarks door knows the page on screen is a bookmark of this Space.

Across the top, ⇧⌘B adds the page; the state follows a navigation away and
back and stays in its own Space; ⇧⌘B again opens the dropdown's actions on
that bookmark, where Rename and Remove are clicked through the app's event
dispatch. Loopback pages in an owned world. Not covered: the door's drawing
(a visual review) and Show in List, which changes no state the bench reads.
"""
from http.server import ThreadingHTTPServer
from threading import Thread
import json
import suite as h

B, BRACKET, RETURN = (11, "b"), (33, "["), (36, "\r")
# The dropdown's foot, from the popover's bottom edge to each row's middle:
# Manage Bookmarks… 33, Show in List 61, Rename 90, Remove 118.
RENAME, REMOVE = 90, 118


def bench(*args):
    return json.loads(h.command(str(h.ROOT / "bench"), "--world", h.WORLD, "--json", *map(str, args)))


def state():
    probe = bench("probe")
    rows = [row["title"] for row in bench("shelf")["rows"]]
    return {"bookmarked": probe["bookmarked"], "dropdown": probe["bookmarksDropdown"], "rows": rows}


def active():
    return next(tab for tab in h.tabs() if tab["active"])


def visit(url):
    bench("field", url, "go")
    h.wait_for(url, active, {"url": url, "loading": False})


def click(offset):
    size = bench("popover")["size"]
    bench("popover", size[0] / 2, size[1] - offset)


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), h.Page)
    Thread(target=server.serve_forever, daemon=True).start()
    with h.world(server):
        h.launch()
        bench("ui", "sidebar", "off")
        base = f"http://127.0.0.1:{server.server_port}"
        visit(f"{base}/a")
        h.wait_for("a page not kept", state, {"bookmarked": "", "dropdown": False, "rows": []})

        bench("press", *B, "cmd", "shift")
        h.wait_for("added", state, {"bookmarked": "Suite a", "dropdown": False, "rows": ["Suite a"]})
        visit(f"{base}/b")
        h.wait_for("away", state, {"bookmarked": ""})
        bench("press", *BRACKET, "cmd")
        h.wait_for("back", active, {"url": f"{base}/a", "loading": False})
        h.wait_for("kept again", state, {"bookmarked": "Suite a"})
        print("ok: ⇧⌘B adds the page and the door follows it away and back")

        bench("space", "new", "Other")
        visit(f"{base}/a")
        h.wait_for("another Space", state, {"bookmarked": "", "rows": []})
        bench("space", "go", "1")
        h.wait_for("its own Space", state, {"bookmarked": "Suite a"})
        print("ok: only this Space's bookmarks mark the page")

        bench("press", *B, "cmd", "shift")
        h.wait_for("actions open", state, {"bookmarked": "Suite a", "dropdown": True, "rows": ["Suite a"]})
        click(RENAME)
        bench("press", 0, "a", "cmd")
        for code, letter in ((40, "k"), (14, "e"), (35, "p"), (17, "t")):
            bench("press", code, letter)
        bench("press", *RETURN)
        h.wait_for("renamed", state, {"bookmarked": "kept", "rows": ["kept"]})
        click(REMOVE)
        h.wait_for("removed", state, {"bookmarked": "", "rows": []})
        print("ok: ⇧⌘B on a kept page opens its actions; Rename and Remove work from the dropdown")


if __name__ == "__main__":
    main()
