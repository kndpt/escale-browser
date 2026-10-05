#!/usr/bin/env python3
"""Putting twenty pages to sleep costs a bounded amount, and they come back.

A tab put to sleep gives its page back and keeps a picture of it, shown for
the moment it takes to wake (Sleep.swift, Tab.sleep). Twenty tabs going to
sleep at once must not take twenty pictures at once, the pictures kept must
stay within a budget, and under critical memory pressure pages are let go
without first being pictured. Checked here, in one world, with ordinary
tabs on local pages scrolled to a place of their own:

- the ordinary pass (`bench idle 0`, what the half-hour timer runs) puts the
  19 page tabs not on screen to sleep; at most one picture is taken at a
  time, and those kept weigh no more than the budget (`sleep.pictures`, set
  low here so that some are let go); the tab on screen, one holding a draft
  typed with real keys and a pinned one stay awake;
- every tab put to sleep wakes on its own page, scrolled where it was left,
  whether or not its picture was kept;
- critical memory pressure (`bench idle critical`) puts them to sleep again
  without taking a picture, and lets go of the pictures already kept; they
  wake as well; the draft and the pinned tab stay awake;
- the pinned tab's cost: unpinned, the same pressure puts it to sleep, and
  its page's memory is reported. Pins are kept awake on purpose (Sleep.swift);
  this measures that choice, it does not change it.

For each pass the app's physical footprint (before, peak during, after) and
the WebContent processes the app is responsible for (count and summed
footprint, `responsibility_get_pid_responsible_for_pid`) are printed. The
peak is the kernel's own maximum since a reset just before the pass
(`proc_reset_footprint_interval`), and a 5 ms sampler as a fallback. They
are measurements, not assertions: the assertions are on counts and on what
the tabs come back to.

Runs in its own world (ESCALE_WORLD, default "a09-sleep"), launched through
fresh.sh from build/Escale.app — ./build.sh first — and wiped afterwards
unless KEEP=1. Pages come from a local server on 127.0.0.1. Exits non-zero,
with expected and actual state for every failed check.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import ctypes
import json
import os
import socket
import subprocess
import sys
import threading
import time

REPO = Path(__file__).resolve().parents[2]
WORLD = os.environ.get("ESCALE_WORLD", "a09-sleep")
FOLDER = Path.home() / "Library/Application Support" / f"Escale ({WORLD})"
BINARY = str(REPO / "build/probe" / WORLD / "Escale.app/Contents/MacOS/Escale")
SUITE = f"com.kndpt.escale.test.{WORLD}"
PAGES = 20
# Low enough that some of the 19 pictures are let go.
BUDGET = int(os.environ.get("BUDGET", str(1_500_000)))


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/")
        if name == "draft":
            body = "<title>A09 draft</title><textarea id=t style='width:600px;height:200px'></textarea>"
        else:
            n = int(name.rsplit("/", 1)[-1]) if name.rsplit("/", 1)[-1].isdigit() else 99
            blocks = "".join(
                f"<div class=b style='background:linear-gradient(90deg,hsl({(n * 17 + k * 29) % 360},70%,55%),"
                f"hsl({(n * 17 + k * 29 + 140) % 360},60%,35%))'><h2>{n}.{k}</h2><p>"
                + ("Lorem ipsum dolor sit amet, consectetur adipiscing elit. " * 12) + "</p></div>"
                for k in range(40))
            body = (f"<title>A09 {name}</title><style>body{{margin:0;font:16px -apple-system}}"
                    f".b{{min-height:280px;padding:12px;color:white}}</style><h1>{name}</h1>{blocks}")
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

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


def tab(id):
    return next((t for t in tabs() if t["id"] == id), None)


def running():
    lines = subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True, text=True).stdout
    return [int(line.split(None, 1)[0]) for line in lines.splitlines()
            if line.strip().split(None, 1)[-1] == BINARY]


def wait_for(check, deadline, every=0.05):
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


# Memory, from the kernel's own accounting of each process.
FIELDS = ("user system pkg_idle intr pageins wired resident footprint start exit child_user child_system "
          "child_pkg_idle child_intr child_pageins child_elapsed diskio_read diskio_write cpu_default "
          "cpu_maint cpu_bg cpu_util cpu_legacy cpu_user_init cpu_user_int billed_system serviced_system "
          "logical_writes lifetime_max_footprint instructions cycles billed_energy serviced_energy "
          "interval_max_footprint runnable_time flags").split()


class Usage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in FIELDS]


LIBC = ctypes.CDLL(None)
LIBPROC = ctypes.CDLL("/usr/lib/libproc.dylib")
LIBC.responsibility_get_pid_responsible_for_pid.argtypes = [ctypes.c_int]
LIBC.responsibility_get_pid_responsible_for_pid.restype = ctypes.c_int
MB = 1 << 20


def usage(pid):
    found = Usage()
    return found if LIBPROC.proc_pid_rusage(pid, 4, ctypes.byref(found)) == 0 else None


def footprint(pid):
    found = usage(pid)
    return found.footprint if found else 0


def webkit(app):
    """The WebKit processes the app is responsible for, by kind."""
    lines = subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True, text=True).stdout
    found = {}
    for pid, comm in (line.split(None, 1) for line in lines.splitlines()):
        if "com.apple.WebKit." in comm and LIBC.responsibility_get_pid_responsible_for_pid(int(pid)) == app:
            found.setdefault(comm.strip().rsplit(".", 1)[-1], []).append(int(pid))
    return found


def memory(app):
    """The app's footprint, and each kind of WebKit process: count and MB."""
    found = {"app MB": round(footprint(app) / MB, 1)}
    for kind in ("WebContent", "GPU", "Networking"):
        pids = webkit(app).get(kind, [])
        found[kind] = len(pids)
        found[f"{kind} MB"] = round(sum(footprint(p) for p in pids) / MB, 1)
    found["all MB"] = round(found["app MB"] + sum(found[f"{k} MB"] for k in ("WebContent", "GPU", "Networking")), 1)
    return found


