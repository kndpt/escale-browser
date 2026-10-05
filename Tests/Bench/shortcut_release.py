#!/usr/bin/env python3
"""A bookmark picked after a shortcut goes where it was asked.

`bench press` used to post the key with ⌘ held and never let ⌘ go. The
last event the app had seen still held it, and Browser.visit, which reads
the modifiers of that event to tell a ⌘-click, took the next bookmark
picked for one: after ⌘T or ⌘W it opened a tab of its own instead of going
into the tab on screen. An extension's page it should have replaced
(Browser.replace) stayed in the row, which is how tab_subscriptions.py
failed.

Each step checks the row right after it: how many tabs, which is on
screen and where it is, and that a replaced tab is gone.

1. ⌘T opens search only; the bookmark creates exactly one tab.
2. ⌘W, then a bookmark in a new tab: one tab more, not two.
3. ⌘W, then an extension's page selected and a bookmark: the page is
   replaced where it stands.
4. With an extension's new tab page, ⌘T opens the approved
   page, then a bookmark: the page is replaced where it stands.

Needs macOS 15.4 for the extension fixtures (written to a temporary
folder; nothing fetched). Runs in its own world (ESCALE_WORLD, default
"issue16-shortcuts"), launched through fresh.sh from build/Escale.app —
./build.sh first — and wiped afterwards unless KEEP=1. Pages come from a
local server on 127.0.0.1. Exits non-zero, with expected and actual state
for every failed check.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time

REPO = Path(__file__).resolve().parents[2]
WORLD = os.environ.get("ESCALE_WORLD", "issue16-shortcuts")
FOLDER = Path.home() / "Library/Application Support" / f"Escale ({WORLD})"
BINARY = str(REPO / "build/probe" / WORLD / "Escale.app/Contents/MacOS/Escale")
SUITE = f"com.kndpt.escale.test.{WORLD}"


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/").split("?")[0] or "home"
        body = f"<title>Issue 16 {name}</title><h1>{name}</h1>".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def run(args, deadline=30, check=True):
    env = dict(os.environ, ESCALE_PROBE=WORLD)
    env.pop("ESCALE_MEASURE", None)
    done = subprocess.run([str(a) for a in args], cwd=REPO, env=env, capture_output=True,
                          text=True, timeout=deadline)
    if check and done.returncode != 0:
        raise AssertionError(f"{' '.join(map(str, args))} exited {done.returncode}: {done.stderr.strip()}")
    return done


def bench(*args, deadline=30, check=True):
    return run([REPO / "bench", "--world", WORLD, *args], deadline=deadline, check=check)


def ask(verb, **fields):
    """One request straight to the socket: no process started per step."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(30)
        s.connect(str(FOLDER / "bench.sock"))
        s.sendall((json.dumps({"do": verb, **fields}) + "\n").encode())
        chunks = []
        while chunk := s.recv(1 << 16):
            chunks.append(chunk)
    reply = json.loads(b"".join(chunks).split(b"\n", 1)[0])
    if "error" in reply:
        raise AssertionError(f"{verb} {fields}: {reply['error']}")
    return reply


def tabs():
    return ask("tabs")["tabs"]


def running():
    lines = subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True, text=True).stdout
    return [line.split(None, 1)[0] for line in lines.splitlines()
            if line.strip().split(None, 1)[-1] == BINARY]


def wait_for(check, deadline, every=0.1):
    """Whether check() came true before the deadline."""
    end = time.monotonic() + deadline
    while time.monotonic() < end:
        try:
            if check():
                return True
        except (subprocess.TimeoutExpired, AssertionError, OSError, ValueError, KeyError, TypeError):
            pass
        time.sleep(every)
    return False


def until(what, check, deadline):
    if not wait_for(check, deadline):
        raise AssertionError(f"timed out after {deadline}s waiting for {what}")


def launch():
    if running():
        raise AssertionError(f"world {WORLD} is already running")
    run([REPO / "fresh.sh", "again"], deadline=60)
    until("the bench to answer", lambda: bench("tabs", deadline=5, check=False).returncode == 0, 60)


def extension(folder, name, newtab=False):
    """A local extension with one page, installed and loaded: its id."""
    folder.mkdir(parents=True)
    manifest = {"manifest_version": 3, "name": name, "version": "1.0", "description": "Issue 16 fixture"}
    if newtab:
        manifest["chrome_url_overrides"] = {"newtab": "page.html"}
    (folder / "manifest.json").write_text(json.dumps(manifest))
    (folder / "page.html").write_text(f"<title>{name}</title><h1>{name}</h1>")
    ask("ext-folder", path=str(folder), yes=True)

    def loaded():
        found = [e for e in ask("extensions")["extensions"] if e["name"] == name]
        return found[0]["id"] if found and found[0]["loaded"] else None

    until(f"{name} to load", loaded, 30)
    return loaded()


def row():
    """The row as (id, url, on screen), in order."""
    return [(t["id"], t["url"], t["active"]) for t in tabs()]


