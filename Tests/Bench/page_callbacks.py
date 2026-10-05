#!/usr/bin/env python3
"""Work left over from an earlier page does nothing to the tab's next.

Waking a tab loads its page, then checks on it 1.5 s later: a load handed
to WebKit as a view's very first job, or right after its process died,
doesn't always take (Tab.loadAndVerify). That check, and the 20 ms retries
before it, belong to the load that scheduled them. Once the tab has been
put back to sleep, sent somewhere else or closed, they must do nothing:

- sleep: wake a tab, leave it and put it back to sleep inside the 1.5 s.
  It stays asleep, with no view: the check must not build it a new one
  (it was seen: `space.pages` go from 2 to 3, the tab still asleep).
- a new address: wake a tab on /one, send it to /three, leave it and end
  its page's process, all inside the 1.5 s. The check must not load /one
  again; coming back to the tab loads /three, where it was.
- close: wake a tab and close it with ⌘W inside the 1.5 s. No view is made
  for the closed tab afterwards.
- repeated: sleep, wake and leave a tab five times as fast as the bench
  goes, then let it rest. It ends asleep with no view, and one wake after
  that opens its own page and nothing else.
- crash on screen: the page's process of the tab looked at ends; the tab
  loads its page again, not a white one.

Views are counted by `space.pages`, which reads the views that exist and
builds none. Timing-sensitive steps talk to the socket directly; each
records how long it took, and a step that overran the 1.5 s it has to fit
in is reported as such rather than passed. Runs in its own world
(ESCALE_WORLD, default "a06-callbacks"), launched through fresh.sh from
build/Escale.app — ./build.sh first — and wiped afterwards unless KEEP=1.
Pages come from a local server on 127.0.0.1; nothing else is fetched.
Exits non-zero, with expected and actual state for every failed check.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import os
import socket
import subprocess
import sys
import threading
import time

REPO = Path(__file__).resolve().parents[2]
WORLD = os.environ.get("ESCALE_WORLD", "a06-callbacks")
FOLDER = Path.home() / "Library/Application Support" / f"Escale ({WORLD})"
BINARY = str(REPO / "build/probe" / WORLD / "Escale.app/Contents/MacOS/Escale")
SUITE = f"com.kndpt.escale.test.{WORLD}"
# The check after a wake runs 1.5 s after it; each race has to be over by then.
CHECK = 1.5
# Long enough past the check for anything it does to show.
SETTLE = 3.0

served = []
served_lock = threading.Lock()


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/") or "home"
        with served_lock:
            served.append(self.path)
        body = f"<title>A06 {name}</title><h1>{name}</h1>".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        # Every load a request, so the server's log counts them.
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def asked(path):
    with served_lock:
        return served.count(path)


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


def tab(id):
    return next((t for t in tabs() if t["id"] == id), None)


def at(url):
    return next((t for t in tabs() if t["url"] == url), None)


def pages():
    """Views that exist, counted without building any."""
    return len(ask("space")["pages"])


def running():
    lines = subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True, text=True).stdout
    return [line.split(None, 1)[0] for line in lines.splitlines()
            if line.strip().split(None, 1)[-1] == BINARY]


def wait_for(check, deadline, every=0.05):
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


def open_tab(url):
    """An ordinary tab at url, at the end of the row, once loaded."""
    bench("bookmark", url, "new", deadline=30)
    until(f"{url} to load", lambda: at(url)["title"].startswith("A06") and not at(url)["loading"], 10)
    return at(url)["id"]


def shown(id, url):
    """The tab's view is on url and done loading."""
    t = tab(id)
    return t["view"] == url and not t["loading"] and not t["asleep"]


def put_to_sleep(id, deadline=5):
    """Asleep, retried while a load that just started keeps it awake."""
    said = []

    def sleep():
        said.append(ask("sleep", id=id)["said"])
        return said[-1] in ("asleep", "already asleep")

    until(f"{id} to sleep (said {said[-3:]})", sleep, deadline)


