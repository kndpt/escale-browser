#!/usr/bin/env python3
"""The icon cache and its fetches stay within their bounds.

A site's icon is asked of the page, fetched once and kept in memory and as a
PNG in the world's `icons` folder (Icons.swift). Browsing many sites must not
grow either without end, and fetching them must not open a request per site
visited, read a body past its limit or wait on a server forever:

- many hosts: one ordinary tab goes through 120 sites, each with a small
  icon. With the caps set low for the test (`icons.memory` 32 in memory,
  `icons.files` 48 on disk), no more are held than that, the last site's
  icon is on disk and the first site's has gone;
- slow icons: the tab goes through 10 sites whose icon takes 1.2 s. At most
  2 icon requests are open at once; icons of sites the tab left before their
  turn came are not fetched; the site it stayed on gets its icon;
- large bodies: an icon of 12 MB with no length, one announcing 50 MB and
  one sent a byte every half second. The first is cut once past the 2 MB
  limit, the second refused on its length, the third given up on within the
  fetch's time limit rather than held open;
- errors: 404, 500, bytes that are no image, a connection closed at once.
  Nothing is kept, and going back to those sites asks for nothing again;
- a private tab: its site's icon is fetched for the tab, not written to disk;
- critical memory pressure (`bench idle critical`): the icons held in memory
  are let go (the tabs keep the one they wear).

The server counts icon requests open at once, bytes written per response and
when the other end closed. Hosts are `NAME.localhost`, which resolves to the
loopback; nothing else is fetched. Runs in its own world (ESCALE_WORLD,
default "a09-icons"), launched through fresh.sh from build/Escale.app —
./build.sh first — and wiped afterwards unless KEEP=1. Exits non-zero, with
expected and actual state for every failed check.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import os
import socket
import struct
import subprocess
import sys
import threading
import time
import zlib

REPO = Path(__file__).resolve().parents[2]
WORLD = os.environ.get("ESCALE_WORLD", "a09-icons")
FOLDER = Path.home() / "Library/Application Support" / f"Escale ({WORLD})"
ICONS = FOLDER / "icons"
BINARY = str(REPO / "build/probe" / WORLD / "Escale.app/Contents/MacOS/Escale")
SUITE = f"com.kndpt.escale.test.{WORLD}"

MEMORY_CAP = 32
FILES_CAP = 48
LIMIT = 2_000_000
CHUNK = 64 * 1024


def png(seed):
    """A 32×32 PNG of one colour, different per host."""
    colour = bytes(((seed * 67) % 256, (seed * 131) % 256, (seed * 29) % 256, 255))
    raw = b"".join(b"\x00" + colour * 32 for _ in range(32))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 32, 32, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


class Log:
    """What the server saw of icon requests."""

    def __init__(self):
        self.lock = threading.Lock()
        self.open = 0
        self.peak = 0
        self.requests = []  # dicts: host, kind, bytes, closed_early, ended

    def begin(self, host, kind):
        with self.lock:
            self.open += 1
            self.peak = max(self.peak, self.open)
            entry = {"host": host, "kind": kind, "bytes": 0, "closed_early": False, "ended": None,
                     "started": time.monotonic()}
            self.requests.append(entry)
            return entry

    def end(self, entry):
        with self.lock:
            self.open -= 1
            entry["ended"] = time.monotonic()

    def reset_peak(self):
        with self.lock:
            self.peak = self.open

    def asked(self, host):
        with self.lock:
            return [r for r in self.requests if r["host"] == host]


LOG = Log()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def host(self):
        return (self.headers.get("Host") or "").rsplit(":", 1)[0].strip("[]").lower()

    def do_GET(self):
        host = self.host()
        if self.path.startswith("/p/"):
            kind = self.path[3:]
            body = (f'<!doctype html><title>A09 {host} {kind}</title>'
                    f'<link rel="icon" href="/i/{kind}.png"><h1>{host}</h1>').encode()
            return self.send(200, "text/html; charset=utf-8", body)
        if self.path.startswith("/i/") or self.path == "/favicon.ico":
            kind = self.path[3:].rsplit(".", 1)[0] if self.path.startswith("/i/") else "root"
            entry = LOG.begin(host, kind)
            try:
                self.icon(kind, host, entry)
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, socket.timeout):
                entry["closed_early"] = True
            finally:
                LOG.end(entry)
            return
        self.send(404, "text/plain", b"no")

    def send(self, status, kind, body, length=None):
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body) if length is None else length))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def stream(self, entry, total, every, size=CHUNK, length=None):
        """`total` bytes, `size` at a time, one lot every `every` seconds."""
        self.send_response(200)
        self.send_header("Content-Type", "image/png")
        if length is not None:
            self.send_header("Content-Length", str(length))
        self.send_header("Connection", "close")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.close_connection = True
        head = png(1)
        sent = 0
        while sent < total:
            piece = (head + b"\x00" * size)[:size] if sent == 0 else b"\x00" * size
            self.wfile.write(piece)
            self.wfile.flush()
            sent += len(piece)
            entry["bytes"] = sent
            time.sleep(every)

    def icon(self, kind, host, entry):
        seed = sum(host.encode())
        if kind == "ok":
            data = png(seed)
            self.send(200, "image/png", data)
            entry["bytes"] = len(data)
        elif kind == "slow":
            time.sleep(1.2)
            data = png(seed)
            self.send(200, "image/png", data)
            entry["bytes"] = len(data)
        elif kind == "big":
            self.stream(entry, 12_000_000, 0.002)
        elif kind == "long":
            self.stream(entry, 50_000_000, 0.002, length=50_000_000)
        elif kind == "trickle":
            self.stream(entry, 120, 0.5, size=1)
        elif kind in ("e404", "root"):
            self.send(404, "text/plain", b"none")
        elif kind == "e500":
            self.send(500, "text/plain", b"broken")
        elif kind == "junk":
            self.send(200, "image/png", os.urandom(4096))
        elif kind == "reset":
            self.close_connection = True
            self.connection.shutdown(socket.SHUT_RDWR)
        else:
            self.send(404, "text/plain", b"?")

    def log_message(self, *args):
        pass


class Server(ThreadingHTTPServer):
    address_family = socket.AF_INET6
    daemon_threads = True

    def server_bind(self):
        # Both loopbacks: NAME.localhost resolves to ::1, sometimes 127.0.0.1.
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()


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


def icons():
    return ask("caches")["icons"]


def running():
    lines = subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True, text=True).stdout
    return [line.split(None, 1)[0] for line in lines.splitlines()
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


def launch():
    if running():
        raise AssertionError(f"world {WORLD} is already running")
    run([REPO / "fresh.sh", "again"], deadline=60)
    until("the bench to answer", lambda: bench("tabs", deadline=5, check=False).returncode == 0, 60)


def main():
    if not (REPO / "build/Escale.app").exists():
        raise AssertionError("no build/Escale.app: run ./build.sh first")
    server = Server(("::", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port = server.server_address[1]

    def site(host, kind):
        return f"http://{host}.localhost:{port}/p/{kind}"

    failures = []
    report = {}

    def check(what, ok, found):
        if not ok:
            failures.append(f"{what}; found {found}")

    def visit(id, url, deadline=10):
        ask("go", id=id, url=url)
        until(f"{url} to load", lambda: (lambda t: t["url"] == url and not t["loading"]
                                         and t["title"].startswith("A09"))(tab(id)), deadline)

    def kept(host):
        return (ICONS / f"{host}.localhost.png").exists()

    try:
        run([REPO / "fresh.sh", "wipe"], deadline=60)
        run(["defaults", "write", SUITE, "bench", "-bool", "YES"])
        run(["defaults", "write", SUITE, "icons.memory", "-int", str(MEMORY_CAP)])
        run(["defaults", "write", SUITE, "icons.files", "-int", str(FILES_CAP)])
        # Nothing put to sleep behind the scenario's back.
        run(["defaults", "write", SUITE, "sleep.after", "-float", "36000"])
        launch()
        bench("bookmark", site("start", "ok"), "new", deadline=30)
        id = next(t["id"] for t in tabs() if t["url"].startswith(f"http://start.localhost:{port}"))
        ask("select", id=id)
        until("the first page", lambda: not tab(id)["loading"] and tab(id)["title"].startswith("A09"), 15)

        # 1. Many hosts.
        started = time.monotonic()
        for i in range(120):
            visit(id, site(f"a{i}", "ok"))
        wait_for(lambda: len(LOG.asked("a119.localhost")) > 0 and kept("a119"), 5)
        time.sleep(1.5)
        seen = icons()
        asked = sum(1 for i in range(120) if LOG.asked(f"a{i}.localhost"))
        report["many hosts"] = {"seconds": round(time.monotonic() - started, 1), "icons asked": asked, **seen}
        check(f"at most {MEMORY_CAP} icons in memory after 120 sites", seen["memory"] <= MEMORY_CAP, seen)
        check(f"at most {FILES_CAP} icon files after 120 sites", seen["files"] <= FILES_CAP, seen)
        check("the last site's icon is on disk", kept("a119"), sorted(p.name for p in ICONS.glob("a11*")))
        check("the first site's icon is gone from disk", not kept("a0"), "a0.localhost.png still there")

        # 2. Slow icons, sites left quickly.
        LOG.reset_peak()
        for i in range(10):
            visit(id, site(f"b{i}", "slow"))
        until("the last slow site's icon", lambda: kept("b9"), 20)
        time.sleep(2.5)
        asked = [i for i in range(10) if LOG.asked(f"b{i}.localhost")]
        report["slow icons"] = {"peak open": LOG.peak, "sites asked": asked}
        check("at most 2 icon requests open at once", LOG.peak <= 2, LOG.peak)
        check("icons of sites left before their turn are not fetched", len(asked) < 10, asked)

        # 3. Large and endless bodies.
        for kind, cap, deadline in (("big", 3_000_000, 20), ("long", 1_000_000, 20), ("trickle", None, 25)):
            host = f"c-{kind}"
            visit(id, site(host, kind))
            until(f"{kind} icon to be asked for", lambda: LOG.asked(f"{host}.localhost"), 10)
            entry = LOG.asked(f"{host}.localhost")[0]
            wait_for(lambda: entry["ended"] is not None, deadline, every=0.2)
            took = (entry["ended"] or time.monotonic()) - entry["started"]
            report[f"{kind} icon"] = {"bytes sent": entry["bytes"], "closed by the app": entry["closed_early"],
                                      "seconds": round(took, 1), "still open": entry["ended"] is None}
            if cap is not None:
                check(f"the {kind} icon is cut short: under {cap} bytes sent", entry["bytes"] < cap
                      and entry["closed_early"], report[f"{kind} icon"])
            else:
                check(f"the trickling icon is given up on within {deadline} s",
                      entry["ended"] is not None and entry["closed_early"], report[f"{kind} icon"])
            check(f"nothing kept for the {kind} icon", not kept(host), "a file")

        # 4. Errors, and no asking again.
        errors = ("e404", "e500", "junk", "reset")
        for kind in errors:
            visit(id, site(f"d-{kind}", kind))
        time.sleep(1.5)
        before = {kind: len(LOG.asked(f"d-{kind}.localhost")) for kind in errors}
        for kind in errors:
            visit(id, site(f"d-{kind}", kind))
        time.sleep(1.5)
        after = {kind: len(LOG.asked(f"d-{kind}.localhost")) for kind in errors}
        report["errors"] = {"asked first": before, "asked after coming back": after}
        check("a site whose icon failed is not asked again this session", after == before, after)
        check("nothing kept for failed icons", not any(kept(f"d-{k}") for k in errors),
              [k for k in errors if kept(f"d-{k}")])

        # 5. A private tab.
        ask("press", code=45, chars="n", mods=["cmd", "shift"])
        ask("bookmark", url=site("e-private", "ok"))
        until("a private tab", lambda: any(t["shy"] and t["active"] for t in tabs()), 5)
        shy = next(t["id"] for t in tabs() if t["shy"] and t["active"])
        wait_for(lambda: LOG.asked("e-private.localhost"), 5)
        time.sleep(1)
        check("a private tab's icon is fetched", bool(LOG.asked("e-private.localhost")), "never asked")
        check("…and not written to disk", not kept("e-private"), "a file")

        # 6. Critical memory pressure.
        held = icons()["memory"]
        ask("idle", level="critical")
        time.sleep(0.5)
        let_go = icons()
        report["critical pressure"] = {"memory before": held, "memory after": let_go["memory"]}
        check("critical pressure empties the icons held in memory", let_go["memory"] == 0, let_go)

        print(json.dumps(report, indent=2))
        if failures:
            raise AssertionError("\n  " + "\n  ".join(failures))
        print("ok: icons held, kept on disk, fetched at once and read stay within their bounds, "
              "and errors, private tabs and memory pressure are handled")
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


if __name__ == "__main__":
    sys.exit(main())
