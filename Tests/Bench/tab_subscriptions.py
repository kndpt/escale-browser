#!/usr/bin/env python3
"""What the browser watches on a tab goes with the tab.

Browser.prepare subscribes to every tab's address (to save its space's
session) and title (to retitle its history entry). Those subscriptions
used to sit in the browser's app-wide bag, which never let go of them:
every tab ever opened, replaced or restored left two behind. They are
the tab's now (Tab.followers) and closing it cancels them.

Churn, in BLOCKS blocks of CYCLES cycles (3 × 100 for the long local run,
3 × 10 by default), each cycle doing once:

- open/close: an ordinary tab opened as a bookmark in a new tab, closed
  with ⌘W;
- replacement: an extension's page in a bench tab sent to the web, which
  swaps the tab for one built for the web (Browser.replace), then closed;
- spaces: a new space with a page in it, left, entered again and deleted;
  then spaces turned off and on, which closes the row restored for a kept
  space and restores it again from its session.

After every block the rows are as they were before the churn, and so must
be what the app holds. `heap` counts, from outside, without keeping
anything alive: the subscriptions prepare makes (Combine sinks of a URL?
and of a String, which the extensions' own per-tab watch also uses), all
AnyCancellable, Tab objects and PageView objects. The app's physical
footprint and the WebContent processes on the machine are printed as
diagnostics only: the processes are not attributable to this app.

Before and after the churn, and on tabs made by a replacement, the
subscriptions still work: a title the page sets after loading reaches the
history file, a navigation the page makes itself reaches the session file,
and a tab closed leaves the session.

Needs macOS 15.4 for the extension fixtures (written to a temporary
folder; nothing fetched). Runs in its own world (ESCALE_WORLD, default
"a07-subscriptions"), launched through fresh.sh from build/Escale.app —
./build.sh first — and wiped afterwards unless KEEP=1. Pages come from a
local server on 127.0.0.1. Exits non-zero, with expected and actual state
for every failed check.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time

REPO = Path(__file__).resolve().parents[2]
WORLD = os.environ.get("ESCALE_WORLD", "a07-subscriptions")
FOLDER = Path.home() / "Library/Application Support" / f"Escale ({WORLD})"
BINARY = str(REPO / "build/probe" / WORLD / "Escale.app/Contents/MacOS/Escale")
SUITE = f"com.kndpt.escale.test.{WORLD}"
BLOCKS = int(os.environ.get("BLOCKS", "3"))
CYCLES = int(os.environ.get("CYCLES", "10"))
# Room for a tab or two between states when the counts are taken.
SLACK = 2
# Longer than the session's (1.2 s) and history's (1.5 s) debounces.
SETTLE = 3.0
# The subscriptions prepare makes: tab.$address and tab.$title, dropFirst, sink.
SINKS = ("Combine.Subscribers.Sink<Swift.Optional<Foundation.URL>, Swift.Never>",
         "Combine.Subscribers.Sink<Swift.String, Swift.Never>")


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/").split("?")[0] or "home"
        # /later names itself again once loaded: only the title subscription
        # carries that to history.
        later = "<script>setTimeout(() => document.title = 'A07 renamed', 600)</script>" if name == "later" else ""
        body = f"<title>A07 {name}</title><h1>{name}</h1>{later}".encode()
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


def at(url):
    return next((t for t in tabs() if t["url"] == url), None)


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


HEAP_LINE = re.compile(r"^\s*(\d+)\s+\d+\s+[\d.]+\s+(.+?)\s{2,}(?:Swift|ObjC|C\+\+|C)?\s*(\S+)\s*$")


def counts():
    """What the app holds, read by `heap` from outside the process."""
    pids = running()
    if len(pids) != 1:
        raise AssertionError(f"expected one process for {WORLD}, found {pids}")
    out = subprocess.run(["heap", pids[0]], capture_output=True, text=True, timeout=120).stdout
    found = {"sinks": 0, "cancellables": 0, "tabs": 0, "pages": 0, "footprint": ""}
    for line in out.splitlines():
        if line.startswith("Physical footprint:"):
            found["footprint"] = line.split(":", 1)[1].strip()
            continue
        m = HEAP_LINE.match(line)
        if not m:
            continue
        n, name, image = int(m.group(1)), m.group(2).strip(), m.group(3)
        if name in SINKS:
            found["sinks"] += n
        elif name == "AnyCancellable" and image == "Combine":
            found["cancellables"] += n
        elif name == "Tab" and image == "Escale":
            found["tabs"] += n
        elif re.search(r"(^|[._])PageView$", name) and image == "Escale":
            found["pages"] += n
    if not found["footprint"] or found["tabs"] == 0:
        raise AssertionError(f"heap could not read {WORLD}'s process: {out[:300]!r}")
    found["webcontent"] = sum(1 for line in subprocess.run(["ps", "-axo", "comm="], capture_output=True,
                                                           text=True).stdout.splitlines()
                              if "com.apple.WebKit.WebContent" in line)
    return found


def extension(folder, name, newtab=False):
    """A local extension with one page, installed and loaded: its id."""
    folder.mkdir(parents=True)
    manifest = {"manifest_version": 3, "name": name, "version": "1.0", "description": "A07 fixture"}
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


def session(space=None):
    name = "session.json" if space is None else f"session-{space.upper()}.json"
    path = FOLDER / name
    return json.loads(path.read_text()) if path.exists() else {"tabs": []}


def in_session(url, space=None):
    return any(t.get("url") == url for t in session(space)["tabs"])


def history_title(url):
    path = FOLDER / "history.json"
    if not path.exists():
        return None
    return next((v["title"] for v in json.loads(path.read_text()) if v["url"] == url), None)


def main():
    if not (REPO / "build/Escale.app").exists():
        raise AssertionError("no build/Escale.app: run ./build.sh first")
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    fixtures = Path(tempfile.mkdtemp(prefix="escale-a07-"))
    failures = []

    def check(what, ok, found):
        if not ok:
            failures.append(f"{what}; found {found}")

    def works(tag, id=None):
        """The tab's title and its own navigation reach history and session;
        closing it takes it out of the session. A new ordinary tab unless
        id names one already on /later?tag."""
        later, moved = f"{base}/later?{tag}", f"{base}/moved?{tag}"
        if id is None:
            ask("bookmark", url=later, new=True)
            until(f"{later} to open", lambda: at(later) is not None, 10)
            id = at(later)["id"]
        check(f"{tag}: the title the page set after loading reaches history",
              wait_for(lambda: history_title(later) == "A07 renamed", 10), history_title(later))
        ask("eval", id=id, js=f"location.href = {json.dumps(moved)}")
        check(f"{tag}: a navigation the page made reaches the session",
              wait_for(lambda: in_session(moved), 10), session()["tabs"])
        ask("select", id=id)
        ask("press", code=13, chars="w", mods=["cmd"])
        until(f"{tag}: the tab to close", lambda: at(moved) is None, 5)
        check(f"{tag}: the tab closed leaves the session",
              wait_for(lambda: not in_session(moved), 10), session()["tabs"])

    try:
        run([REPO / "fresh.sh", "wipe"], deadline=60)
        run(["defaults", "write", SUITE, "bench", "-bool", "YES"])
        launch()
        ask("ext-answer", answer="yes")
        pages_ext = extension(fixtures / "pages", "A07 pages")

        # The rows the churn comes back to: one tab on screen, and a kept
        # space with two tabs in its saved session.
        ask("bookmark", url=f"{base}/home")
        ask("space", action="new", name="Kept")
        kept = next(s["id"] for s in ask("space")["spaces"] if s["name"] == "Kept")
        ask("bookmark", url=f"{base}/one")
        ask("bookmark", url=f"{base}/two", new=True)
        ask("space", action="go", index=1)
        until("the kept space's session", lambda: len(session(kept)["tabs"]) == 2, 10)
        home = tabs()[0]["id"]

        works("before")
        time.sleep(SETTLE)
        start = counts()
        print(f"start: {start}")

        samples = []
        for block in range(1, BLOCKS + 1):
            for cycle in range(CYCLES):
                tag = f"{block}-{cycle}"
                # Open and close an ordinary tab.
                ask("bookmark", url=f"{base}/one?{tag}", new=True)
                ask("press", code=13, chars="w", mods=["cmd"])
                # Replace an extension's page with the web, then close it.
                page = ask("ext-page", id=pages_ext, path="page.html")["id"]
                target = f"{base}/two?{tag}"
                ask("go", id=page, url=target)
                until(f"{tag}: the replacement tab", lambda: at(target) is not None, 5)
                ask("close", id=at(target)["id"])
                # A space made, left, entered again and deleted.
                ask("space", action="new", name="Churn")
                ask("bookmark", url=f"{base}/three?{tag}")
                ask("space", action="go", index=1)
                ask("space", action="go", index=3)
                ask("space", action="delete")
                # The kept space's restored row closed, and restored again.
                ask("ui", spaces=False)
                ask("ui", spaces=True)
            time.sleep(SETTLE)
            state = ask("space")
            rows = (len(tabs()), len(state["spaces"]), state["parked"])
            now = counts()
            samples.append(now)
            print(f"block {block} ({CYCLES} cycles): {now}; rows {rows}")
            check(f"block {block}: rows as before the churn (1 tab, 2 spaces, kept row of 2)",
                  rows == (1, 2, [{kept: 2}]), rows)
            for key in ("sinks", "tabs", "pages"):
                check(f"block {block}: {key} back to where they started ({start[key]}, +{SLACK})",
                      now[key] <= start[key] + SLACK, now[key])
        check("no growth from the first block to the last in any AnyCancellable",
              samples[-1]["cancellables"] <= samples[0]["cancellables"] + SLACK,
              [s["cancellables"] for s in samples])

        works("after")

        # An approved extension's New Tab page is created on consent, then
        # sent to the web (Browser.replace). The replacing page's subscriptions
        # still work; opening search alone owns no extra tab.
        before = counts()
        extension(fixtures / "newtab", "A07 new tab", newtab=True)
        ask("press", code=17, chars="t", mods=["cmd"])
        until("the new tab page to replace the blank tab",
              lambda: any(t["title"] == "A07 new tab" and t["active"] for t in tabs()), 10)
        later = f"{base}/later?replaced"
        ask("bookmark", url=later)
        until(f"{later} in the replacing tab", lambda: at(later) is not None, 10)
        works("replaced", at(later)["id"])
        time.sleep(SETTLE)
        after = counts()
        print(f"around the replacements: {before} → {after}")
        check("after the replacements and closing, the tabs are back to one",
              [t["id"] for t in tabs()] == [home], tabs())
        for key in ("sinks", "tabs", "pages"):
            check(f"…and {key} to where they were ({before[key]}, +{SLACK})",
                  after[key] <= before[key] + SLACK, after[key])

        if failures:
            raise AssertionError("\n  " + "\n  ".join(failures))
        print(f"ok: {BLOCKS} × {CYCLES} cycles of tabs opened, replaced and closed and spaces made, "
              "restored and dropped left no subscription, tab or view behind; titles, navigation "
              "and closing still reach history and the session")
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
