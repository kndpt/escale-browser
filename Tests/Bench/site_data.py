#!/usr/bin/env python3
"""Reset one WebKit domain while another domain keeps its local state.

Run after ./build.sh debug. Two names for one loopback server give distinct
WebKit records and cookie jars. The test owns an isolated probe world and
checks cookies, localStorage and IndexedDB before and after the production
reset path. No outside network or personal browser data is involved.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread
import json
import os
import subprocess
import time


ROOT = Path(__file__).resolve().parents[2]
WORLD = "site-data-reset"


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"<!doctype html><title>Site data test</title><body>Site data test</body>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def run(*args, env=None):
    result = subprocess.run(args, cwd=ROOT, env=env, capture_output=True,
                            text=True, timeout=40)
    if result.returncode:
        raise AssertionError(f"{args}: {result.stdout} {result.stderr}")
    return result.stdout


def bench(*args):
    return json.loads(run(str(ROOT / "bench"), "--world", WORLD, "--json", *args))


def until(label, predicate):
    end = time.monotonic() + 15
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(0.15)
    raise AssertionError(f"timed out: {label}")


def state(tab):
    # The asynchronous database listing writes to the DOM, so bench eval can
    # observe a settled value without trying to serialise a JS Promise.
    bench("eval", tab, "indexedDB.databases().then(xs => document.body.dataset.dbs = JSON.stringify(xs.map(x => x.name))); 'checking'")
    until("database listing", lambda: bool(bench("eval", tab, "document.body.dataset.dbs")["value"]))
    return bench("eval", tab, "JSON.stringify({cookie:document.cookie, local:localStorage.getItem('site-data-test'), dbs:document.body.dataset.dbs})")["value"]


def seed(tab, marker):
    bench("eval", tab, f"document.cookie='site-data-test={marker}; Path=/'; localStorage.setItem('site-data-test','{marker}'); "
                      f"var req=indexedDB.open('site-data-{marker}',1); "
                      "req.onupgradeneeded=()=>req.result.createObjectStore('items'); "
                      "req.onsuccess=()=>{req.result.close();document.body.dataset.seed='ready'}; 'armed'")
    until(f"seed {marker}", lambda: bench("eval", tab, "document.body.dataset.seed")["value"] == "ready")
    found = state(tab)
    assert marker in found, (marker, found)


def main():
    assert (ROOT / "build/Escale.app").exists(), "run ./build.sh debug first"
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    Thread(target=server.serve_forever, daemon=True).start()
    env = dict(os.environ, ESCALE_PROBE=WORLD)
    try:
        run("./fresh.sh", "wipe", env=env)
        run("defaults", "write", f"com.kndpt.escale.test.{WORLD}", "bench", "-bool", "YES")
        run("./fresh.sh", "again", env=env)
        target = bench("open", f"http://127.0.0.1:{server.server_port}/")
        other = bench("open", f"http://localhost:{server.server_port}/")
        target, other = target["id"], other["id"]
        for tab in (target, other):
            loaded = bench("wait", tab, "20")
            assert loaded.get("loading") is False and not loaded.get("failure"), loaded
        seed(target, "target")
        seed(other, "other")
        scope = bench("site-data", target)
        assert scope["host"] == "127.0.0.1" and scope["domains"] == ["127.0.0.1"], scope
        assert any("Cookies" in ",".join(r["types"]) for r in scope["records"]), scope
        cleared = bench("site-data", target, "clear")
        assert cleared["cleared"] and cleared["domains"] == ["127.0.0.1"], cleared
        bench("wait", target, "20")
        after = state(target)
        assert "target" not in after, after
        assert "other" in state(other), state(other)
        # A new load, rather than only the already-open document, sees the
        # deletion. The other domain remains intact after its own reload.
        bench("go", other, f"http://localhost:{server.server_port}/")
        bench("wait", other, "20")
        assert "other" in state(other), state(other)
        # A tab closed behind the confirmation is neither cleared nor
        # reloaded: its reload would build a page no tab owns.
        closed = bench("site-data", other, "closed")
        assert closed["cleared"] is False and closed["page"] is False, closed
        print("site data: target cookie/localStorage/IndexedDB removed; other domain retained; closed tab left alone")
    finally:
        server.shutdown()
        run("./fresh.sh", "wipe", env=env)


if __name__ == "__main__":
    main()
