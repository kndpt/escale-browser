#!/usr/bin/env python3
"""The address field over a history far past its bound.

The bound and the ranking are proven by the Swift tests on History
(Tests/EscaleTests/HistoryTests.swift). This checks what they can't: the app
reading a 20,000-place history.json at launch, the real field offering the
places a person goes to most while it is typed into a key at a time, a visit
recorded at the bound, and the file written back within it on ⌘Q.

The history is synthetic: three places visited often (projectalpha, beta and
gamma under example.test) among 19,997 seen once, two months ago or more, all
matching "project". The field must offer the three first, in that order. It
also prints each key's time until the window rests (`bench field … type`), so
the same script measures typing before and after a change: run it from each
checkout with MEASURE=1 and ROUNDS=15 (105 keys), on an otherwise idle Mac,
and PLACES=2000 for the history's bound rather than past it.

Runs in its own world (ESCALE_WORLD, default "a04-history"), launched through
fresh.sh from build/Escale.app — ./build.sh first — and wiped afterwards
unless KEEP=1. The visited page comes from a local server on 127.0.0.1;
nothing else is fetched. Exits non-zero, with expected and actual state, on
failure.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import os
import statistics
import subprocess
import sys
import threading
import time

REPO = Path(__file__).resolve().parents[2]
WORLD = os.environ.get("ESCALE_WORLD", "a04-history")
FOLDER = Path.home() / "Library/Application Support" / f"Escale ({WORLD})"
BINARY = str(REPO / "build/probe" / WORLD / "Escale.app/Contents/MacOS/Escale")
SUITE = f"com.kndpt.escale.test.{WORLD}"
ROUNDS = int(os.environ.get("ROUNDS", "3"))
PLACES = int(os.environ.get("PLACES", "20000"))
ROOM = 2_000
TYPED = "project"
OFTEN = ["projectalpha.example.test", "projectbeta.example.test", "projectgamma.example.test"]
# Foundation's JSONEncoder writes a Date as seconds since 1 January 2001.
EPOCH_2001 = 978_307_200


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/") or "home"
        body = f"<title>A04 {name}</title><h1>{name}</h1>".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def run(args, deadline=30, check=True):
    env = dict(os.environ, ESCALE_PROBE=WORLD)
    if os.environ.get("MEASURE") != "1":
        env.pop("ESCALE_MEASURE", None)
    else:
        env["ESCALE_MEASURE"] = "1"
    done = subprocess.run([str(a) for a in args], cwd=REPO, env=env, capture_output=True,
                          text=True, timeout=deadline)
    if check and done.returncode != 0:
        raise AssertionError(f"{' '.join(map(str, args))} exited {done.returncode}: {done.stderr.strip()}")
    return done


def bench(*args, deadline=30, check=True):
    return run([REPO / "bench", "--world", WORLD, *args], deadline=deadline, check=check)


def running():
    lines = subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True, text=True).stdout
    return [line.split(None, 1)[0] for line in lines.splitlines()
            if line.strip().split(None, 1)[-1] == BINARY]


def until(what, check, deadline):
    end = time.monotonic() + deadline
    while time.monotonic() < end:
        try:
            if check():
                return
        except (subprocess.TimeoutExpired, AssertionError, OSError, ValueError):
            pass
        time.sleep(0.2)
    raise AssertionError(f"timed out after {deadline}s waiting for {what}")


def listening():
    return bench("tabs", deadline=5, check=False).returncode == 0


def loaded(url):
    """The active tab is at url and done loading, per `bench tabs`."""
    for line in bench("tabs", deadline=5).stdout.splitlines():
        if line.startswith("●"):
            return line.rstrip().endswith(url)
    return False


def seed():
    """history.json as the app writes it, PLACES places, before first launch."""
    now = time.time() - EPOCH_2001
    places = [
        {"url": f"https://{key}/", "key": key, "title": key, "count": count, "last": now - 60}
        for key, count in zip(OFTEN, (900, 800, 700))
    ]
    places += [
        {"url": f"https://project{i}.example.test/docs", "key": f"project{i}.example.test/docs",
         "title": f"Project {i}", "count": 1, "last": now - 60 * 86_400 - 60 * i}
        for i in range(PLACES - len(OFTEN))
    ]
    FOLDER.mkdir(parents=True, exist_ok=True)
    (FOLDER / "history.json").write_text(json.dumps(places))


def launch():
    if running():
        raise AssertionError(f"world {WORLD} is already running")
    run([REPO / "fresh.sh", "again"], deadline=60)
    until("the bench to answer", listening, 60)


def typed_round():
    """TYPED a key at a time; the offers and each key's time until rest."""
    answer = json.loads(bench("field", TYPED, "type", deadline=60).stdout)
    if answer.get("typed") != TYPED:
        raise AssertionError(f"field holds {answer.get('typed')!r}, expected {TYPED!r}")
    offers = answer.get("offers", [])
    if offers[:3] != OFTEN:
        raise AssertionError(f"offers for {TYPED!r}: expected {OFTEN} first, found {offers}")
    # Escape: the field closes and forgets what was typed (the tab has a page).
    bench("press", "53", "\x1b", deadline=10)
    return [rested for _, rested in answer["ms"]]


def percentile(values, share):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(len(ordered) * share))]


def main():
    if not (REPO / "build/Escale.app").exists():
        raise AssertionError("no build/Escale.app: run ./build.sh first")
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://localhost:{server.server_address[1]}"
    start, later = f"{base}/start", f"{base}/later"
    try:
        run([REPO / "fresh.sh", "wipe"], deadline=60)
        run(["defaults", "write", SUITE, "bench", "-bool", "YES"])
        seed()
        launch()

        # A page behind the field, so Escape closes it between rounds.
        bench("field", start, "go", deadline=30)
        until("the first page to load", lambda: loaded(start), 15)
        bench("press", "53", "\x1b", deadline=10)

        times = []
        for _ in range(ROUNDS):
            times += typed_round()

        # A visit recorded with the history at its bound, then ⌘Q.
        bench("field", later, "go", deadline=30)
        until("the later page to load", lambda: loaded(later), 15)
        bench("press", "12", "q", "cmd", deadline=10, check=False)
        until("the app to quit", lambda: not running(), 30)

        saved = json.loads((FOLDER / "history.json").read_text())
        keys = {visit["key"] for visit in saved}
        urls = {visit["url"] for visit in saved}
        if len(saved) > ROOM:
            raise AssertionError(f"history.json after quit: {len(saved)} places, expected at most {ROOM}")
        missing = [key for key in OFTEN if key not in keys] + [url for url in (start, later) if url not in urls]
        if missing:
            raise AssertionError(f"history.json after quit is missing {missing}")

        print(f"ok: offers {OFTEN} for {TYPED!r} over {PLACES} seeded places; "
              f"{len(saved)} places on disk after quit, both visits kept")
        print(f"keys={len(times)} rested_ms median={statistics.median(times):.2f} "
              f"p95={percentile(times, 0.95):.2f} max={max(times):.2f}")
        print("rested_ms=" + json.dumps([round(t, 3) for t in times]))
        return 0
    except (AssertionError, subprocess.TimeoutExpired, json.JSONDecodeError) as failure:
        print(f"FAIL: {failure}", file=sys.stderr)
        return 1
    finally:
        server.shutdown()
        if os.environ.get("KEEP") != "1":
            run([REPO / "fresh.sh", "wipe"], deadline=60, check=False)


if __name__ == "__main__":
    sys.exit(main())
