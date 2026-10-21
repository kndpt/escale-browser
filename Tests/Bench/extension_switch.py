#!/usr/bin/env python3
"""Switching how extensions are kept, after Welcome, deletes nothing.

Per Space, the first Space and a second each install their own extension and
write to its `chrome.storage`. Switched to one set for every Space and
launched again, the first Space's extension serves both Spaces with what it
stored, and the second's is listed there to reinstall. Switched back, the
second Space runs its own again, with what it stored, and lists the first's
to reinstall.
"""
from http.server import ThreadingHTTPServer
from pathlib import Path
import json
import shutil
import tempfile
import threading
import suite as h

ROOT = Path(__file__).resolve().parents[2]
FIRST = "00000000-0000-0000-0000-000000000001"
FIXTURE = ROOT / "Tests/Bench/fixtures/shared-extension"
NAMES = {"1": "Escale switch fixture one", "2": "Escale switch fixture two"}


def obj(*args):
    return json.loads(h.command(str(ROOT / "bench"), "--world", h.WORLD, "--json", *args, seconds=35))


def current():
    state = obj("space")
    return next(s["id"] for s in state["spaces"] if s["name"] == state["current"])


def go(index):
    obj("space", "go", index)
    h.until(f"Space {index} on screen", lambda: current() == obj("space")["spaces"][int(index) - 1]["id"])


def loaded(name):
    return h.until(f"{name} loaded", lambda: next((r for r in obj("extensions")["extensions"]
                                                   if r["name"] == name and r["loaded"]), None), 30)


def stored(ident):
    """What its own page reads back from chrome.storage.local."""
    tab = obj("ext-page", ident, "page.html")["id"]
    obj("wait", tab, "15")
    obj("eval", tab, "window.__r = null; chrome.storage.local.get('who').then(v => window.__r = v.who || ''); 0")
    return h.until("storage read", lambda: (v if (v := obj("eval", tab, "window.__r")["value"]) is not None else None))


def write(ident, who):
    tab = obj("ext-page", ident, "page.html")["id"]
    obj("wait", tab, "15")
    obj("eval", tab, f"chrome.storage.local.set({{who: '{who}'}}); 0")
    h.until("storage written", lambda: stored(ident) == who)


def planned():
    return [s["planned"] for s in obj("space")["spaces"]]


def relaunch():
    obj("press", "12", "q", "cmd")
    h.until("quit", lambda: not h.running(), 30)
    h.launch()


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), h.Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix="escale-extension-switch-") as temp, h.world(server):
        h.command("defaults", "write", h.SUITE, "extensions.shared", "-bool", "NO")
        folders = {}
        for index, name in NAMES.items():
            folder = Path(temp) / index
            shutil.copytree(FIXTURE, folder)
            manifest = json.loads((folder / "manifest.json").read_text())
            manifest["name"] = name
            (folder / "manifest.json").write_text(json.dumps(manifest))
            folders[index] = folder
        h.launch()
        obj("space", "new", "B")
        ids = {}
        for index in ("1", "2"):
            go(index)
            obj("ext-folder", str(folders[index]), "--yes")
            ids[index] = loaded(NAMES[index])["id"]
            write(ids[index], index)
        h.require("per Space: nothing to reinstall", planned(), [0, 0])
        print("ok: each Space has its own extension, with what it stored")

        h.require("shared stored", obj("ext-mode", "shared")["stored"], True)
        relaunch()
        go("1")
        state = obj("extensions")
        h.require("one owner", (state["shared"], state["owner"]), (True, FIRST))
        h.require("the first Space's set is the shared one", [r["name"] for r in state["extensions"]], [NAMES["1"]])
        h.require("its storage kept", stored(loaded(NAMES["1"])["id"]), "1")
        go("2")
        loaded(NAMES["1"])
        h.require("the second Space's own listed to reinstall", planned(), [0, 1])
        print("ok: shared, the first Space's extension serves both and the second's is listed")

        h.require("apart stored", obj("ext-mode", "apart")["stored"], True)
        relaunch()
        go("2")
        state = obj("extensions")
        h.require("its own owner again", (state["shared"], state["owner"] != FIRST), (False, True))
        h.require("the second Space's own set back", [r["name"] for r in state["extensions"]], [NAMES["2"]])
        h.require("its storage kept", stored(loaded(NAMES["2"])["id"]), "2")
        h.require("the first's listed to reinstall in the second", planned(), [0, 1])
        go("1")
        h.require("the first Space keeps its own", stored(loaded(NAMES["1"])["id"]), "1")
        print("extension switch: PASS")


if __name__ == "__main__":
    main()