def main():
    if not (REPO / "build/Escale.app").exists():
        raise AssertionError("no build/Escale.app: run ./build.sh first")
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    fixtures = Path(tempfile.mkdtemp(prefix="escale-issue16-"))
    failures = []

    def check(what, ok, found):
        if not ok:
            failures.append(f"{what}; found {found}")

    def went(step, url, before, replaced=None):
        """After a bookmark: the row as before, with url on screen in the
        place of the tab that was — replaced, when it had to be."""
        after = row()
        check(f"{step}: as many tabs as before ({len(before)})", len(after) == len(before), after)
        was = next((i for i, t in enumerate(before) if t[2]), None)
        now = next((i for i, t in enumerate(after) if t[2]), None)
        check(f"{step}: {url} on screen, where the tab on screen was ({was})",
              now == was and now is not None and after[now][1] == url, after)
        if replaced is not None:
            check(f"{step}: the extension's page {replaced} gone from the row",
                  all(t[0] != replaced for t in after), after)
        else:
            check(f"{step}: into the same tab", now is not None and was is not None
                  and after[now][0] == before[was][0], after)
        return after

    def close():
        """⌘W on the tab on screen: one tab less."""
        before = row()
        ask("press", code=13, chars="w", mods=["cmd"])
        until("⌘W to close the tab on screen", lambda: len(tabs()) == len(before) - 1, 5)

    try:
        run([REPO / "fresh.sh", "wipe"], deadline=60)
        run(["defaults", "write", SUITE, "bench", "-bool", "YES"])
        launch()
        ask("ext-answer", answer="yes")
        pages_ext = extension(fixtures / "pages", "Issue 16 pages")

        ask("bookmark", url=f"{base}/home")
        until("the first page", lambda: row()[-1][1] == f"{base}/home", 10)
        home = row()
        check("one tab to start from", len(home) == 1, home)

        # 1. ⌘T, then a bookmark.
        ask("press", code=17, chars="t", mods=["cmd"])
        check("⌘T leaves the row intact", row() == home, row())
        ask("bookmark", url=f"{base}/after-t")
        check("committing the bookmark adds exactly one tab", len(tabs()) == 2, row())
        check("the source page remains unchanged", row()[0][1] == f"{base}/home", row())
        check("the new bookmark page is selected", row()[-1][1:] == (f"{base}/after-t", True), row())
        close()

        # 2. ⌘W, then a bookmark in a new tab.
        before = row()
        ask("bookmark", url=f"{base}/new-after-w", new=True)
        after = row()
        check(f"⌘W then a bookmark in a new tab: one tab more ({len(before) + 1})",
              len(after) == len(before) + 1, after)
        check("…the new one on screen, on the bookmark, at the end",
              after[-1][1] == f"{base}/new-after-w" and after[-1][2], after)
        close()

        # 3. ⌘W, then an extension's page selected and a bookmark.
        ask("press", code=17, chars="t", mods=["cmd"])
        check("⌘T still leaves the row intact", row() == home, row())
        ask("press", code=13, chars="w", mods=["cmd"])
        check("⌘W cancels uncommitted search", row() == home, row())
        page = ask("ext-page", id=pages_ext, path="page.html")["id"]
        ask("select", id=page)
        until("the extension's page on screen",
              lambda: any(t["id"] == page and t["active"] and t["title"] == "Issue 16 pages" for t in tabs()), 10)
        before = row()
        ask("bookmark", url=f"{base}/from-page")
        went("⌘W, an extension's page, then a bookmark", f"{base}/from-page", before, replaced=page)
        ask("close", id=next(t[0] for t in row() if t[1] == f"{base}/from-page"))

        # 4. An extension's new tab page after ⌘T, then a bookmark.
        extension(fixtures / "newtab", "Issue 16 new tab", newtab=True)
        ask("press", code=17, chars="t", mods=["cmd"])
        until("the new tab page on screen",
              lambda: any(t["title"] == "Issue 16 new tab" and t["active"] for t in tabs()), 10)
        before = row()
        newtab = next(t[0] for t in before if t[2])
        ask("bookmark", url=f"{base}/from-new-tab")
        went("⌘T to an extension's new tab page, then a bookmark", f"{base}/from-new-tab", before,
             replaced=newtab)
        close()
        check("the row is back to the first tab", [t[0] for t in row()] == [home[0][0]], row())

        if failures:
            raise AssertionError("\n  " + "\n  ".join(failures))
        print("ok: after ⌘T and ⌘W, with and without an extension's page, a bookmark goes into "
              "the tab on screen or replaces it where it stands; a new tab only when asked for")
        return 0
    except (AssertionError, subprocess.TimeoutExpired) as failure:
        if failures and not str(failure).startswith("\n"):
            failure = f"{failure}\n  " + "\n  ".join(failures)
        print(f"FAIL: {failure}", file=sys.stderr)
        return 1
    finally:
        server.shutdown()
        if os.environ.get("KEEP") != "1":
            run([REPO / "fresh.sh", "wipe"], deadline=60, check=False)


if __name__ == "__main__":
    sys.exit(main())
