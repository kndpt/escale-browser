#!/usr/bin/env python3
"""The visible tab-search entrance opens the same focused switcher as Cmd K.

Real pointer events cover crowded/narrow columns, folded columns and top tabs
in both themes and all interface sizes. Only an owned world and loopback pages
are used; tab counts, result order and page identity must survive cancellation.
"""
from http.server import ThreadingHTTPServer
from threading import Thread
import json
import math
import time
import suite as h


def bench(*args):
    return json.loads(h.command(str(h.ROOT / "bench"), "--world", h.WORLD,
                                "--json", *map(str, args)))


def escape():
    selected = bench("probe")["picked"] != -1
    bench("press", 53, "\x1b")
    if selected:
        # The existing switcher clears the result before closing the field.
        h.require("Escape clears selection", bench("probe")["picked"], -1)
        bench("press", 53, "\x1b")
    h.until("switcher dismissed", lambda: not bench("probe")["fieldShowing"])


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), h.Page)
    Thread(target=server.serve_forever, daemon=True).start()
    with h.world(server):
        # Minimum column width catches collisions hidden by the default width.
        h.command("defaults", "write", h.SUITE, "sidebar.width", "-float", "176")
        h.launch()
        bench("ui", "sidebar", "on")
        bench("ui", "shelf", "on")
        bench("resize", 1000, 640)
        tabs = [h.open_ordinary(f"http://127.0.0.1:{server.server_port}/documentation-long-title-{n}" + ("-needle" if n == 17 else ""))
                for n in range(20)]
        bench("pin", tabs[0], "on")
        bench("select", tabs[1])
        bench("shelf", "keep")
        bench("select", tabs[-1])
        bench("eval", tabs[-1], "window.searchMarker = 'kept'")
        # A shortcut from outside the process, as the physical keyboard sends
        # it, reaches neither the window's shortcuts nor the field.
        count = len(h.tabs())
        bench("press", 17, "t", "cmd", "outside")
        state = bench("probe")
        h.require("outside shortcut ignored", (state["fieldShowing"], state["openingTab"], len(h.tabs())),
                  (False, False, count))
        checked = 0
        for theme in ("light", "dark"):
            bench("ui", "look", theme)
            for size, factor in (("compact", .9), ("standard", 1.125), ("large", 1.35)):
                def length(value):
                    return math.floor(value * factor * 2 + .5) / 2
                bench("ui", "size", size)
                for layout in ("shelf", "no-shelf", "no-spaces", "no-spaces-no-bar", "folded", "folded-no-bar", "top"):
                    side = layout != "top"
                    folded = layout.startswith("folded")
                    spaces = not layout.startswith("no-spaces")
                    for key, on in (("sidebar", side), ("spaces", spaces),
                                    ("shelf", layout == "shelf"),
                                    ("bar", layout not in ("folded-no-bar", "no-spaces-no-bar")),
                                    ("folded", folded)):
                        bench("ui", key, "on" if on else "off")
                    bench("select", tabs[-1])
                    time.sleep(.7)  # Let the documented layout springs settle before hitting coordinates.
                    state = bench("probe")
                    frames = [entry["frame"] for entry in bench("panels")["entries"]]
                    if folded:
                        x = max(80, length(10) + length(72)) + length(26) + length(28) / 2
                        y = length(36) / 2
                    elif side:
                        x = max(frame[0] + frame[2] for frame in frames) - length(28) / 2
                        if spaces:
                            # Search stays beside the Space title, above the
                            # pins and scrolling rows, even at minimum width.
                            y = length(36) + length(32) / 2
                        else:
                            x = max(80, length(10) + length(72)) + length(28) / 2
                            y = length(36) / 2
                    else:
                        x = max(frame[0] + frame[2] for frame in frames) + length(30) + 2 * length(2) + length(28) / 2
                        y = length(36) / 2
                    name = f"{theme}/{size}/{layout}"
                    before = len(h.tabs())
                    bench("press", 40, "k", "cmd")
                    keyboard = bench("probe")
                    escape()
                    bench("hit", x, y, "click", "live")
                    click = bench("probe")
                    for key in ("summoning", "fieldShowing", "fieldFocused"):
                        h.require(f"{name}: {key}", click[key], True)
                    for key in ("offers", "offerDetails", "searchPrivate", "openingTab"):
                        h.require(f"{name}: same {key}", click[key], keyboard[key])
                    # A key from outside the process, as the physical keyboard of
                    # whoever uses this Mac meanwhile, must not reach the field.
                    # Tab is a shortcut here (GitHub search), taken before the
                    # field sees it; a letter only reaches the field.
                    bench("press", 48, "\t", "outside")
                    bench("press", 7, "x", "outside")
                    after = bench("probe")
                    h.require(f"{name}: outside keys ignored",
                              (after["summoning"], after["github"]["open"], after["typed"]), (True, False, ""))
                    h.require(f"{name}: same page frame",
                              all(abs(a - b) < .5 for a, b in zip(click["pageFrame"], state["pageFrame"])), True)
                    escape()
                    h.require(f"{name}: no tab created", len(h.tabs()), before)
                    h.require(f"{name}: same document", bench("eval", tabs[-1], "window.searchMarker")["value"], "kept")
                    # Typing must reach the already-focused field, and Return
                    # must select an existing page without creating one.
                    bench("hit", x, y, "click", "live")
                    bench("press", 0, "a", "cmd")
                    for char in "needle":
                        bench("press", 0, char)
                    h.require(f"{name}: actual typing", bench("probe")["typed"], "needle")
                    bench("press", 36, "\r")
                    h.until(name + ": selected result", lambda: next(t for t in h.tabs() if t["active"])["id"] == tabs[17])
                    h.require(f"{name}: selection creates no page", len(h.tabs()), before)
                    checked += 1
                    print(f"PASS: {name}", flush=True)
        ignored = bench("probe")["foreignKeys"]
        h.require("outside keys counted", ignored >= 4 * checked, True)
        print(f"PASS: {checked} layouts/themes/sizes; pointer = Cmd K, focus, real typing, selection, Escape, no new tab/reload,"
              f" {ignored} keys from outside the world ignored")


if __name__ == "__main__":
    main()
