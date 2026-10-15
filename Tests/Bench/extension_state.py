#!/usr/bin/env python3
"""What an extension leaves behind goes with it.

An extension's keep-awake assertion and offscreen document belong to its
Space's owner (Extensions) and are let go when the extension unloads:
switched off, or removed. The assertion is read from macOS itself
(`pmset -g assertions`), not from Escale's own account of it. A copy of the
local messaging fixture is given the two permissions; no store extension is
used.
"""
from pathlib import Path
import json
import shutil
import subprocess
import tempfile
import suite as h

ROOT = Path(__file__).resolve().parents[2]
NAME = "Escale state fixture"
HOLDER = "An extension in Escale"


def obj(*args):
    return json.loads(h.command(str(ROOT / "bench"), "--world", h.WORLD, "--json", *args, seconds=35))


def js(page, script):
    return obj("eval", page, script)["value"]


def installed():
    return next((row for row in obj("extensions")["extensions"] if row["name"] == NAME), None)


def held():
    """Whether this world's Escale, by its process id, holds the assertion."""
    pids = subprocess.run(["pgrep", "-f", h.BINARY], capture_output=True, text=True, timeout=10).stdout.split()
    out = subprocess.run(["pmset", "-g", "assertions"], capture_output=True, text=True, timeout=10).stdout
    return any(HOLDER in line and any(f"pid {pid}(" in line for pid in pids) for line in out.splitlines())


def settle(page, script, label):
    js(page, "window.escaleResult = undefined; Promise.resolve().then(() => " + script + ")"
       ".then(v => window.escaleResult = {value: v === undefined ? '(undefined)' : v},"
       " e => window.escaleResult = {error: String(e && e.message || e)}); 0")
    return h.until(label, lambda: js(page, "window.escaleResult ?? null"))


def loaded_page():
    row = h.until("fixture loaded", lambda: (r if (r := installed()) and r["loaded"] else None), 30)
    page = obj("ext-page", row["id"], "page.html")["id"]
    h.until("page ready", lambda: js(page, "document.readyState === 'complete' && typeof globalThis.chrome?.power?.requestKeepAwake === 'function'"))
    return row["id"], page


def main():
    with tempfile.TemporaryDirectory(prefix="escale-state-") as temp, h.world(None):
        folder = Path(temp) / "state"
        shutil.copytree(ROOT / "Tests/Bench/fixtures/messaging-extension", folder)
        manifest = json.loads((folder / "manifest.json").read_text())
        manifest["name"] = NAME
        manifest["permissions"] = manifest["permissions"] + ["power", "offscreen"]
        (folder / "manifest.json").write_text(json.dumps(manifest))
        (folder / "offscreen.html").write_text("<!doctype html><title>offscreen</title>")
        h.launch()
        obj("ext-folder", str(folder), "--yes")
        ident, page = loaded_page()

        h.require("no assertion before", held(), False)
        settle(page, "chrome.power.requestKeepAwake('system')", "keep awake")
        h.until("assertion held", held)
        settle(page, "chrome.offscreen.createDocument({url: 'offscreen.html', reasons: ['DOM_PARSER'], justification: 'test'})",
               "offscreen created")
        h.require("offscreen there", settle(page, "chrome.offscreen.hasDocument()", "has document"), {"value": True})

        # Switched off: both go; switched on again, it starts with neither.
        obj("ext-enable", ident, "off")
        h.until("assertion released on unload", lambda: not held())
        obj("ext-enable", ident, "on")
        ident, page = loaded_page()
        h.require("offscreen gone after unload", settle(page, "chrome.offscreen.hasDocument()", "has document again"),
                  {"value": False})

        # Removed: the assertion it took again goes too.
        settle(page, "chrome.power.requestKeepAwake('display')", "keep awake again")
        h.until("assertion held again", held)
        obj("ext-remove", ident)
        h.until("assertion released on removal", lambda: not held())
        print("PASS: keep-awake and offscreen document let go on unload and removal")


if __name__ == "__main__":
    main()
