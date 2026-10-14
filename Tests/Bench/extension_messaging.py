#!/usr/bin/env python3
"""Chrome's extension messaging, as an extension relies on it, on WebKit.

WebKit's messaging differs from Chrome's, and shim.js mends it: several
listeners and the one that answers, async and promised answers, a reply that
never comes, a page that listens without answering, ports, messages to a
tab's content script and to the extension's page framed in a website. A
local fixture (fixtures/messaging-extension) exercises each path from the
outside, so the shim can be reorganised without breaking 1Password or
Bitwarden unnoticed. No store extension or personal profile is used.

Where Escale doesn't keep Chrome's contract yet, `gap` names both answers:
Chrome's passes as fixed, today's passes as a known gap, anything else fails.
"""
from http.server import ThreadingHTTPServer
from pathlib import Path
import json
import shutil
import tempfile
import threading
import suite as h

ROOT = Path(__file__).resolve().parents[2]
NAME = "Escale messaging fixture"


def obj(*args):
    return json.loads(h.command(str(ROOT / "bench"), "--world", h.WORLD, "--json", *args, seconds=35))


def js(page, script):
    return obj("eval", page, script)["value"]


def installed():
    return next((row for row in obj("extensions")["extensions"] if row["name"] == NAME), None)


def settle(page, script, label, seconds=15):
    """Run an expression that yields a promise; return what it settled to."""
    js(page, "window.escaleResult = undefined; Promise.resolve().then(() => " + script + ")"
       ".then(v => window.escaleResult = {value: v === undefined ? '(undefined)' : v},"
       " e => window.escaleResult = {error: String(e && e.message || e)}); 0")
    return h.until(label, lambda: js(page, "window.escaleResult ?? null"), seconds)


def send(page, message, label):
    return settle(page, f"chrome.runtime.sendMessage({json.dumps(message)})", label)


def send_callback(page, message, label):
    """The callback form, which reports a missing answer through lastError."""
    return settle(page, "new Promise(r => chrome.runtime.sendMessage(" + json.dumps(message) + ", v =>"
                  " r({reply: v ?? null, lastError: chrome.runtime.lastError ? chrome.runtime.lastError.message : null})))",
                  label)


GAPS = []


def gap(what, actual, chrome, today):
    if actual == chrome:
        print(f"fixed: {what}")
    elif actual == today:
        GAPS.append(what)
    else:
        raise AssertionError(f"{what}: expected Chrome's {chrome!r} or today's {today!r}, got {actual!r}")


