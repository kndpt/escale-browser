#!/usr/bin/env python3
"""A tab moves to another Space from its menu or a key, as a drag does.

In an owned world with Move Tab to Previous/Next Space bound to ⌥⌘P and ⌥⌘O
(they have no default), in the sidebar and then the top tab bar: a regular, a
pinned and a private tab each go from Personal to Two through the right-click
menu's Move to Space, then to Three by the Next key and back to Two by the
Previous key, keeping their pin and privacy. After ⌘Q and a relaunch the
regular and pinned ones are still in Two. With one Space or Spaces off the
entry is gone and the keys do nothing; a bench tab's refused move is
announced. Run after ./build.sh debug, in front: the menus need the pointer.
Not covered: the Tabs menu in the menu bar (the same view, picked by hand),
the icons drawn in the menu, an extension page's refusal (space_mouse.py) and
private tabs after a relaunch, which are never kept.
"""
from http.server import ThreadingHTTPServer
from threading import Thread
import json
import suite as h

# ⌥⌘, as NSEvent.ModifierFlags: option and command (Control–Option is VoiceOver's).
CHORD = 524288 + 1048576
NEXT = (31, "o", "opt", "cmd")
PREVIOUS = (35, "p", "opt", "cmd")


def bench(*args):
    return json.loads(h.command(str(h.ROOT / "bench"), "--world", h.WORLD, "--json", *map(str, args)))


def current():
    return bench("space")["current"]


def active():
    return next(t for t in h.tabs() if t["active"])


def place(ident):
    """The tab's row or square as drawn, once it holds still: the frames the
    test build publishes for every tab in the column or the strip."""
    seen = []

    def still():
        frame = next((e["frame"] for e in bench("panels")["entries"]
                      if e["id"].lower().startswith(ident)), None)
        seen.append(frame)
        return frame is not None and seen[-3:] == [frame] * 3

    h.until(f"tab {ident} drawn and still", still)
    x, y, w, height = seen[-1]
    return x + min(w / 2, 40), y + height / 2


def tab_menu(ident):
    """The tab's right-click menu. The hand arrives first, as one does: a
    press with no move before it can land on the window's host instead."""
    x, y = place(ident)
    bench("pointer", "move", x, y)
    state = bench("pointer", "menu", x, y)
    titles = [item["title"] for item in state["items"]]
    assert "Close Other Tabs" in titles, state
    return state["items"]


def make(kind, url):
    if kind == "private":
        bench("press", 45, "n", "cmd", "shift")
        bench("field", url, "go")
        h.until("private page", lambda: active()["shy"] and active()["url"] == url and not active()["loading"])
        return active()["id"]
    ident = h.open_ordinary(url)
    if kind == "pinned":
        bench("pin", ident)
    return ident


def shape(url):
    tab = next((t for t in h.tabs() if t["url"] == url), None)
    return tab and {"pinned": bool(tab["pin"]), "private": tab["shy"]}


def lands(what, space, url, kind):
    h.wait_for(what, lambda: {"space": current(), "tab": shape(url)},
               {"space": space, "tab": {"pinned": kind == "pinned", "private": kind == "private"}})


def nowhere(ident, url, what):
    """No Move to Space in the tab's menu, and the keys leave it alone."""
    items = tab_menu(ident)
    bench("pointer", "cancel")
    h.require(what + ": no Move to Space", "Move to Space" in [i["title"] for i in items], False)
    before = current()
    bench("press", *NEXT)
    bench("press", *PREVIOUS)
    h.require(what + ": the keys do nothing", (current(), shape(url) is not None), (before, True))


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), h.Page)
    Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    with h.world(server):
        # Store uses Data, as Preferences does. Never touch a production suite.
        data = json.dumps({"overrides": {
            "moveTabToNextSpace": [{"key": "o", "modifiers": CHORD}],
            "moveTabToPreviousSpace": [{"key": "p", "modifiers": CHORD}],
        }}).encode().hex()
        h.command("defaults", "write", h.SUITE, "keyboard.bindings", "-data", data)
        h.launch()
        bench("ui", "spaces", "on")
        bench("ui", "sidebar", "on")
        home = current()

        lonely = make("regular", f"{base}/lonely")
        nowhere(lonely, f"{base}/lonely", "one Space")
        bench("space", "new", "Two")
        bench("space", "new", "Three")
        bench("space", "go", 1)
        bench("ui", "spaces", "off")
        nowhere(lonely, f"{base}/lonely", "Spaces off")
        bench("ui", "spaces", "on")

        for sidebar in (True, False):
            bench("ui", "sidebar", "on" if sidebar else "off")
            for kind in ("regular", "pinned", "private"):
                layout = "sidebar" if sidebar else "top"
                url = f"{base}/{layout}-{kind}"
                bench("space", "go", 1)
                items = tab_menu(make(kind, url))
                titles = [i["title"] for i in items]
                where = titles.index("Move to Space")
                h.require(f"{layout} {kind}: the other Spaces", items[where].get("submenu"), ["Two", "Three"])
                bench("pointer", "choose", where, 0)
                lands(f"{layout} {kind} by its menu", "Two", url, kind)
                bench("press", *NEXT)
                lands(f"{layout} {kind} by the Next key", "Three", url, kind)
                bench("press", *PREVIOUS)
                lands(f"{layout} {kind} by the Previous key", "Two", url, kind)

        bench("space", "go", 1)
        refused = bench("open", f"{base}/bench")["id"]
        bench("space", "transfer", refused, 2)
        h.require("a refused move is announced", (current(), bench("probe")["announcement"]),
                  (home, "This tab can’t move to “Two”"))
        bench("close", refused)

        try:
            bench("press", 12, "q", "cmd")
        except (AssertionError, ValueError):
            pass  # The socket may close with the app before it answers.
        h.until("the app to quit", lambda: not h.running(), 30)
        h.launch()
        bench("space", "go", 2)
        for layout in ("sidebar", "top"):
            for kind in ("regular", "pinned"):
                url = f"{base}/{layout}-{kind}"
                h.wait_for(f"{layout} {kind} in Two after relaunch", lambda: {"space": current(), "tab": shape(url)},
                           {"space": "Two", "tab": {"pinned": kind == "pinned", "private": False}})
        print("space send: menu and keys in both layouts, pins and privacy kept, refusal said, relaunch kept")


if __name__ == "__main__":
    main()