class Peak:
    """The app's highest footprint while a pass runs."""

    def __init__(self, app):
        self.app = app
        self.reset = hasattr(LIBC, "proc_reset_footprint_interval") and \
            LIBC.proc_reset_footprint_interval(app) == 0
        self.sampled = footprint(app)
        self.going = True
        self.thread = threading.Thread(target=self.sample, daemon=True)
        self.thread.start()

    def sample(self):
        while self.going:
            self.sampled = max(self.sampled, footprint(self.app))
            time.sleep(0.005)

    def stop(self):
        self.going = False
        self.thread.join()
        found = usage(self.app)
        kernel = found.interval_max_footprint if (found and self.reset) else 0
        return round(max(kernel, self.sampled) / MB, 1)


def main():
    if not (REPO / "build/Escale.app").exists():
        raise AssertionError("no build/Escale.app: run ./build.sh first")
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    failures = []
    report = {}

    def check(what, ok, found):
        if not ok:
            failures.append(f"{what}; found {found}")

    def open_tab(url):
        """An ordinary tab on url, on screen and loaded."""
        bench("bookmark", url, "new", deadline=30)
        id = next(t["id"] for t in tabs() if t["url"] == url)
        ask("select", id=id)
        until(f"{url} to load", lambda: (lambda t: not t["loading"] and t["view"] == url
                                         and t["title"].startswith("A09"))(tab(id)), 15)
        return id

    def scrolled(id):
        return ask("eval", id=id, js="Math.round(window.scrollY)")["value"]

    def comes_back(id, url, y, label):
        ask("select", id=id)
        ok = wait_for(lambda: (lambda t: not t["asleep"] and not t["loading"] and t["view"] == url
                               and not t["hollow"])(tab(id)), 15)
        check(f"{label}: {url} wakes on its page", ok, tab(id))
        if ok:
            got = wait_for(lambda: abs(scrolled(id) - y) <= 2, 5)
            check(f"{label}: {url} wakes scrolled where it was ({y})", got, scrolled(id))

    def put_to_sleep(level, label, pages, first):
        """A pass, measured; the page tabs but the first end asleep."""
        ask("select", id=first)
        time.sleep(3)
        app = running()[0]
        before = memory(app)
        taken = ask("caches")["pictures"].get("taken", 0)
        peak = Peak(app)
        started = time.monotonic()
        ask("idle", **({"level": level} if level else {"seconds": 0}))
        done = wait_for(lambda: all(tab(id)["asleep"] for id, _, _ in pages[1:]), 60, every=0.1)
        took = time.monotonic() - started
        top = peak.stop()
        time.sleep(3)
        after = memory(app)
        caches = ask("caches")["pictures"]
        caches["taken in the pass"] = caches.get("taken", 0) - taken if "taken" in caches else None
        rows = {t["id"]: t for t in tabs()}
        report[label] = {
            "seconds to sleep": round(took, 2), "before": before, "app peak MB": top, "after": after,
            "pictures": caches, "picture KB": sorted(round(rows[id]["picture"] / 1024) for id, _, _ in pages[1:]),
        }
        check(f"{label}: the {len(pages) - 1} page tabs not on screen are asleep", done,
              [rows[id]["asleep"] for id, _, _ in pages[1:]])
        return caches, rows

    try:
        run([REPO / "fresh.sh", "wipe"], deadline=60)
        run(["defaults", "write", SUITE, "bench", "-bool", "YES"])
        run(["defaults", "write", SUITE, "sleep.after", "-float", "36000"])
        run(["defaults", "write", SUITE, "sleep.pictures", "-int", str(BUDGET)])
        launch()
        ask("resize", width=1280, height=800)

        pages = []
        for i in range(PAGES):
            url = f"{base}/page/{i}"
            id = open_tab(url)
            y = 500 + 37 * i
            ask("eval", id=id, js=f"window.scrollTo(0, {y}); 1")
            until(f"{url} to scroll", lambda: scrolled(id) == y, 5)
            pages.append((id, url, y))
        draft = open_tab(f"{base}/draft")
        ask("tap", id=draft, selector="#t")
        ask("key", id=draft, text="draft")
        until("the draft to be typed", lambda: ask("eval", id=draft, js="t.value")["value"] == "draft", 5)
        pin = open_tab(f"{base}/page/pin")
        ask("pin", id=pin, on=True)
        first = pages[0][0]

        # 1. The ordinary pass.
        caches, rows = put_to_sleep(None, "ordinary pass", pages, first)
        check("at most one picture taken at a time", caches.get("peak", 99) <= 1, caches)
        check(f"pictures kept weigh at most {BUDGET} bytes", caches["bytes"] <= BUDGET, caches)
        check("some pictures are kept", caches["count"] > 0, caches)
        check("the tab on screen stays awake", not rows[first]["asleep"], rows[first])
        check("the tab holding a draft stays awake", not rows[draft]["asleep"], rows[draft])
        check("the pinned tab stays awake", not rows[pin]["asleep"], rows[pin])
        for id, url, y in pages[1:]:
            comes_back(id, url, y, "after the ordinary pass")
        time.sleep(3)
        report["ordinary pass"]["after waking all"] = memory(running()[0])

        # 2. Critical pressure.
        caches, rows = put_to_sleep("critical", "critical pressure", pages, first)
        check("no picture taken under critical pressure, none kept",
              caches["taken in the pass"] == 0 and caches["count"] == 0, caches)
        check("the draft stays awake under critical pressure", not rows[draft]["asleep"], rows[draft])
        check("the pinned tab stays awake under critical pressure", not rows[pin]["asleep"], rows[pin])
        for id, url, y in (pages[1], pages[10], pages[19]):
            comes_back(id, url, y, "after critical pressure")
        check("the draft is still there", ask("eval", id=draft, js="t.value")["value"] == "draft", "lost")

        # 3. What the pin costs.
        ask("select", id=first)
        time.sleep(3)
        app = running()[0]
        pinned = memory(app)
        ask("pin", id=pin, on=False)
        ask("idle", level="critical")
        until("the unpinned tab to sleep", lambda: tab(pin)["asleep"], 30)
        time.sleep(3)
        unpinned = memory(app)
        report["pinned tab"] = {"pinned, awake": pinned, "unpinned, asleep": unpinned,
                                "its page MB": round(pinned["WebContent MB"] - unpinned["WebContent MB"], 1)}

        print(json.dumps(report, indent=2))
        if failures:
            raise AssertionError("\n  " + "\n  ".join(failures))
        print("ok: twenty pages put to sleep one picture at a time, within the pictures' budget, "
              "none pictured under critical pressure, all back where they were")
        return 0
    except (AssertionError, subprocess.TimeoutExpired) as failure:
        if report:
            print(json.dumps(report, indent=2))
        if failures and not str(failure).startswith("\n"):
            failure = f"{failure}\n  " + "\n  ".join(failures)
        print(f"FAIL: {failure}", file=sys.stderr)
        return 1
    finally:
        server.shutdown()
        if os.environ.get("KEEP") != "1":
            run([REPO / "fresh.sh", "wipe"], deadline=60, check=False)


def launch():
    if running():
        raise AssertionError(f"world {WORLD} is already running")
    run([REPO / "fresh.sh", "again"], deadline=60)
    until("the bench to answer", lambda: bench("tabs", deadline=5, check=False).returncode == 0, 60)


if __name__ == "__main__":
    sys.exit(main())
