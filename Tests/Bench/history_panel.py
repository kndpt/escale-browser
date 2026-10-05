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
import suite as harness

ROUNDS = int(os.environ.get("ROUNDS", "10"))
PLACES = int(os.environ.get("PLACES", "2000"))
SITES = 200
GUARD_MS = 500
FOLDER = harness.SOCKET.parent
# Foundation's JSONEncoder writes a Date as seconds since 1 January 2001.
EPOCH_2001 = 978_307_200


def bench(*args):
    answer = json.loads(harness.command(str(harness.ROOT / "bench"), "--world", harness.WORLD,
                                        "--json", *args, seconds=60))
    if "error" in answer:
        raise AssertionError(f"{' '.join(args)}: {answer['error']}")
    return answer


def seed():
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
        for i in range(PLACES - doors)
    ]
    FOLDER.mkdir(parents=True, exist_ok=True)
    (FOLDER / "history.json").write_text(json.dumps(places))
    return PLACES - doors


def recall(*args, showing):
    answer = bench("recall", *args)
    harness.require(f"recall {' '.join(args)} answer", answer.get("open"), showing)
    harness.require(f"History panel after recall {' '.join(args)}", bench("probe").get("history"), showing)
    return answer


def summary(name, samples):
    first = [ms[0] for ms in samples]
    settled = [ms[-1] for ms in samples]
    return (f"{name}: n={len(samples)} first_rest_ms median={statistics.median(first):.1f} "
            f"max={max(first):.1f}; settled_ms median={statistics.median(settled):.1f} "
            f"max={max(settled):.1f}")


def main():
    with harness.world(None):
        lines = seed()
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

        settled = statistics.median(ms[-1] for ms in opens)
        if settled >= GUARD_MS:
            raise AssertionError(f"median settled opening {settled:.1f} ms over {lines} lines, "
                                 f"expected under {GUARD_MS} ms: is the whole list built again?")
        print(f"ok: {PLACES} seeded places, {lines} listed; panel opened, closed and searched as asked")
        print(summary("first open", [first]))
        print(summary("open", opens))
        print(summary("close", closes))
        print(summary("search", [h["ms"] for h in hunts]))
        print("open_ms=" + json.dumps([[round(t, 2) for t in ms] for ms in [first] + opens]))


if __name__ == "__main__":
    main()
