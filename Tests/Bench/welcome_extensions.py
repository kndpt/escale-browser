#!/usr/bin/env python3
"""Welcome's extensions step writes its answer as it is left.

A first arrival (`welcomed` off) with nothing installed asks how extensions
are kept. Continue on the first step, then on this one with its preselected
answer, stores the shared mode; the first Space's owner is made again for
it, and the tab made at launch with the old controller is made again, so
it carries the new one, and a pinned tab stays pinned. Return presses
Continue, the step's default action.
"""
from http.server import ThreadingHTTPServer
from pathlib import Path
import json
import subprocess
import threading
import time
import suite as h

ROOT = Path(__file__).resolve().parents[2]
FIRST = "00000000-0000-0000-0000-000000000001"


def obj(*args):
    return json.loads(h.command(str(ROOT / "bench"), "--world", h.WORLD, "--json", *args, seconds=35))


def stored():
    result = subprocess.run(["defaults", "read", h.SUITE, "extensions.shared"], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), h.Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    site = f"http://127.0.0.1:{server.server_address[1]}/pinned"
    with h.world(server):
        h.command("defaults", "write", h.SUITE, "welcomed", "-bool", "NO")
        h.launch()
        h.until("Welcome shown", lambda: obj("probe")["welcome"] is True)
        # Welcome can come back after browsing: a pinned page, made before the choice.
        pinned = h.open_ordinary(site)
        obj("pin", pinned)
        h.require("no mode before the step", stored(), None)
        h.require("per Space until chosen", obj("extensions")["shared"], False)
        before = {t["id"] for t in obj("tabs")["tabs"]}
        obj("press", "36", "\r")  # the first step's Continue
        time.sleep(1)
        h.require("nothing written by reaching the step", stored(), None)
        obj("press", "36", "\r")  # the extensions step's Continue
        h.until("mode written as the step is left", lambda: stored() == "1")
        state = obj("extensions")
        h.require("one owner for every Space", (state["shared"], state["owner"]), (True, FIRST))
        rows = h.until("tabs made again", lambda: (r if (r := obj("tabs")["tabs"]) and not ({t["id"] for t in r} & before) else None))
        h.require("tabs carry the chosen set", [t["extensionsCurrent"] for t in rows], [True] * len(rows))
        h.require("the pinned page made again, still pinned", [t["pin"] != "" for t in rows if t["url"] == site], [True])
        h.require("Welcome goes on", obj("probe")["welcome"], True)
        print("welcome extensions: PASS")


if __name__ == "__main__":
    main()
