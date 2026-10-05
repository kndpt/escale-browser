#!/usr/bin/env python3
"""A space left behind keeps working for itself.

Pages of a space that is no longer on screen are still alive: what they do
while it is parked belongs to that space, not to the one on screen. Three
ordinary tabs in the first space ("A") ask a local server for pages it holds
back. The file starts, keeps its tab awake, then that initiating tab is closed;
space B, with its own cookies, is opened before the server lets the work finish:

- a redirect to /final: history gets the visit, A's session (session.json)
  gets /final in place of the address that was held;
- a file: it finishes after its initiating tab closes and lands in A's
  downloads folder, not in the folder B would use;
- a failed download: its retained transfer is released and it is not added to
  the list of completed downloads;
- a dropped page connection: back in A, that tab says its page didn't load.

Cookies stay apart: /final sets one in A, which a page in B doesn't get and
a page in A does. Then a fourth page of A is let go while B is on screen, and
the app is quit from B as soon as that page has loaded, inside the session's
1.2 s debounce: A's session must hold it, and the relaunched world must bring
it back in A at /later, without asking for the held address again.

The server holds each request until the scenario releases it, so nothing
depends on how long a step takes. Runs in its own world (ESCALE_WORLD,
default "a03-parked"), launched through fresh.sh from build/Escale.app —
./build.sh first — and wiped afterwards unless KEEP=1. Nothing but the local
server on 127.0.0.1 is fetched. Exits non-zero, with expected and actual
state for every failed check, on failure.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import os
import subprocess
import sys
import threading
import time

REPO = Path(__file__).resolve().parents[2]
WORLD = os.environ.get("ESCALE_WORLD", "a03-parked")
FOLDER = Path.home() / "Library/Application Support" / f"Escale ({WORLD})"
BINARY = str(REPO / "build/probe" / WORLD / "Escale.app/Contents/MacOS/Escale")
SUITE = f"com.kndpt.escale.test.{WORLD}"
FIRST_SPACE = "00000000-0000-0000-0000-000000000001"
A_DOWNLOADS = FOLDER / "A downloads"
B_DOWNLOADS = FOLDER / "Downloads"  # the test run's folder in Settings (Prefs.downloads)
FILE_NAME = "a03-file.bin"
FAILED_FILE_NAME = "a03-failed.bin"
FILE_BODY = b"A03 " * 1024

# What the server was asked for, and the moments it lets held work go.
served = []
served_lock = threading.Lock()
first_release = threading.Event()
download_started = threading.Event()
download_release = threading.Event()
failed_download_started = threading.Event()
failed_download_release = threading.Event()
second_release = threading.Event()


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        with served_lock:
            served.append(path)
        if path in ("/hold/final", "/hold/fail"):
            first_release.wait(120)
        elif path == "/hold/later":
            second_release.wait(120)

        if path in ("/hold/final", "/hold/later"):
            self.send_response(302)
            self.send_header("Location", path.replace("/hold", ""))
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif path == "/hold/file":
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Disposition", f'attachment; filename="{FILE_NAME}"')
            self.send_header("Content-Length", str(len(FILE_BODY)))
            self.end_headers()
            self.wfile.write(FILE_BODY[:4])
            self.wfile.flush()
            download_started.set()
            download_release.wait(120)
            self.wfile.write(FILE_BODY[4:])
        elif path == "/hold/download-fail":
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Disposition", f'attachment; filename="{FAILED_FILE_NAME}"')
            self.send_header("Content-Length", str(len(FILE_BODY)))
            self.end_headers()
            self.wfile.write(FILE_BODY[:4])
            self.wfile.flush()
            failed_download_started.set()
            failed_download_release.wait(120)
            # Ending before Content-Length is a real transfer failure after a
            # destination was chosen, not a page load that never downloaded.
            self.close_connection = True
        elif path == "/hold/fail":
            # No answer at all: the connection just ends.
            self.close_connection = True
        elif path == "/final":
            self.page("A03 final", "final", cookie="a03=space-a; Path=/")
        elif path == "/later":
            # The picture is asked for once the document is in: the server
            # hearing it means the tab is at /later.
            self.page("A03 later", '<img src="/beacon">')
        elif path == "/cookie":
            self.page("A03 cookie", f"cookie=[{self.headers.get('Cookie', '')}]")
        else:
            self.send_response(204)
            self.end_headers()

    def page(self, title, body, cookie=None):
        data = f"<title>{title}</title><p>{body}</p>".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


def asked(path):
    with served_lock:
        return path in served


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


def running():
    lines = subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True, text=True).stdout
    return [line.split(None, 1)[0] for line in lines.splitlines()
            if line.strip().split(None, 1)[-1] == BINARY]


def wait_for(check, deadline):
    """Whether check() came true before the deadline."""
    end = time.monotonic() + deadline
    while time.monotonic() < end:
        try:
            if check():
                return True
        except (subprocess.TimeoutExpired, AssertionError, OSError, ValueError, KeyError):
            pass
        time.sleep(0.2)
    return False


def until(what, check, deadline):
    if not wait_for(check, deadline):
        raise AssertionError(f"timed out after {deadline}s waiting for {what}")


def tabs():
    """The row on screen, as (id, title, url, active) from `bench tabs`."""
    rows = []
    for line in bench("tabs", deadline=5).stdout.splitlines():
        mark, rest = line[:1], line[2:]
        parts = rest.split("  ")
        if len(parts) < 3:
            continue
        url = parts[-1].removesuffix(" …").removesuffix(" z")
        rows.append((parts[0], "  ".join(parts[1:-1]), url, mark == "●"))
    return rows


def tab_at(url):
    return next((row for row in tabs() if row[2] == url), None)


def space():
    return json.loads(bench("space", deadline=10).stdout)


def probe():
    return json.loads(bench("probe", deadline=10).stdout)


def saved(name):
    return json.loads((FOLDER / name).read_text())


def session_urls():
    return [tab["url"] for tab in saved("session.json")["tabs"]]


def history_urls():
    return [visit["url"] for visit in saved("history.json")]


def page_text(url):
    """Open url in a new ordinary tab of the space on screen; its text once loaded."""
    bench("bookmark", url, "new", deadline=30)
    until(f"{url} to load", lambda: (tab_at(url) or ("", "", "", False))[1].startswith("A03"), 10)
    return bench("text", tab_at(url)[0], deadline=10).stdout


def launch():
    if running():
        raise AssertionError(f"world {WORLD} is already running")
    run([REPO / "fresh.sh", "again"], deadline=60)
    until("the bench to answer", lambda: bench("tabs", deadline=5, check=False).returncode == 0, 60)


def main():
    if not (REPO / "build/Escale.app").exists():
        raise AssertionError("no build/Escale.app: run ./build.sh first")
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    failures = []

    def check(what, ok, found):
        if not ok:
            failures.append(f"{what}; found {found}")

    try:
        run([REPO / "fresh.sh", "wipe"], deadline=60)
        run(["defaults", "write", SUITE, "bench", "-bool", "YES"])
        # A synthetic list of spaces: the first one sends its downloads to a
        # folder of its own.
        A_DOWNLOADS.mkdir(parents=True)
        (FOLDER / "spaces.json").write_text(json.dumps(
            [{"id": FIRST_SPACE, "name": "A", "colour": 0, "downloads": str(A_DOWNLOADS)}]))
        launch()
        bench("ui", "spaces", "on")

        # Space A: two pages the server is holding back, then a download whose
        # first bytes arrive while the initiating tab is still present.
        for path in ("/hold/fail", "/hold/final"):
            bench("bookmark", base + path, "new", deadline=30)
            until(f"the server to be asked for {path}", lambda: asked(path), 10)
        failing = tab_at(base + "/hold/fail")
        if failing is None:
            raise AssertionError(f"no tab at {base}/hold/fail in {tabs()}")
        held_file = base + "/hold/file"
        bench("bookmark", held_file, "new", deadline=30)
        until("the file download to start", download_started.is_set, 10)
        file_tab = tab_at(held_file)
        if file_tab is None:
            raise AssertionError(f"no initiating tab at {held_file} in {tabs()}")
        failed_file = base + "/hold/download-fail"
        bench("bookmark", failed_file, "new", deadline=30)
        until("the failing download to start", failed_download_started.is_set, 10)
        failed_download_tab = tab_at(failed_file)
        if failed_download_tab is None:
            raise AssertionError(f"no initiating tab at {failed_file} in {tabs()}")

        # The transfers, not the row's current selection, keep their pages alive.
        bench("select", failing[0], deadline=10)
        def download_reason(tab):
            return json.loads(bench("sleep", tab[0], deadline=10).stdout).get("said")
        until("the completing transfer to keep its page awake",
              lambda: download_reason(file_tab) == "downloading", 10)
        until("the failing transfer to keep its page awake",
              lambda: download_reason(failed_download_tab) == "downloading", 10)
        check("two transfers retained while active", probe()["activeDownloads"] == 2,
              probe()["activeDownloads"])

        # Closing the page must not release the WKDownload retained by its own
        # owner. The server keeps the rest of the bytes back until space B is
        # showing, so completion proves both lifetime and origin.
        bench("select", file_tab[0], deadline=10)
        bench("press", "13", "w", "cmd", deadline=10)
        until("the initiating tab to close", lambda: tab_at(held_file) is None, 10)

        # Space B, signed out, on screen; then A's pages are let go.
        bench("space", "new", "B", "fresh")
        until("space B on screen", lambda: space()["current"] == "B", 10)
        first_release.set()
        download_release.set()
        failed_download_release.set()

        final, download = base + "/final", A_DOWNLOADS / FILE_NAME
        wait_for(lambda: final in history_urls() and final in session_urls()
                 and download.exists() and download.stat().st_size == len(FILE_BODY), 15)
        check(f"history.json holds {final}", wait_for(lambda: final in history_urls(), 0.5),
              (FOLDER / "history.json").exists() and history_urls())
        check(f"A's session.json holds {final}, not the held address",
              wait_for(lambda: final in session_urls() and base + "/hold/final" not in session_urls(), 0.5),
              session_urls())
        check(f"{FILE_NAME} in A's folder", download.exists() and download.stat().st_size == len(FILE_BODY),
              sorted(p.name for p in A_DOWNLOADS.iterdir()))
        check(f"no {FILE_NAME} in the folder B uses", not (B_DOWNLOADS / FILE_NAME).exists(),
              sorted(p.name for p in B_DOWNLOADS.iterdir()) if B_DOWNLOADS.exists() else [])
        check("completed and failed transfers released; B keeps no trace of A's downloads",
              wait_for(lambda: probe()["activeDownloads"] == 0, 10)
              and not probe()["keptDownloads"],
              {"active": probe()["activeDownloads"],
               "kept": probe()["keptDownloads"]})
        check("A's pages kept to A's row", len(tabs()) == 1, tabs())
        text = page_text(base + "/cookie")
        check("B's page has none of A's cookies", "a03=space-a" not in text, text.strip())

        # Back in A: the failure is there, the redirect landed.
        bench("space", "go", "1")
        until("space A on screen", lambda: space()["current"] == "A", 10)
        check("A keeps only its completed download",
              any(name.startswith("a03-file") for name in probe()["keptDownloads"])
              and not any(name.startswith("a03-failed") for name in probe()["keptDownloads"]),
              probe()["keptDownloads"])
        waited = json.loads(bench("wait", failing[0], "5", deadline=15).stdout)
        check("the dropped page's tab says it didn't load", bool(waited.get("failure")), waited)
        check(f"a tab at {final} titled “A03 final”", (tab_at(final) or (0, ""))[1] == "A03 final", tabs())
        text = page_text(base + "/cookie")
        check("A's page has A's cookie", "a03=space-a" in text, text.strip())

        # A fourth page of A let go from B, and ⌘Q from B as soon as it is in.
        bench("bookmark", base + "/hold/later", "new", deadline=30)
        until("the server to be asked for /hold/later", lambda: asked("/hold/later"), 10)
        bench("space", "go", "2")
        until("space B on screen", lambda: space()["current"] == "B", 10)
        second_release.set()
        until("the later page to load in A", lambda: asked("/beacon"), 15)
        bench("press", "12", "q", "cmd", deadline=10, check=False)
        until("the app to quit", lambda: not running(), 30)

        later = base + "/later"
        check(f"A's session.json after quitting from B holds {later}",
              later in session_urls() and base + "/hold/later" not in session_urls(), session_urls())
        check(f"history.json after quitting holds {later}", later in history_urls(), history_urls())

        launch()
        check("the world comes back in B", space()["current"] == "B", space()["current"])
        bench("space", "go", "1")
        until("space A on screen", lambda: space()["current"] == "A", 10)
        # Its tab comes back at /later itself: had the session kept the held
        # address, waking it would ask the server for that again.
        check(f"A's restored row has {later}", wait_for(lambda: tab_at(later) is not None, 10), tabs())
        with served_lock:
            again = served.count("/hold/later")
        check("the held address not asked for again after the relaunch", again == 1, f"{again} requests")

        if failures:
            raise AssertionError("\n  " + "\n  ".join(failures))
        print("ok: a parked space's redirect, download, failure and session stayed its own, "
              "through a quit from another space and a relaunch")
        return 0
    except (AssertionError, subprocess.TimeoutExpired) as failure:
        if failures and not str(failure).startswith("\n"):
            failure = f"{failure}\n  " + "\n  ".join(failures)
        print(f"FAIL: {failure}", file=sys.stderr)
        return 1
    finally:
        first_release.set()
        download_release.set()
        failed_download_release.set()
        second_release.set()
        server.shutdown()
        if os.environ.get("KEEP") != "1":
            run([REPO / "fresh.sh", "wipe"], deadline=60, check=False)


if __name__ == "__main__":
    sys.exit(main())
