#!/usr/bin/env python3
"""JSON fidelity and targeted storage in a disposable, local WebKit world.

Uses production feature actions, asserts absence of a second JSON request,
checks stale editors, duplicate cookie names, origins and navigation teardown.
Set ESCALE_KEEP_TOOLS=1 only for manual UI follow-up in this owned world.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread
import json
import os
import socket
import subprocess
import time
import tempfile

ROOT = Path(__file__).resolve().parents[2]
WORLD = "page-data-89-90"
REQUESTS = []


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        REQUESTS.append(self.path)
        if self.path == "/sample.json":
            body = '{"number":9007199254740993123456789,"a/b~":["é🌍",true,null],"duplicate":1,"duplicate":2}'
            mime = "application/json"
        elif self.path == "/auth.json":
            body, mime = ('{"authenticated":true}', "application/json") if "auth=ok" in self.headers.get("Cookie", "") else ("sign in", "text/html")
        elif self.path == "/looks-json":
            body, mime = '{"html":true}', "text/html"
        elif self.path == "/bad.json":
            body, mime = '{"missing":}', "application/json"
        elif self.path == "/large.json":
            body, mime = json.dumps(list(range(19990))), "application/json"
        elif self.path == "/too-large.json":
            body, mime = '"' + 'x' * 2097153 + '"', "application/json"
        elif self.path == "/scalar.json":
            body, mime = "1.2300e+99", "application/json"
        else:
            body, mime = '<!doctype html><title>Page data fixture</title><h1>Page data</h1><a href="/sample.json">JSON response</a><textarea></textarea>', "text/html"
        encoded = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", mime + "; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, *_):
        pass


def run(*args, env=None):
    p = subprocess.run(args, cwd=ROOT, env=env, capture_output=True, text=True, timeout=60)
    assert p.returncode == 0, (args, p.stdout, p.stderr)
    return p.stdout


def ask(verb, **fields):
    path = Path.home() / "Library/Application Support" / f"Escale ({WORLD})/bench.sock"
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(20)
        connection.connect(str(path))
        connection.sendall((json.dumps({"do": verb, **fields}) + "\n").encode())
        raw = b""
        while chunk := connection.recv(65536):
            raw += chunk
    reply = json.loads(raw.split(b"\n")[0])
    assert "error" not in reply, reply
    return reply


def until(label, fn):
    end = time.monotonic() + 20
    while time.monotonic() < end:
        result = fn()
        if result:
            return result
        time.sleep(.05)
    raise AssertionError(label)


def load(tab, url):
    ask("go", id=tab, url=url)
    result = ask("wait", id=tab, seconds=15)
    assert not result.get("failure") and not result.get("loading") and not result.get("timeout"), result


def settled(tab):
    return until("storage settled", lambda: (s if not s["busy"] else None) if (s := ask("site-storage", id=tab)) else None)


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    Thread(target=server.serve_forever, daemon=True).start()
    env = dict(os.environ, ESCALE_PROBE=WORLD)
    base = f"http://127.0.0.1:{server.server_port}"
    try:
        run("./fresh.sh", "wipe", env=env)
        run("defaults", "write", f"com.kndpt.escale.test.{WORLD}", "bench", "-bool", "YES")
        run("./fresh.sh", "again", env=env)
        ask("ui", welcome=False)
        tab = ask("open", url=base + "/sample.json")["id"]
        ask("select", id=tab)
        ask("wait", id=tab, seconds=15)
        state = ask("json-reader", id=tab)
        assert state["available"] and not state["shown"], state
        before = REQUESTS.count("/sample.json")
        ask("json-reader", id=tab, action="open")
        state = until("JSON parsed", lambda: (s if s["count"] or s["failure"] else None) if (s := ask("json-reader", id=tab)) else None)
        assert state["count"] == 8 and not state["failure"], state
        assert ask("json-reader", id=tab, node=1)["value"] == "9007199254740993123456789"
        assert ask("json-reader", id=tab, node=3)["path"] == "/a~1b~0/0"
        assert REQUESTS.count("/sample.json") == before
        ask("json-reader", id=tab, query="duplicate")
        assert ask("json-reader", id=tab)["visible"] == 2
        ask("json-reader", id=tab, action="raw")
        assert ask("json-reader", id=tab)["count"] == 0
        for path, valid in [("/scalar.json", True), ("/bad.json", False), ("/too-large.json", False), ("/large.json", True)]:
            load(tab, base + path)
            ask("json-reader", id=tab, action="open")
            state = until(path, lambda: (s if s["count"] or s["failure"] else None) if (s := ask("json-reader", id=tab)) else None)
            assert bool(state["count"]) == valid, state
        load(tab, base + "/looks-json")
        assert not ask("json-reader", id=tab)["available"]
        with tempfile.TemporaryDirectory(prefix="escale-json-") as folder:
            fixture = Path(folder) / "fixture.json"
            fixture.write_text('{"local":9007199254740993}')
            load(tab, fixture.as_uri())
            ask("json-reader", id=tab, action="open")
            until("local JSON", lambda: ask("json-reader", id=tab)["count"])
            assert ask("json-reader", id=tab, node=1)["value"] == "9007199254740993"
        load(tab, base + "/")
        ask("eval", id=tab, js="document.cookie='auth=ok; Path=/'; 'authenticated'")
        load(tab, base + "/auth.json")
        ask("json-reader", id=tab, action="open")
        until("authenticated JSON", lambda: ask("json-reader", id=tab)["count"])
        assert REQUESTS.count("/auth.json") == 1
        load(tab, base + "/")
        ask("eval", id=tab, js="document.cookie='auth=; Path=/; Max-Age=0'; 'cleared'")
        assert not ask("json-reader", id=tab)["available"]
        ask("eval", id=tab, js="document.cookie='same=root; Path=/'; document.cookie='same=other; Path=/other'; localStorage.setItem('keep','untouched'); localStorage.setItem('edit','old'); 'seeded'")
        ask("site-storage", id=tab, action="open")
        state = settled(tab)
        assert not state["failure"] and len(state["cookies"]) == 2 and len(state["local"]) == 2, state
        other_path = next(x for x in state["cookies"] if '/other' in x["scope"])
        ask("site-storage", id=tab, action="save", cookie=True, entry=other_path["id"], value="changed")
        state = settled(tab)
        assert not state["failure"], state
        assert sorted(x["value"] for x in state["cookies"]) == ["changed", "root"]
        ask("site-storage", id=tab, action="save", entry="edit", value="new")
        state = settled(tab)
        assert not state["failure"], state
        assert {x["key"]: x["value"] for x in state["local"]} == {"keep": "untouched", "edit": "new"}
        ask("eval", id=tab, js="localStorage.setItem('edit','page changed'); 'changed'")
        ask("site-storage", id=tab, action="save", entry="edit", value="must not overwrite")
        state = settled(tab)
        assert "changed" in state["failure"], state
        ask("site-storage", id=tab, action="refresh")
        state = settled(tab)
        assert next(x for x in state["local"] if x["key"] == "edit")["value"] == "page changed"
        other = ask("open", url=f"http://localhost:{server.server_port}/")["id"]
        ask("wait", id=other, seconds=15)
        ask("site-storage", id=other, action="open")
        state = settled(other)
        assert not state["cookies"] and not state["local"], state
        ask("site-storage", id=other, action="close")
        ask("select", id=tab)
        ask("site-storage", id=tab, action="delete", entry="edit")
        until("delete confirmation", lambda: any(w["visible"] and w["kind"] == "_NSAlertPanel" for w in ask("probe")["windows"]))
        ask("press", code=53, chars="\x1b")
        until("cancelled confirmation", lambda: not any(w["visible"] and w["kind"] == "_NSAlertPanel" for w in ask("probe")["windows"]))
        assert len(settled(tab)["local"]) == 2
        ask("space", action="new", name="Other project")
        assert not ask("site-storage", id=tab)["shown"]
        new = ask("open", url=base + "/")["id"]
        ask("wait", id=new, seconds=15)
        ask("site-storage", id=new, action="open")
        state = settled(new)
        assert not state["cookies"] and not state["local"], state
        ask("site-storage", id=new, action="close")
        ask("space", action="go", index=1)
        ask("select", id=tab)
        ask("site-storage", id=tab, action="open")
        settled(tab)
        load(tab, base + "/sample.json")
        assert not ask("site-storage", id=tab)["shown"]
        ask("json-reader", id=tab, action="open")
        load(tab, base + "/")
        assert not ask("json-reader", id=tab)["shown"]
        # New Tab search creates the private tab only once a destination is confirmed.
        ask("press", code=45, chars="n", mods=["cmd", "shift"])
        ask("field", text=base + "/", type=False, go=True)
        private = until("private tab", lambda: next((t for t in ask("tabs")["tabs"] if t["active"] and t["shy"]), None))["id"]
        ask("wait", id=private, seconds=15)
        ask("site-storage", id=private, action="open")
        state = settled(private)
        assert "Private tab" in state["context"] and not state["cookies"] and not state["local"], state
        ask("site-storage", id=private, action="save", key="private", value="only here")
        settled(private)
        ask("press", code=13, chars="w", mods=["cmd"])
        until("private tab closed", lambda: not any(t["id"] == private for t in ask("tabs")["tabs"]))
        ask("select", id=tab)
        ask("site-storage", id=tab, action="open")
        assert all(x["key"] != "private" for x in settled(tab)["local"])
        ask("site-storage", id=tab, action="close")
        print("PASS: JSON fidelity, scalar/invalid/large/bounds, no refetch, search, raw release; cookie path identity, local edits/stale conflicts, origin isolation and navigation cancellation")
    finally:
        if not os.environ.get("ESCALE_KEEP_TOOLS"):
            run("./fresh.sh", "wipe", env=env)
        server.shutdown()


if __name__ == "__main__":
    main()
