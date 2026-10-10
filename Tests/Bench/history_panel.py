#!/usr/bin/env python3
"""The History panel over a full history.

Opening History → Show History… took two seconds with a history at its bound:
the panel built every one of its lines. This seeds a synthetic history.json in
an isolated world before launch, then opens the panel as the menu does
(`bench recall`), each time until the window has rested three times in a row:
the first opening after launch, then ROUNDS more with the panel closed in
between, and a search typed into it and cleared. Every step must leave the
panel in the state asked for.

The history is synthetic: PLACES places (default 2,000, the bound), a front
door for each of 200 sites under example.test and a titled page for the rest,
one every twenty minutes back from now, so 1,800 lines over 25 days. Nothing
under example.test has an icon on disk, so every line built asks for one and
finds none: the icon read is in the times as a missing file.

Then the keyboard, through real key presses on the panel (`bench press`):
three pages on a loopback fixture are searched for; ↑ and ↓ move the selection within them, Return opens one in the tab on
screen, ⌘Return in a new tab, ⌫ in the field removes a letter until the
arrows have moved and the line after that, and Escape closes the panel.
Which line a key chose is read from the page it opens.

The median settled opening must stay under 500 ms. That is a guard against the
whole list being built again (about 2,000 ms on an M1, release build), not
a budget: the lazy list settles in about 15 ms there. The times are printed for
a before/after; a comparison uses a release build (./build.sh) on an idle Mac.
Run after ./build.sh debug or ./build.sh; the shared runner owns a unique world,
its diagnostics and cleanup.
"""

import json
import os
import statistics
import time
from http.server import ThreadingHTTPServer
from threading import Thread
import suite as harness

ROUNDS = int(os.environ.get("ROUNDS", "10"))
PLACES = int(os.environ.get("PLACES", "2000"))
SITES = 200
GUARD_MS = 500
FOLDER = harness.SOCKET.parent
# Foundation's JSONEncoder writes a Date as seconds since 1 January 2001.
EPOCH_2001 = 978_307_200
# The pages the keyboard walks, newest first, in place of three synthetic ones.
KEYS = ["keys-a", "keys-b", "keys-c"]
DOWN, UP, RETURN, DELETE, ESCAPE = ("125", "\uf701"), ("126", "\uf700"), ("36", "\r"), ("51", "\x7f"), ("53", "\x1b")


def bench(*args):
    answer = json.loads(harness.command(str(harness.ROOT / "bench"), "--world", harness.WORLD,
                                        "--json", *args, seconds=60))
    if "error" in answer:
        raise AssertionError(f"{' '.join(args)}: {answer['error']}")
    return answer


def seed(base):
    """history.json as the app writes it, before first launch. Returns how
    many lines the panel lists: the pages, not the front doors."""
    now = time.time() - EPOCH_2001
    doors = min(SITES, PLACES)
    places = [
        {"url": f"https://site{i}.example.test/", "key": f"site{i}.example.test",
         "title": "", "count": 3, "last": now - 60 * i}
        for i in range(doors)
    ]
    places += [
        {"url": f"https://site{i % SITES}.example.test/page/{i}",
         "key": f"site{i % SITES}.example.test/page/{i}",
         "title": f"Synthetic page {i}", "count": 1, "last": now - 1_200 * i}
        for i in range(PLACES - doors - len(KEYS))
    ]
    places += [
        {"url": f"{base}/{name}", "key": f"127.0.0.1/{name}", "title": name,
         "count": 1, "last": now - 1 - i}
        for i, name in enumerate(KEYS)
    ]
    FOLDER.mkdir(parents=True, exist_ok=True)
    (FOLDER / "history.json").write_text(json.dumps(places))
    return PLACES - doors


def recall(*args, showing):
    answer = bench("recall", *args)
    harness.require(f"recall {' '.join(args)} answer", answer.get("open"), showing)
    harness.require(f"History panel after recall {' '.join(args)}", bench("probe").get("history"), showing)
    return answer


