#!/usr/bin/env python3
"""Spaces reorder by dragging their icons in the rail.

A live pointer drag carries the third icon to the top without switching
Space; Escape (even over Select Area) or a release beside, above or below the
rail leaves the order alone; a plain click still switches. After ⌘Q and a relaunch, the order holds and ⌃1 opens
the moved Space. Run after ./build.sh debug, in an owned world. Not covered:
Reduce Motion (only an animation is dropped) and the drawn landing preview.
"""
from http.server import ThreadingHTTPServer
from threading import Thread
import json
import suite as h

# Door centres at the standard interface size: 32-point doors, 4 apart,
# the first under the title line (as in space_drag.py).
X = 26


def door(index):
    return 64 + 36 * index


def bench(*args):
    return json.loads(h.command(str(h.ROOT / "bench"), "--world", h.WORLD, "--json", *map(str, args)))


def names():
    return [space["name"] for space in bench("space")["spaces"]]


def current():
    return bench("space")["current"]


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), h.Page)
    Thread(target=server.serve_forever, daemon=True).start()
    with h.world(server):
        h.launch()
        bench("ui", "sidebar", "on")
        bench("space", "new", "Two")
        bench("space", "new", "Three")
        h.require("three Spaces", names(), ["Personal", "Two", "Three"])

        bench("hit", X, door(2), "click", "live")
        h.until("a click switches Space", lambda: current() == "Three")
        bench("space", "go", "2")

        bench("drag", X, door(2), X, door(0) - 4, 300, "live")
        h.wait_for("third Space first", lambda: {"order": names(), "current": current()},
                   {"order": ["Three", "Personal", "Two"], "current": "Two"})

        bench("drag", X, door(0), X, door(2) + 4, 300, "escape", "live")
        h.require("Escape cancels", (names(), current()), (["Three", "Personal", "Two"], "Two"))
        bench("drag", X, door(0), 220, door(2), 300, "live")
        h.require("a drop beyond the rail cancels", (names(), current()), (["Three", "Personal", "Two"], "Two"))
        bench("drag", X, door(2), X, -30, 300, "live")
        h.require("a drop above the rail cancels", (names(), current()), (["Three", "Personal", "Two"], "Two"))

        # Escape cancels the held icon before an open Select Area takes it.
        tab = h.open_ordinary(f"http://127.0.0.1:{server.server_port}/area")
        bench("page-capture", tab, json.dumps({"action": "area", "step": "start"}))
        bench("drag", X, door(2), X, door(0) - 4, 300, "escape", "live")
        h.require("Escape over Select Area cancels the drag",
                  (names(), bench("page-capture", tab)["area"]["active"]), (["Three", "Personal", "Two"], True))
        bench("page-capture", tab, json.dumps({"action": "area", "step": "stop"}))

        try:
            bench("press", 12, "q", "cmd")
        except (AssertionError, ValueError):
            pass  # The socket may close with the app before it answers.
        h.until("the app to quit", lambda: not h.running(), 30)
        h.launch()
        h.require("after relaunch", (names(), current()), (["Three", "Personal", "Two"], "Two"))
        bench("press", 18, "1", "ctrl")
        h.until("⌃1 opens the moved Space", lambda: current() == "Three")
        print("space reorder: drag, Escape, outside drop, click, relaunch and ⌃1 passed")


if __name__ == "__main__":
    main()