def extension_page(ident, path):
    page = obj("ext-page", ident, path)["id"]
    h.until(f"{path} ready", lambda: js(page, "document.readyState === 'complete'"
                                              " && typeof globalThis.chrome?.runtime?.sendMessage === 'function'"))
    return page


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), h.Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    with tempfile.TemporaryDirectory(prefix="escale-messaging-") as temp, h.world(server):
        folder = Path(temp) / "messaging"
        shutil.copytree(ROOT / "Tests/Bench/fixtures/messaging-extension", folder)
        h.launch()
        obj("ext-folder", str(folder), "--yes")
        row = h.until("fixture loaded", lambda: (r if (r := installed()) and r["loaded"] else None), 30)
        h.require("extension errors", row["errors"], [])
        page = extension_page(row["id"], "page.html")

        # Worker answers: the second listener answers although the first
        # returns nothing, synchronously, later, or through a promise.
        h.require("sync answer past a silent first listener",
                  send(page, {"kind": "sync", "echo": 1}, "sync"), {"value": {"from": "worker", "echo": 1}})
        h.require("async answer (return true)", send(page, {"kind": "async"}, "async"),
                  {"value": {"from": "worker", "late": True}})
        h.require("promised answer", send(page, {"kind": "promise"}, "promise"),
                  {"value": {"from": "worker", "promised": True}})
        # Nobody answers: a promise settles empty, a callback hears lastError.
        h.require("unanswered promise", send(page, {"kind": "silent"}, "silent"), {"value": "(undefined)"})
        h.require("unanswered callback", send_callback(page, {"kind": "silent"}, "silent callback"),
                  {"value": {"reply": None, "lastError": "The message port closed before a response was received."}})

        # A page that listens without answering doesn't stand in for the
        # worker, nor hold its answer up; and a page can answer another.
        quiet = extension_page(row["id"], "quiet.html")
        timed = settle(page, "(async () => { const t = performance.now();"
                             " const r = await chrome.runtime.sendMessage({kind: 'sync', echo: 2});"
                             " return {r, ms: performance.now() - t}; })()", "sync beside a quiet page")
        h.require("worker's answer beside a quiet page", timed["value"]["r"], {"from": "worker", "echo": 2})
        assert timed["value"]["ms"] < 3000, f"the quiet page held the answer up: {timed}"
        h.require("a page answers another", send(page, {"kind": "page"}, "page to page"),
                  {"value": {"from": "quiet page"}})

        # Ports: messages echoed in order, then the worker hears the end.
        h.require("port round trip", settle(page, "new Promise(done => {"
                  " const port = chrome.runtime.connect({name: 'echo'}); const got = [];"
                  " port.onMessage.addListener(m => { got.push(m); if (got.length === 2) { port.disconnect(); done(got); } });"
                  " port.postMessage('a'); port.postMessage('b'); })", "port"),
                  {"value": [{"echo": "a", "n": 1}, {"echo": "b", "n": 2}]})
        h.until("worker hears the port close",
                lambda: "disconnected echo" in (send(page, {"kind": "ports"}, "ports").get("value") or []))

        # A website with the content script: it reaches the worker as its tab,
        # and the worker reaches it back.
        site = h.open_ordinary(f"{base}/messaging")
        h.until("content script ready", lambda: js(site, "document.documentElement.dataset.content === 'ready'"))
        js(site, "delete document.documentElement.dataset.reply;"
                 " window.postMessage({escaleAsk: {kind: 'sender'}}, '*'); 0")
        sender = json.loads(h.until("content script's message answered",
                                    lambda: js(site, "document.documentElement.dataset.reply ?? null")))["reply"]
        assert isinstance(sender["tab"], int) and sender["tab"] >= 0, sender
        h.require("sender url", sender["url"], f"{base}/messaging")
        h.require("sender frame", sender["frameId"], 0)
        tab_id = sender["tab"]
        h.require("worker to content script",
                  send(page, {"kind": "toTab", "tabId": tab_id, "inner": {"kind": "tabPing"}}, "to tab"),
                  {"value": {"reply": {"from": "content", "href": f"{base}/messaging"}}})

        # A tab with nobody listening answers at once rather than never. The
        # promise settles empty where Chrome rejects: WebKit answers the same
        # nothing when a listener stays silent, and a script injected through
        # `scripting` carries no shim to tell them apart. (Match patterns
        # carry no port, so the tab is found by its address.)
        h.open_ordinary(f"{base}/bare")
        bare = settle(page, f"chrome.tabs.query({{}}).then(t => t.filter(x => x.url === '{base}/bare').map(x => x.id))",
                      "bare tab id")["value"]
        h.require("one bare tab", len(bare), 1)
        none = "Could not establish connection. Receiving end does not exist."
        gap("no receiver, promise", send(page, {"kind": "toTab", "tabId": bare[0], "inner": {"kind": "tabPing"}}, "no receiver"),
            {"value": {"error": none}}, {"value": {"reply": None}})
        h.require("no receiver, callback", send(page, {"kind": "toTabCallback", "tabId": bare[0], "inner": {"kind": "tabPing"}},
                                                "no receiver callback"),
                  {"value": {"reply": None, "lastError": none}})

        # The extension's page framed in the website: its privileged call goes
        # through, the website's process lives on, and the worker's tab
        # message reaches the frame as well as the content script.
        own = settle(page, "chrome.runtime.getURL('frame.html')", "frame url")["value"]
        js(site, "window.escaleAlive = true; window.addEventListener('message', e => { if (e.data && e.data.escaleFrame)"
                 " document.documentElement.dataset.frame = JSON.stringify(e.data.escaleFrame); });"
                 f" const f = document.createElement('iframe'); f.src = {json.dumps(own)}; document.body.append(f); 0")
        framed = json.loads(h.until("framed page's tabs.query answered",
                                    lambda: js(site, "document.documentElement.dataset.frame ?? null")))
        assert framed.get("tabs", 0) >= 2, f"framed page's privileged call: {framed}"
        h.require("website process survives the framed page", js(site, "window.escaleAlive === true"), True)
        h.require("worker to framed page",
                  send(page, {"kind": "toTab", "tabId": tab_id, "inner": {"kind": "frameCheck"}}, "to frame"),
                  {"value": {"reply": {"from": "frame"}}})

        for ident in (page, quiet):
            obj("close", ident)
        obj("ext-remove", row["id"])
        print("PASS: listeners and answers (sync, async, promise, none), quiet page, page to page, ports,"
              " content script both ways, no receiver, framed extension page")
        for what in GAPS:
            print(f"known gap: {what}")


if __name__ == "__main__":
    main()