def main():
    if not (REPO / "build/Escale.app").exists():
        raise AssertionError("no build/Escale.app: run ./build.sh first")
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    one, two, three, four = (f"{base}/{name}" for name in ("one", "two", "three", "four"))
    failures = []
    overran = []

    def check(what, ok, found):
        if not ok:
            failures.append(f"{what}; found {found}")

    def within(what, started):
        took = time.monotonic() - started
        if took >= CHECK:
            overran.append(f"{what} took {took:.2f}s, past the {CHECK}s check")
        return took

    try:
        run([REPO / "fresh.sh", "wipe"], deadline=60)
        run(["defaults", "write", SUITE, "bench", "-bool", "YES"])
        launch()
        a = open_tab(one)
        b = open_tab(two)

        # 1. Wake, leave, sleep again inside the check.
        put_to_sleep(a)
        until("the slept view to go", lambda: tab(a)["view"] == "", 5)
        before = pages()
        started = time.monotonic()
        ask("select", id=a)
        until(f"{one} to load again", lambda: shown(a, one), CHECK)
        ask("select", id=b)
        put_to_sleep(a, deadline=CHECK)
        took = within("wake, leave and sleep", started)
        time.sleep(max(0, SETTLE - took))
        check("the woken tab put back to sleep stays asleep", tab(a)["asleep"], tab(a))
        check("…with no view", tab(a)["view"] == "", tab(a))
        check(f"no view made after the check: {before} views as before the wake", pages() == before, pages())

        # 2. Wake on /one, then /three, then out of sight and its process gone.
        started = time.monotonic()
        ask("select", id=a)
        until(f"{one} to load again", lambda: shown(a, one), CHECK)
        ask("go", id=a, url=three)
        until(f"{three} to load", lambda: shown(a, three), CHECK)
        asked_one = asked("/one")
        ask("select", id=b)
        ask("crash", id=a)
        took = within("wake, go elsewhere, leave and crash", started)
        time.sleep(max(0, SETTLE - took))
        check(f"{one} not asked for again after the tab went to {three}", asked("/one") == asked_one,
              f"{asked('/one') - asked_one} more")
        check(f"the tab still says {three}", tab(a)["url"] == three, tab(a))
        asked_three = asked("/three")
        ask("select", id=a)
        check(f"back on the tab, its page comes back at {three}", wait_for(lambda: shown(a, three), 10), tab(a))
        check(f"…fetched again, not left white", asked("/three") > asked_three and not tab(a)["hollow"], tab(a))

        # 3. Wake and close with ⌘W inside the check.
        c = open_tab(four)
        ask("select", id=b)
        put_to_sleep(c)
        until("the slept view to go", lambda: tab(c)["view"] == "", 5)
        before = pages()
        started = time.monotonic()
        ask("select", id=c)
        until(f"{four} to load again", lambda: shown(c, four), CHECK)
        ask("press", code=13, chars="w", mods=["cmd"])
        until("the tab to close", lambda: tab(c) is None, CHECK)
        took = within("wake and close", started)
        time.sleep(max(0, SETTLE - took))
        check(f"no view made for the closed tab: {before} views as before its wake", pages() == before, pages())

        # 4. Round and round, as fast as the bench goes.
        ask("select", id=b)
        put_to_sleep(a)
        until("the slept view to go", lambda: tab(a)["view"] == "", 5)
        before = pages()
        for _ in range(5):
            ask("select", id=a)
            ask("select", id=b)
            put_to_sleep(a)
        time.sleep(SETTLE)
        check("after five quick rounds the tab is asleep", tab(a)["asleep"], tab(a))
        check("…with no view", tab(a)["view"] == "", tab(a))
        check(f"…and {before} views, as before them", pages() == before, pages())
        asked_three = asked("/three")
        ask("select", id=a)
        check(f"one more wake opens {three}", wait_for(lambda: shown(a, three), 10), tab(a))
        time.sleep(SETTLE)
        check(f"…fetched at most once", asked("/three") <= asked_three + 1, f"{asked('/three') - asked_three} times")
        check(f"…with one more view than while it slept", pages() == before + 1, pages())

        # 5. The page on screen loses its process.
        asked_three = asked("/three")
        ask("crash", id=a)
        check(f"the tab on screen comes back at {three}",
              wait_for(lambda: asked("/three") > asked_three and shown(a, three), 10), tab(a))
        check("…not white", not tab(a)["hollow"], tab(a))

        if overran:
            failures.append("inconclusive, too slow to race the check: " + "; ".join(overran))
        if failures:
            raise AssertionError("\n  " + "\n  ".join(failures))
        print("ok: nothing scheduled for an earlier load woke, rebuilt or sent back a tab "
              "that slept, moved on or closed, and a page whose process ended came back")
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
