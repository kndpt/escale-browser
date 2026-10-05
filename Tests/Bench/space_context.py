#!/usr/bin/env python3
"""Space context: legacy attribution, isolation and organisation-only
duplication.

Run after ./build.sh debug. A unique test bundle and loopback site are used;
the world and synthetic keychain items are removed in finally. Assertions use
ordinary tabs for cookies, history and saved sessions. Extension API checks
use a copied local fixture outside Documents to avoid macOS TCC prompts.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import os
import shutil
import subprocess
import tempfile
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
WORLD = os.environ.get("ESCALE_WORLD", "issue40-context")
FOLDER = Path.home() / "Library/Application Support" / f"Escale ({WORLD})"
SUITE = f"com.kndpt.escale.test.{WORLD}"
FIRST = "00000000-0000-0000-0000-000000000001"


class Site(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        body = f"<title>{path}</title><p>{self.headers.get('Cookie', '')}</p>".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        if path in ("/a", "/b"):
            self.send_header("Set-Cookie", f"account={path[1:]}; Path=/")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def run(*args, timeout=20):
    done = subprocess.run([str(x) for x in args], cwd=ROOT, capture_output=True, text=True, timeout=timeout)
    if done.returncode:
        raise AssertionError(f"{args} exited {done.returncode}: {done.stderr.strip()}")
    return done.stdout.strip()


def bench(*args):
    return run(ROOT / "bench", "--world", WORLD, *args)


def obj(*args):
    return json.loads(bench("--json", *args))


def active():
    for row in bench("tabs").splitlines():
        if row.startswith("● "):
            return row.split()[1]
    raise AssertionError("no active ordinary tab")


def visit(url):
    obj("field", url, "go")
    tab = active()
    result = obj("wait", tab, "15")
    assert result.get("loading") is False and not result.get("timeout") and not result.get("failure"), result
    return tab


def cookie(tab):
    result = obj("eval", tab, "document.cookie")
    return result.get("value", result) if isinstance(result, dict) else result


def until(label, condition, seconds=20):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if condition():
            return
        time.sleep(0.2)
    raise AssertionError(f"timed out: {label}")


def extensions():
    return obj("extensions")["extensions"]


def fixture():
    return next((item for item in extensions() if item["name"] == "Escale shim fixture"), None)


def tree_titles(extension_id):
    page = obj("ext-page", extension_id, "page.html")["id"]
    obj("wait", page, "15")
    obj("eval", page, "window.__spaceTree = undefined; chrome.bookmarks.getTree()"
        ".then(v => window.__spaceTree = {value: v}, e => window.__spaceTree = {error: String(e)}); 0")
    until("bookmark tree", lambda: obj("eval", page, "JSON.stringify(window.__spaceTree || null)")["value"] != "null")
    result = json.loads(obj("eval", page, "JSON.stringify(window.__spaceTree)")["value"])
    assert "error" not in result, result
    return [child.get("title") for child in result["value"][0]["children"][0]["children"]]


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Site)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    with tempfile.TemporaryDirectory(prefix="escale-issue40-") as temp:
        copied_fixture = Path(temp) / "fixture"
        shutil.copytree(ROOT / "Tests/Bench/fixtures/shim-extension", copied_fixture)
        try:
            run("env", f"ESCALE_PROBE={WORLD}", ROOT / "fresh.sh", "wipe")
            FOLDER.mkdir(parents=True)
            other = str(uuid.uuid4()).upper()
            # The historical choice persisted a shared store. Its data now
            # belongs to the first space; the second remains independently named.
            (FOLDER / "spaces.json").write_text(json.dumps([
                {"id": FIRST, "name": "A", "colour": 0},
                {"id": other, "name": "B", "colour": 0, "sharesSignIns": True},
            ]))
            (FOLDER / "bookmarks.json").write_text(json.dumps([
                {"id": str(uuid.uuid4()).upper(), "title": "A only", "url": base + "/page"},
            ]))
            run("defaults", "write", SUITE, "bench", "-bool", "YES")
            run("defaults", "write", SUITE, "capture.127.0.0.1|0", "-bool", "YES")
            run("env", f"ESCALE_PROBE={WORLD}", ROOT / "fresh.sh", "again")
            until("bench", lambda: obj("space")["current"] == "A")

            a = visit(base + "/a")
            assert "account=a" in cookie(a), cookie(a)
            assert obj("space")["history"] > 0
            assert obj("space", "capture", "127.0.0.1", "0")["choice"] is True
            assert obj("space", "credentials", "alice")["users"] == ["alice"]
            obj("ext-folder", str(copied_fixture), "--yes")
            until("A extension", lambda: fixture() and fixture()["loaded"])
            assert "A only" in tree_titles(fixture()["id"])
            a_extension_page = obj("ext-page", fixture()["id"], "page.html")["id"]
            obj("wait", a_extension_page, "15")
            assert obj("eval", a_extension_page, "localStorage.setItem('space', 'A'); localStorage.getItem('space')")["value"] == "A"

            b = obj("space", "go", "2")
            assert b["history"] == 0 and b["current"] == "B", b
            assert obj("space", "credentials")["users"] == []
            assert obj("space", "capture", "127.0.0.1", "0")["choice"] is None
            assert obj("space", "capture", "127.0.0.1", "0", "deny")["choice"] is False
            assert extensions() == [], extensions()
            btab = visit(base + "/page")
            assert "account=a" not in cookie(btab), cookie(btab)
            btab = visit(base + "/b")
            assert "account=b" in cookie(btab), cookie(btab)
            second_login = obj("space", "credentials", "alice")
            assert second_login["saved"] and second_login["users"] == ["alice"], second_login
            different_account = obj("space", "credentials", "bob")
            assert different_account["saved"] and set(different_account["users"]) == {"alice", "bob"}, different_account
            obj("ext-folder", str(copied_fixture), "--yes")
            until("B extension", lambda: fixture() and fixture()["loaded"])
            assert "A only" not in tree_titles(fixture()["id"])
            b_extension_page = obj("ext-page", fixture()["id"], "page.html")["id"]
            obj("wait", b_extension_page, "15")
            assert obj("eval", b_extension_page, "localStorage.getItem('space')")["value"] is None

            obj("space", "go", "1")
            assert "account=a" in cookie(a), cookie(a)
            assert obj("space", "credentials")["users"] == ["alice"]
            assert obj("space", "capture", "127.0.0.1", "0")["choice"] is True
            before = obj("space")
            original_bookmarks = (FOLDER / "bookmarks.json").read_bytes()
            blocked = str(uuid.uuid4()).upper()
            (FOLDER / f"bookmarks-{blocked}.json").mkdir()
            failed = obj("space", "duplicate-id", blocked, "Incomplete")
            assert len(failed["spaces"]) == 2 and failed["current"] == "A", failed
            assert (FOLDER / "bookmarks.json").read_bytes() == original_bookmarks
            until("failed copy cleanup", lambda: not (FOLDER / f"session-{blocked}.json").exists())
            obj("space", "duplicate", "A Copy")
            copied = obj("space")
            assert copied["current"] == "A" and len(copied["spaces"]) == 3, copied
            destination = copied["spaces"][2]["id"]
            assert copied["spaces"][2]["planned"] == 1, copied
            assert len(copied["pages"]) == len(before["pages"]), (before, copied)
            shape = json.loads((FOLDER / f"session-{destination}.json").read_text())
            assert shape["tabs"] and all(entry["url"].startswith(base) for entry in shape["tabs"]), shape
            copied_bookmarks = json.loads((FOLDER / f"bookmarks-{destination}.json").read_text())
            assert [item["title"] for item in copied_bookmarks] == ["A only"]
            assert copied_bookmarks[0]["id"] != json.loads((FOLDER / "bookmarks.json").read_text())[0]["id"]
            assert not (FOLDER / f"history-{destination}.json").exists()
            assert not (FOLDER / f"downloads-{destination}.json").exists()
            assert extensions() and obj("space", "credentials")["users"] == ["alice"]

            copy_space = obj("space", "go", "3")
            assert copy_space["current"] == "A Copy" and copy_space["history"] == 0, copy_space
            assert obj("space", "credentials")["users"] == []
            assert extensions() == []
            copied_tab = active()
            obj("wait", copied_tab, "15")
            # /a sets its own cookie in the response. Its rendered body shows
            # what the first request sent, before that new cookie exists.
            first_request = obj("text", copied_tab)["text"]
            assert "account=a" not in first_request, first_request
            copied_history = obj("space")["history"]

            # The file identities and isolation survive an orderly restart.
            bench("press", "12", "q", "cmd")
            binary = str(ROOT / "build/probe" / WORLD / "Escale.app/Contents/MacOS/Escale")
            until("quit", lambda: binary not in run("ps", "-axo", "comm="), 30)
            run("env", f"ESCALE_PROBE={WORLD}", ROOT / "fresh.sh", "again")
            until("restart", lambda: obj("space")["current"] == "A Copy")
            assert obj("space")["history"] == copied_history, obj("space")
            assert obj("space", "credentials")["users"] == []
            assert obj("space", "go", "1")["history"] > 0
            assert obj("space", "credentials")["users"] == ["alice"]
            assert obj("space", "capture", "127.0.0.1", "0")["choice"] is True
            obj("space", "go", "2")
            assert obj("space", "capture", "127.0.0.1", "0")["choice"] is False
            assert obj("space", "capture", "127.0.0.1", "0", "clear")["choice"] is None
            obj("space", "go", "1")
            assert obj("space", "capture", "127.0.0.1", "0")["choice"] is True
            obj("space", "go", "3")
            obj("shelf", "seed")
            assert (FOLDER / "bookmarks.json").read_bytes() == original_bookmarks
            obj("space", "oauth", base + "/page")
            until("extension auth pending", lambda: obj("space")["pendingAuth"] == 1)
            deleted = obj("space", "delete")
            assert len(deleted["spaces"]) == 2 and deleted["current"] == "A", deleted
            assert deleted["pendingAuth"] == 0, deleted
            assert (FOLDER / "bookmarks.json").read_bytes() == original_bookmarks
            assert obj("space", "credentials")["users"] == ["alice"] and fixture()["loaded"]

            # The shim's action and side-panel overrides use the same Space
            # key on write and read. The fixture's manifest popup is popup.html.
            obj("space", "go", "2")
            parked_extension = obj("ext-page", fixture()["id"], "page.html")["id"]
            obj("wait", parked_extension, "15")
            obj("space", "go", "1")
            extension_id = fixture()["id"]
            page = obj("ext-page", extension_id, "page.html")["id"]
            obj("wait", page, "15")
            obj("eval", page, "window.__popupSet = false; chrome.action.setPopup({popup: 'page.html'})"
                ".then(() => window.__popupSet = true); 0")
            until("popup override", lambda: obj("eval", page, "window.__popupSet")["value"] is True)
            obj("ext-press", extension_id)
            def popup_path():
                try:
                    return obj("ext-popup", extension_id, "location.pathname")["value"]
                except AssertionError:
                    return ""
            until("action popup", lambda: popup_path().endswith("/page.html"))
            obj("eval", parked_extension,
                "window.__parkedContexts = undefined; chrome.runtime.getContexts({contextTypes: ['POPUP']})"
                ".then(v => window.__parkedContexts = v); 0")
            until("parked extension contexts", lambda:
                  obj("eval", parked_extension, "JSON.stringify(window.__parkedContexts || null)")["value"] != "null")
            parked_contexts = json.loads(obj("eval", parked_extension, "JSON.stringify(window.__parkedContexts)")["value"])
            assert parked_contexts == [], parked_contexts
            obj("ext-press", extension_id)
            obj("eval", page, "chrome.sidePanel.setOptions({path: 'page.html'})"
                ".then(() => chrome.sidePanel.open()); 0")
            until("side panel override", lambda: any(
                tab["active"] and tab["url"].endswith("/page.html")
                for tab in obj("tabs")["tabs"]), 10)
            print("space context and duplication: PASS")
        finally:
            server.shutdown()
            if os.environ.get("KEEP") != "1":
                run("env", f"ESCALE_PROBE={WORLD}", ROOT / "fresh.sh", "wipe")


if __name__ == "__main__":
    main()
