#!/usr/bin/env python3
"""The scripts pages are given, read from the app's own files.

The JavaScript Escale injects lives in `.js` files in each domain's
`Scripts/` folder, shipped in Escale_Escale.bundle inside the app and read
with Bundled.script. A file the app can't find is the empty script: nothing
crashes, and the feature is simply gone from pages. So this checks, in the
assembled app copied outside the build folder by fresh.sh, that each script
is there and does its part, from what it leaves in the page:

1. A page loaded in an ordinary tab carries every script added when it was
   created: the pointing mode for hiding things (`__escaleVeil`), the swipe
   watch and its calm stylesheet, the image menu's and the middle button's
   watches, and, with passkeys not offered (a test world's default), the
   passkey object taken away. Middle-button scrolling and link destinations
   are enabled by default. Retired preferences are discarded at launch.
2. Middle-button scrolling turned off leaves the page already up; that choice
   survives restart and turning it back on restores the script. Link hover
   reports its destination and disabling the option clears it.
3. Reading mode (⌘⇧R) turns the page into its article.

Not covered here, each for its own reason: the floating video (needs a video
playing), the selection read by the right-click menu, the Chrome Web Store's button
(its site only), the popup's size (compatibility.py with the local fixture)
and the site icon probe (icon_cache.py).

Runs in its own world (ESCALE_WORLD, default "page-scripts"), launched
through fresh.sh from build/Escale.app — ./build.sh first — and wiped
afterwards unless KEEP=1. Pages come from a local server on 127.0.0.1;
nothing else is fetched. Exits non-zero, with expected and actual state for
every failed check.
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
WORLD = os.environ.get("ESCALE_WORLD", "page-scripts")
BINARY = str(REPO / "build/probe" / WORLD / "Escale.app/Contents/MacOS/Escale")
SUITE = f"com.kndpt.escale.test.{WORLD}"

PROSE = " ".join(["Plenty of words make an article worth reading, and none of them are links."] * 12)
ARTICLE = f"""<!doctype html><title>Article</title>
<nav><a href="/a">One</a> <a href="/b">Two</a></nav>
<article><h1>A story</h1><p>{PROSE}</p><p>{PROSE}</p><p>{PROSE}</p></article>"""

# What each script leaves in the page, read in one go.
LOOK = """JSON.stringify({
  veil: typeof window.__escaleVeil,
  swipe: window.__escaleSwipe === true,
  calm: !!document.getElementById('escale-calm'),
  images: window.__escaleImages === true,
  middle: window.__escaleMiddle === true,
  passkeys: !!(Object.getOwnPropertyDescriptor(window, 'PublicKeyCredential') || {}).get,
  scroll: typeof window.__escaleAutoScroll,
  reader: !!document.getElementById('escale-reader'),
})"""

failures = []


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        body = ARTICLE.encode()
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


def running():
    lines = subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True, text=True).stdout
    return [line.split(None, 1)[0] for line in lines.splitlines()
            if line.strip().split(None, 1)[-1] == BINARY]


def until(what, check, deadline=10):
    end = time.monotonic() + deadline
    while time.monotonic() < end:
        try:
            if check():
                return
        except (subprocess.TimeoutExpired, AssertionError, OSError, ValueError):
            pass
        time.sleep(0.2)
    raise AssertionError(f"timed out after {deadline}s waiting for {what}")


def active():
    """The id and address of the tab on screen."""
    for tab in json.loads(bench("--json", "tabs", deadline=5).stdout)["tabs"]:
        if tab.get("active"):
            return tab["id"], tab.get("url")
    return None, None


def look(id):
    return json.loads(json.loads(bench("--json", "eval", id, LOOK).stdout)["value"])


def settle(what, id, **expected):
    """The page, once every field named holds its value (or 5 s pass)."""
    state = {}
    end = time.monotonic() + 5
    while time.monotonic() < end:
        state = look(id)
        if all(state.get(key) == value for key, value in expected.items()):
            return
        time.sleep(0.2)
    for key, value in expected.items():
        if state.get(key) != value:
            failures.append(f"{what}: {key} expected {value!r}, found {state.get(key)!r}")


def exercise(base):
    url = f"{base}/article"
    bench("field", url, "go", deadline=30)
    until(f"{url} on screen", lambda: active()[1] == url, 15)
    id = active()[0]
    bench("wait", id, "10", deadline=15)

    # 1. Every script added with the page.
    settle("a page as it loads", id, veil="object", swipe=True, calm=True, images=True,
           middle=True, passkeys=True, scroll="function", reader=False)

    probe = json.loads(bench("--json", "probe").stdout)
    if not probe.get("showsLinks") or not probe.get("autoScroll"):
        failures.append(f"fresh page defaults expected both enabled, found {probe}")
    bench("eval", id, "document.querySelector('a').dispatchEvent(new MouseEvent('mouseover', {bubbles:true}))")
    until("hovered link destination", lambda: json.loads(bench("--json", "probe").stdout).get("linkDestination") == f"{base}/a")
    bench("ui", "links", "off")
    until("hidden link destination", lambda: json.loads(bench("--json", "probe").stdout).get("linkDestination") == "")

    # 2. Saved explicit choices survive a restart, then can be enabled again.
    bench("ui", "autoscroll", "off")
    settle("middle-button scrolling turned off", id, scroll="undefined")
    bench("press", "12", "q", "cmd")
    until("app quit", lambda: not running(), 20)
    run([REPO / "fresh.sh", "again"], deadline=60)
    until("bench after restart", lambda: bench("tabs", deadline=5, check=False).returncode == 0, 60)
    until("restored article", lambda: active()[1] == url, 15)
    id = active()[0]
    settle("saved scrolling choice", id, scroll="undefined")
    probe = json.loads(bench("--json", "probe").stdout)
    if probe.get("showsLinks") or probe.get("autoScroll"):
        failures.append("explicit disabled choices were not preserved after restart")
    bench("ui", "links", "on")
    bench("ui", "autoscroll", "on")
    settle("middle-button scrolling turned back on", id, scroll="function")

    # 3. Reading mode.
    bench("press", "15", "r", "cmd", "shift", deadline=10)
    settle("⌘⇧R", id, reader=True)


def main():
    if not (REPO / "build/Escale.app").exists():
        raise SystemExit("no build/Escale.app: run ./build.sh first")
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://localhost:{server.server_address[1]}"
    try:
        if running():
            raise AssertionError(f"world {WORLD} is already running")
        run([REPO / "fresh.sh", "wipe"], deadline=60)
        run(["defaults", "write", SUITE, "bench", "-bool", "YES"])
        run(["defaults", "write", SUITE, "welcomed", "-bool", "YES"])
        for key in ("autocorrect", "pages.120", "float.flicks", "float.away"):
            run(["defaults", "write", SUITE, key, "-bool", "YES"])
        run(["defaults", "write", f"com.kndpt.escale.probe.{WORLD}",
             "WebAutomaticSpellingCorrectionEnabled", "-bool", "YES"])
        run([REPO / "fresh.sh", "again"], deadline=60)
        until("the bench to answer", lambda: bench("tabs", deadline=5, check=False).returncode == 0, 60)
        for key in ("autocorrect", "pages.120", "float.flicks", "float.away"):
            if run(["defaults", "read", SUITE, key], check=False).returncode == 0:
                failures.append(f"retired preference remains: {key}")
        platform = f"com.kndpt.escale.probe.{WORLD}"
        value = run(["defaults", "read", platform, "WebAutomaticSpellingCorrectionEnabled"]).stdout.strip()
        if value != "0":
            failures.append(f"spelling correction expected disabled, found {value}")
        exercise(base)
    except (AssertionError, subprocess.TimeoutExpired, json.JSONDecodeError, KeyError) as failure:
        failures.append(str(failure))
    finally:
        server.shutdown()
        if os.environ.get("KEEP") != "1":
            run([REPO / "fresh.sh", "wipe"], deadline=60, check=False)
    if failures:
        for failure in failures:
            print(f"FAIL {failure}", file=sys.stderr)
        sys.exit(1)
    print("page_scripts: OK")


if __name__ == "__main__":
    main()
