#!/usr/bin/env python3
"""One set of extensions serves every Space; sites stay per Space.

With `extensions.shared` set in the test world, an extension installed in
the first Space runs in the second from the same owner: its button shows
there, and what one Space's page writes to `chrome.storage` the other reads,
with `onChanged` in both. A site cookie set in one Space's tab is absent in
the other's. Each Space is a window: `tabs.query({currentWindow: true})`
answers with the Space on screen's tabs, and switching Space closes none.
A popup opened in either Space is listed by `getContexts`. Installing asks
as joining every Space, a copy of a Space plans nothing to reinstall, and
deleting a Space, which empties its website store, leaves the extension
loaded with its storage and its pages' own. A private tab still gets no
extensions. A transfer file carries the set once: brought back here it
plans nothing, and into a browser per Space it plans the set in every
imported Space.
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
NAME = "Escale shared fixture"
PHRASE = "correct horse battery"


def obj(*args):
    return json.loads(h.command(str(ROOT / "bench"), "--world", h.WORLD, "--json", *args, seconds=35))


def current():
    state = obj("space")
    return next(s["id"] for s in state["spaces"] if s["name"] == state["current"])


def fixture():
    return next((r for r in obj("extensions")["extensions"] if r["name"] == NAME), None)


def page(ident, path):
    tab = obj("ext-page", ident, path)["id"]
    obj("wait", tab, "15")
    return tab


def run(tab, script):
    """A chrome.* call in an extension page, its answer as JSON."""
    obj("eval", tab, "window.__r = undefined; Promise.resolve().then(() => " + script + ")"
        ".then(v => window.__r = {value: v === undefined ? null : v}, e => window.__r = {error: String(e)}); 0")
    h.until(f"answer to {script}", lambda: obj("eval", tab, "JSON.stringify(window.__r || null)")["value"] != "null")
    result = json.loads(obj("eval", tab, "JSON.stringify(window.__r)")["value"])
    assert "error" not in result, (script, result)
    return result["value"]


def value(tab, script):
    return obj("eval", tab, script)["value"]


def listen(tab):
    value(tab, "window.__changed = []; window.__removed = 0;"
          " chrome.storage.onChanged.addListener(c => window.__changed.push(...Object.keys(c)));"
          " chrome.tabs.onRemoved.addListener(() => window.__removed++); 0")


def bring(file):
    """Opens and applies a transfer file: its summary and the Spaces made."""
    obj("transfer", "choose", str(file))
    h.until("file chosen", lambda: obj("transfer")["bringing"] == "locked")
    obj("transfer", "unlock", PHRASE)
    summary = h.until("file opened", lambda: (v["summary"] if (v := obj("transfer"))["bringing"] == "summary" else None), 40)
    obj("transfer", "apply")
    report = h.until("imported", lambda: (v["report"] if (v := obj("transfer"))["bringing"] == "finished" else None), 60)
    return summary, report["imported"]


def planned(name):
    return next(s["planned"] for s in reversed(obj("space")["spaces"]) if s["name"] == name)


def popup(ident):
    try:
        return obj("ext-popup", ident, "location.pathname")["value"]
    except AssertionError:
        return ""


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), h.Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    with tempfile.TemporaryDirectory(prefix="escale-shared-extensions-") as temp, h.world(server):
        h.command("defaults", "write", h.SUITE, "extensions.shared", "-bool", "YES")
        folder = Path(temp) / "fixture"
        shutil.copytree(ROOT / "Tests/Bench/fixtures/shared-extension", folder)
        h.launch()
        obj("space", "new", "B")
        second = h.until("second Space on screen", lambda: (s if (s := current()) != FIRST else None))
        obj("space", "go", "1")

        # Installed once, in the first Space, asked as joining every Space.
        obj("ext-answer", "yes")
        obj("ext-folder", str(folder))
        row = h.until("fixture loaded", lambda: (r if (r := fixture()) and r["loaded"] else None), 30)
        ident = row["id"]
        obj("ext-pin", ident, "on")
        state = obj("extensions")
        h.require("shared owner", (state["shared"], state["owner"]), (True, FIRST))
        h.require("asked as every Space's", f"Add “{NAME}”?" in obj("ext-answer", "yes")["asked"], True)
        a_page = page(ident, "page.html")
        listen(a_page)

        # The second Space has it too: the same owner and context, its button drawn.
        obj("space", "go", "2")
        h.until("second Space on screen again", lambda: current() == second)
        state = obj("extensions")
        h.require("owner in the second Space", state["owner"], FIRST)
        h.require("loaded in the second Space", (fixture()["loaded"], fixture()["base"]), (True, row["base"]))
        h.until("button in the second Space", lambda: ident in {a["id"] for a in obj("extensions")["bar"]}, 10)
        # page.html again: WebKit sends no storage events to the action's
        # popup page shown in a tab.
        b_page = page(ident, "page.html")
        listen(b_page)
        print("ok: installed in one Space, loaded and shown in the other")

        # One state: written from the first Space, read in the second.
        obj("space", "go", "1")
        run(a_page, "chrome.storage.local.set({who: 'A'})")
        h.require("read in the second Space", run(b_page, "chrome.storage.local.get('who').then(v => v.who)"), "A")
        for tab in (a_page, b_page):
            h.until("onChanged in both Spaces", lambda: value(tab, "window.__changed.includes('who')") is True)
        print("ok: chrome.storage written in one Space is read in the other")

        # Sites stay per Space.
        site_a = obj("open", f"{base}/a")["id"]
        h.loaded_page(site_a, "a", 15, "first Space's site")
        value(site_a, "document.cookie = 'space=A; max-age=600'; 0")
        h.require("cookie set", value(site_a, "document.cookie"), "space=A")
        obj("space", "go", "2")
        site_b = obj("open", f"{base}/b")["id"]
        h.loaded_page(site_b, "b", 15, "second Space's site")
        h.require("cookie of the first Space absent", value(site_b, "document.cookie"), "")
        print("ok: a site cookie stays in its Space")

        # Each Space is a window; the one on screen is current.
        windows = run(b_page, "chrome.windows.getAll().then(w => w.length)")
        h.require("a window per Space", windows, 2)
        shown = run(b_page, "chrome.tabs.query({currentWindow: true}).then(t => t.map(x => x.url))")
        h.require("current window holds the second Space's tabs", len(shown), len(obj("tabs")["tabs"]))
        assert f"{base}/b" in shown and f"{base}/a" not in shown, shown
        for tab in (a_page, b_page):
            h.require("no tab reported closed by Space switches", value(tab, "window.__removed"), 0)
        print("ok: tabs.query follows the Space on screen; switching closes nothing")

        # A popup opened in the second Space is listed from either.
        obj("ext-press", ident)
        h.until("popup open", lambda: popup(ident).endswith("/popup.html"))
        for tab in (b_page, a_page):
            contexts = run(tab, "chrome.runtime.getContexts({contextTypes: ['POPUP']}).then(c => c.length)")
            h.require("popup listed", contexts, 1)
        obj("ext-press", ident)
        print("ok: getContexts lists a popup from any Space")

        # A copy of a Space runs the same extensions: nothing to reinstall.
        copy = obj("space", "duplicate", "B Copy")
        h.require("duplicate plans nothing", next(s["planned"] for s in copy["spaces"] if s["name"] == "B Copy"), 0)

        # Deleting the second Space empties its store, not the extension's.
        value(b_page, "localStorage.setItem('kept', 'yes'); 0")
        obj("space", "delete")
        h.until("first Space after the delete", lambda: current() == FIRST)
        h.require("still loaded", fixture()["loaded"], True)
        h.require("storage kept", run(a_page, "chrome.storage.local.get('who').then(v => v.who)"), "A")
        h.require("its pages' storage kept", value(a_page, "localStorage.getItem('kept')"), "yes")
        h.require("one window left", run(a_page, "chrome.windows.getAll().then(w => w.length)"), 1)
        print("ok: deleting a Space leaves the extension and its storage")

        # A private tab follows extensions.private, off here.
        obj("press", "45", "n", "cmd", "shift")
        obj("field", f"{base}/private", "go")
        private = h.until("private tab", lambda: next((t for t in obj("tabs")["tabs"] if t["active"] and t["shy"]), None))
        h.require("private tab without extensions", private["extensions"], False)
        print("ok: a private tab follows extensions.private")

        # Transfer: the set is written once, and the receiving mode decides
        # the plan. Two files, as one file opened twice finds its Spaces.
        files = [Path(temp) / f"shared-{n}.escale" for n in (1, 2)]
        for file in files:
            obj("transfer", "save", str(file), PHRASE)
            h.until("file saved", lambda: obj("transfer")["saving"] == "saved")
        sources = len(obj("space")["spaces"])
        summary, imported = bring(files[0])
        h.require("set counted once", (summary["sharedExtensions"], {l["extensions"] for l in summary["lines"]}), (1, {0}))
        h.require("shared here: nothing to reinstall", [planned(name) for name in imported], [0] * sources)
        obj("press", "12", "q", "cmd")
        h.until("quit", lambda: not h.running(), 30)
        h.command("defaults", "write", h.SUITE, "extensions.shared", "-bool", "NO")
        h.launch()
        _, imported = bring(files[1])
        h.require("per Space here: the set planned in every imported Space", [planned(name) for name in imported], [1] * sources)
        print("shared extensions: PASS")


if __name__ == "__main__":
    main()
