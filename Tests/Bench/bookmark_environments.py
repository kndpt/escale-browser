#!/usr/bin/env python3
"""Explicit destinations survive editing, navigation, moves and Space copies.

A local HTTP fixture records requests; editing a shut bookmark must not load
it. The scenario owns one isolated world and uses production bookmark actions.
UI keyboard/cancellation and visual checks are recorded alongside the captures.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread

ROOT = Path(__file__).resolve().parents[2]
WORLD = "issue88-environments"
requests = []


def run(*args, env=None):
    result = subprocess.run([str(x) for x in args], cwd=ROOT, env=env,
                            text=True, capture_output=True, timeout=45)
    if result.returncode:
        raise AssertionError(f"{args}: {result.stdout} {result.stderr}")
    return result.stdout.strip()


def bench(*args):
    return json.loads(run(ROOT / "bench", "--world", WORLD, "--json", *args))


def entries(name="WebKit", *args):
    return bench("environments", name, *args)


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        requests.append(self.path)
        body = b"<title>Environment fixture</title><h1>Environment fixture</h1>"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    Thread(target=server.serve_forever, daemon=True).start()
    origin = f"http://127.0.0.1:{server.server_port}"
    # Path claims ride along with names and colours through every copy below.
    draft = [{"name": "Local", "url": origin + "/local?chosen=1#start", "colour": "blue", "depth": 1},
             {"name": "Recette", "url": origin + "/recette", "depth": 1}]
    saved = [dict(item, name=item["name"].upper(), colour=item.get("colour", "neutral")) for item in draft]
    env = dict(os.environ, ESCALE_PROBE=WORLD)
    run(ROOT / "fresh.sh", "wipe", env=env)
    try:
        run("defaults", "write", f"com.kndpt.escale.test.{WORLD}", "bench", "-bool", "YES")
        run(ROOT / "fresh.sh", "again", env=env)
        bench("ui", "welcome", "off")
        bench("ui", "sidebar", "on")
        bench("shelf", "seed")
        bench("bookmark", "data:text/html,<title>Ready</title>", "new")
        before = bench("space")["pages"]
        original = entries()
        configured = entries("WebKit", "set", json.dumps(draft))
        assert configured["entries"] == saved and not configured["built"]
        assert bench("space")["pages"] == before and not requests
        assert configured["original"] == original["original"]
        for invalid in [[{"name": "", "url": origin}], saved + [saved[0]],
                        [{"name": "Broken", "url": "not a URL"}]]:
            try:
                entries("WebKit", "set", json.dumps(invalid))
            except AssertionError as error:
                assert "invalid entries" in str(error)
            else:
                raise AssertionError("invalid entries were accepted")
            assert entries()["entries"] == saved

        first = entries("WebKit", "open", "LOCAL")
        bench("wait", first["tab"], "10")
        assert entries()["badge"] == "LOCAL"
        second = entries("WebKit", "open", "RECETTE")
        bench("wait", second["tab"], "10")
        assert second["tab"] == first["tab"]
        assert entries()["address"] == saved[1]["url"] and entries()["badge"] == "RECETTE"
        bench("field", origin + "/elsewhere?from=current#old", "go")
        assert entries()["badge"] == ""
        entries("WebKit", "open", "LOCAL")
        assert entries()["address"] == saved[0]["url"]
        assert entries()["original"] == original["original"]
        print("ok: editing builds no page; selection reuses the tab and opens the exact saved URL")

        # An environment that does not answer keeps its address and badge: the
        # tab does not fall back to the page it was showing.
        with socket.socket() as spare:
            spare.bind(("127.0.0.1", 0))
            down = {"name": "Down", "url": f"http://127.0.0.1:{spare.getsockname()[1]}/soon", "depth": 1}
        entries("WebKit", "set", json.dumps(draft + [down]))
        entries("WebKit", "open", "DOWN")
        for _ in range(40):
            state = entries()
            if state["address"] == down["url"] and state["badge"] == "DOWN":
                break
            time.sleep(0.25)
        assert state["address"] == down["url"] and state["badge"] == "DOWN", state
        time.sleep(1)
        assert entries()["address"] == down["url"] and entries()["badge"] == "DOWN"
        entries("WebKit", "open", "LOCAL")
        bench("wait", first["tab"], "10")
        assert entries()["address"] == saved[0]["url"]
        entries("WebKit", "set", json.dumps(draft))
        print("ok: an environment that does not answer keeps its address and badge")

        # A sleeping linked page remains asleep while its configuration changes.
        bench("wait", first["tab"], "10")
        bench("bookmark", "data:text/html,<title>Other</title>", "new")
        bench("sleep", first["tab"])
        assert not entries()["built"], entries()
        entries("WebKit", "set", json.dumps(saved))
        assert not entries()["built"]
        print("ok: editing a sleeping bookmark does not wake its page")

        bench("space", "duplicate", "Independent")
        bench("space", "go", "2")
        copy = entries()
        assert copy["entries"] == saved and copy["id"] != original["id"]
        assert not copy["built"]
        entries("WebKit", "set", "[]")
        assert entries()["entries"] == [] and entries()["original"] == original["original"]
        bench("space", "go", "1")
        assert entries()["entries"] == saved
        print("ok: Space copy is independent; removing the last association preserves the bookmark")

        # Close the linked page, then carry the saved row through a rail dwell.
        bench("select", first["tab"])
        bench("press", "13", "w", "cmd")
        bench("space", "new", "Moved")
        bench("space", "go", "1")
        result = bench("drag", "120", "123", "26", "140", "900", "120", "123", "500", "live")
        assert bench("space")["current"] == "Moved", result
        assert entries()["id"] == original["id"] and entries()["entries"] == saved
        bench("space", "go", "1")
        assert "WebKit" not in [row["title"] for row in bench("shelf")["rows"]]
        bench("space", "go", "3")
        bench("press", "12", "q", "cmd")
        run(ROOT / "fresh.sh", "again", env=env)
        assert entries()["entries"] == saved and entries()["id"] == original["id"]
        bench("space", "delete")
        bench("space", "go", "2")
        assert entries()["entries"] == []
        print("ok: bookmark move and restart preserve ownership; deleting its Space leaves the copy intact")
    finally:
        run(ROOT / "fresh.sh", "wipe", env=env)
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