def press(*key, mods=()):
    bench("press", *key, *mods)


def history_count():
    return bench("space")["history"]


def opened(name, tabs):
    """The page a key opened is the one on screen, with `tabs` tabs open and
    the panel closed."""
    def shown():
        active = next(t for t in harness.tabs() if t["active"])
        return active["url"].endswith("/" + name) and not active["loading"]
    harness.until(f"{name} on screen", shown, 15)
    harness.require(f"tabs after opening {name}", len(harness.tabs()), tabs)
    harness.require(f"History panel after opening {name}", bench("probe").get("history"), False)


def keyboard():
    """Arrows, Return, ⌘Return, ⌫ and Escape in a search for the loopback pages."""
    recall("open", showing=True)
    recall("hunt", "keys-", showing=True)
    tabs = len(harness.tabs())
    # a, b, c: the selection starts at the top, ↓ takes b.
    press(*DOWN)
    press(*RETURN)
    opened("keys-b", tabs)

    # b, a, c now. Past the bottom and back: c, then a.
    recall("open", showing=True)
    recall("hunt", "keys-", showing=True)
    for key in (DOWN, DOWN, DOWN, UP):
        press(*key)
    press(*RETURN, mods=("cmd",))
    opened("keys-a", tabs + 1)

    # a, b, c. ⌫ before any arrow is the field's: no line goes.
    recall("open", showing=True)
    recall("hunt", "keys-", showing=True)
    before = history_count()
    press(*DELETE)
    harness.require("lines after ⌫ in the field", history_count(), before)
    # The search changed (keys-), so the selection is back at a; ↓ takes b,
    # ⌫ removes it and passes the selection on to c.
    recall("hunt", "keys-", showing=True)
    press(*UP)
    press(*DOWN)
    press(*DELETE)
    harness.until("b forgotten", lambda: history_count() == before - 1, 10)
    press(*RETURN)
    opened("keys-c", tabs + 1)

    recall("open", showing=True)
    press(*ESCAPE)
    harness.until("Escape closes History", lambda: bench("probe").get("history") is False, 10)


def summary(name, samples):
    first = [ms[0] for ms in samples]
    settled = [ms[-1] for ms in samples]
    return (f"{name}: n={len(samples)} first_rest_ms median={statistics.median(first):.1f} "
            f"max={max(first):.1f}; settled_ms median={statistics.median(settled):.1f} "
            f"max={max(settled):.1f}")


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), harness.Page)
    Thread(target=server.serve_forever, daemon=True).start()
    with harness.world(server):
        lines = seed(f"http://127.0.0.1:{server.server_port}")
        harness.launch()
        # A beat for launch to finish before anything is timed.
        time.sleep(2)

        first = recall("open", showing=True)["ms"]
        closes = [recall("close", showing=False)["ms"]]
        opens = []
        for _ in range(ROUNDS):
            opens.append(recall("open", showing=True)["ms"])
            closes.append(recall("close", showing=False)["ms"])

        recall("open", showing=True)
        hunts = [recall("hunt", "page/1", showing=True), recall("hunt", showing=True)]
        harness.require("search applied then cleared", [h.get("hunt") for h in hunts], ["page/1", ""])
        recall("close", showing=False)

        keyboard()

        settled = statistics.median(ms[-1] for ms in opens)
        if settled >= GUARD_MS:
            raise AssertionError(f"median settled opening {settled:.1f} ms over {lines} lines, "
                                 f"expected under {GUARD_MS} ms: is the whole list built again?")
        print(f"ok: {PLACES} seeded places, {lines} listed; panel opened, closed and searched as asked")
        print("ok: ↑ ↓ held in bounds, Return, ⌘Return, ⌫ (field first, then the line) and Escape")
        print(summary("first open", [first]))
        print(summary("open", opens))
        print(summary("close", closes))
        print(summary("search", [h["ms"] for h in hunts]))
        print("open_ms=" + json.dumps([[round(t, 2) for t in ms] for ms in [first] + opens]))


if __name__ == "__main__":
    main()
