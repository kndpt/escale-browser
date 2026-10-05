#!/usr/bin/env python3
"""What Escale takes from outside WebKit's public API still works here.

docs/COMPATIBILITY.md lists every private WebKit name Escale asks for and
every shim it adds for extensions. Each is asked for before it is used and
has a fallback, so a macOS that drops one breaks nothing loudly: the feature
just goes quiet. This scenario is how a new macOS or Safari is checked. It
prints the macOS and Safari it ran on.

Private names, on an ordinary tab of a local page:

- `_setDeveloperExtrasEnabled:` (Tab.inspector): the page's WebKit says its
  developer extras are on (`probe.inspector`, read through
  `_developerExtrasEnabled`).
- `_inspector`, `show`, `close`, `webView`, `InspectorFrontendHost` and
  `WKInspectorWKWebView` (Inspector.swift): ⌥⌘I docks the Web Inspector at
  the right, which the page sees as a narrower viewport; ⌥⌘I again puts it
  away and the page has its width back.
- `connect`, `hide` and `inspectorWebView` on `_WKInspector`, and the Web
  Inspector frontend's `WI.*` network model (Calls.swift, calls.js): the API
  Calls panel collects without showing the inspector, lists a fetch, and
  ⌥⌘I docks then hides the inspector on that session without ending it.
- `_webProcessIdentifier` (bench crash): the page's process is named and
  ended, and the tab on screen comes back on its page.
- The user agent names the Safari installed on this Mac (Web.userAgentName).

A local unpacked extension (fixtures/shim-extension, which asks for
bookmarks and nothing else), on macOS 15.4 or later:

- it installs and loads with no error;
- `chrome.bookmarks.getTree()`, filled in by ExtensionShims, answers with
  the bookmarks Escale has (seeded by `bench shelf seed`);
- `chrome.history.search()` is refused, since the manifest never asked for
  history, and `chrome.tabGroups.get()` says Escale has none: an explicit
  unsupported answer, not a simulated success;
- its popup (ExtensionPopup, sized when WebKit reports the document built
  through `_webView:navigationDidFinishDocumentLoad:`) comes to the size its
  page asks for, 320 × 180. The time it takes is printed for information,
  not a pass condition beyond the popup's own 5 s reveal.
  The popover is transient: it closes as soon as another app is used. The
  world's app is brought to the front first (by its pid, never launching
  anything), and a popup that closes anyway, because someone used the Mac
  meanwhile, is reported as inconclusive with the app then in front, not as
  a compatibility failure.

Not covered here: `_isPlayingAudio` and the first-frame hold, listed as gaps
in COMPATIBILITY.md, and the passkey public-suffix test, which has a Swift
test (Tests/EscaleTests/PasskeysTests.swift).

Runs in its own world (ESCALE_WORLD, default "a10-compat"), launched through
fresh.sh from build/Escale.app — ./build.sh first — and wiped afterwards
unless KEEP=1. Pages come from a local server on 127.0.0.1; nothing else is
fetched. Exits non-zero, with expected and actual state for every failed check.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import os
import platform
import plistlib
import re
import socket
import subprocess
import sys
import threading
import time

REPO = Path(__file__).resolve().parents[2]
WORLD = os.environ.get("ESCALE_WORLD", "a10-compat")
FOLDER = Path.home() / "Library/Application Support" / f"Escale ({WORLD})"
BINARY = str(REPO / "build/probe" / WORLD / "Escale.app/Contents/MacOS/Escale")
SUITE = f"com.kndpt.escale.test.{WORLD}"
FIXTURE = (Path(os.environ["ESCALE_EXTENSION_FIXTURE"])
           if os.environ.get("ESCALE_EXTENSION_FIXTURE")
           else REPO / "Tests/Bench/fixtures/shim-extension")
# What the fixture's popup page asks for.
POPUP = [320, 180]
# ExtensionPopup shows a popup after 5 s whatever its page did.
REVEAL = 5.0
# What the bench answers once the popup is gone.
CLOSED = "no popup open for that extension"


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"<title>A10 page</title><h1>A10</h1>"
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


def ask(verb, quiet=False, **fields):
    """One request straight to the socket. quiet: an error is returned, not raised."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(30)
        s.connect(str(FOLDER / "bench.sock"))
        s.sendall((json.dumps({"do": verb, **fields}) + "\n").encode())
        chunks = []
        while chunk := s.recv(1 << 16):
            chunks.append(chunk)
    reply = json.loads(b"".join(chunks).split(b"\n", 1)[0])
    if "error" in reply and not quiet:
        raise AssertionError(f"{verb} {fields}: {reply['error']}")
    return reply


def tabs():
    return ask("tabs")["tabs"]


def tab(id):
    return next((t for t in tabs() if t["id"] == id), None)


def at(url):
    return next((t for t in tabs() if t["url"] == url), None)


def js(id, script):
    return ask("eval", id=id, js=script)["value"]


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


def safari():
    for path in ("/System/Cryptexes/App/System/Applications/Safari.app", "/Applications/Safari.app"):
        try:
            with open(f"{path}/Contents/Info.plist", "rb") as f:
                return plistlib.load(f)["CFBundleShortVersionString"]
        except (OSError, KeyError, plistlib.InvalidFileException):
            continue
    return None


def frontmost():
    """The app in front, as (name, pid): a transient popover closes as soon
    as anything outside it is used, another app included, so a popup that
    is gone is read against this. The pid tells this world's Escale from
    another one."""
    front = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True).stdout.strip()
    info = subprocess.run(["lsappinfo", "info", front], capture_output=True, text=True).stdout
    name = re.search(r'"([^"]*)"', info)
    pid = re.search(r"\bpid = (\d+)", info)
    return (name.group(1) if name else front, pid.group(1) if pid else None)


def bring_forward(pid):
    """The world's own process to the front, as a click on its window would.
    By pid only: nothing is launched if it has gone."""
    script = (f"ObjC.import('AppKit'); const a = $.NSRunningApplication.runningApplicationWithProcessIdentifier({pid});"
              " a.isNil() ? 'gone' : String(a.activateWithOptions(0))")
    return subprocess.run(["osascript", "-l", "JavaScript", "-e", script],
                          capture_output=True, text=True, timeout=10).stdout.strip()


def settled(id, url):
    t = tab(id)
    return t["view"] == url and not t["loading"] and not t["hollow"]


def later(id, script, deadline=5):
    """A promise's outcome, from a page the bench can only ask synchronously."""
    js(id, f"window.__a10 = undefined; Promise.resolve().then(() => {script})"
           ".then(v => window.__a10 = {value: v}, e => window.__a10 = {error: String(e && e.message || e)}); 0")
    until(f"{script} to settle", lambda: js(id, "JSON.stringify(window.__a10 || null)") != "null", deadline)
    return json.loads(js(id, "JSON.stringify(window.__a10)"))


def main():
    if not (REPO / "build/Escale.app").exists():
        raise AssertionError("no build/Escale.app: run ./build.sh first")
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    page = f"http://127.0.0.1:{server.server_address[1]}/"
    failures = []
    notes = []
    inconclusive = []

    def check(what, ok, found):
        print(f"  {'ok  ' if ok else 'FAIL'} {what}")
        if not ok:
            failures.append(f"{what}; found {found}")

    macos = platform.mac_ver()[0]
    build = subprocess.run(["sw_vers", "-buildVersion"], capture_output=True, text=True).stdout.strip()
    print(f"macOS {macos} ({build}), Safari {safari()}, {platform.machine()}")

    try:
        run([REPO / "fresh.sh", "wipe"], deadline=60)
        run(["defaults", "write", SUITE, "bench", "-bool", "YES"])
        launch()

        bench("bookmark", page, "new")
        until(f"{page} to load", lambda: at(page) and not at(page)["loading"], 10)
        id = at(page)["id"]
        ask("select", id=id)

        # Developer extras, as each page's WebKit has them.
        probe = ask("probe")
        check("developer extras on in the page (_setDeveloperExtrasEnabled:)",
              probe.get("inspector") == [True], probe.get("inspector"))
        # The Web Inspector, docked at the right: the page gets narrower.
        wide = js(id, "innerWidth")
        tall = js(id, "innerHeight")
        ask("press", code=34, chars="i", mods=["cmd", "opt"])
        docked = wait_for(lambda: js(id, "innerWidth") < wide - 100, 5)
        check("⌥⌘I docks the Web Inspector beside the page (_inspector, show)", docked,
              f"innerWidth {wide} → {js(id, 'innerWidth')}; innerHeight {tall} → {js(id, 'innerHeight')}")
        second = page + "?second"
        bench("bookmark", second, "new")
        until("the next tab to load", lambda: at(second) and not at(second)["loading"], 10)
        second_id = at(second)["id"]
        check("the right-docked inspector follows a new tab",
              wait_for(lambda: js(second_id, "innerWidth") < wide - 100, 5),
              f"innerWidth {js(second_id, 'innerWidth')}, was {wide}")
        ask("press", code=17, chars="t", mods=["cmd"])
        ask("select", id=second_id)
        check("the inspector returns after a blank tab",
              wait_for(lambda: js(second_id, "innerWidth") < wide - 100, 5),
              f"innerWidth {js(second_id, 'innerWidth')}, was {wide}")
        ask("press", code=34, chars="i", mods=["cmd", "opt"])
        check("⌥⌘I again puts it away (close)",
              wait_for(lambda: js(second_id, "innerWidth") == wide, 5),
              f"innerWidth {js(second_id, 'innerWidth')}, was {wide}")
        ask("select", id=id)

        # The API Calls panel (Calls.swift) on the same session: `connect`
        # loads the frontend unseen, `inspectorWebView` gives its page, the
        # `WI.*` network model reports a fetch, and ⌥⌘I while it collects
        # shows then hides the inspector (`hide`) without ending it.
        ask("calls", action="open")
        wait_for(lambda: ask("calls")["phase"]["name"] in ("collecting", "stopped"), 10)
        state = ask("calls")
        check("API Calls connects WebKit's inspector unseen (connect, inspectorWebView, WI.*)",
              state["phase"]["name"] == "collecting" and state["inspection"]["visible"] is False, state["phase"])
        js(id, "fetch('/?compat-call'); true")
        check("…and lists the page's fetch from WI.Resource events",
              wait_for(lambda: any("compat-call" in row["url"] for row in ask("calls")["rows"]), 5), ask("calls")["count"])
        beside = js(id, "innerWidth")
        ask("press", code=34, chars="i", mods=["cmd", "opt"])
        # Docked when the page is wide enough beside the panel, otherwise in
        # WebKit's own window (the same rule as a narrow split pane).
        check("⌥⌘I shows the inspector on that loaded frontend (show)",
              wait_for(lambda: ask("calls")["inspector"] != "" and ask("calls")["inspection"]["visible"] is True, 5),
              f"innerWidth {js(id, 'innerWidth')}, was {beside}; {ask('calls')['inspection']}")
        notes.append(f"API Calls + Web Inspector: page {beside} → {js(id, 'innerWidth')} pt "
                     + ("(docked)" if js(id, "innerWidth") < beside - 100 else "(WebKit's own window: page too narrow to dock)"))
        ask("press", code=34, chars="i", mods=["cmd", "opt"])
        check("⌥⌘I again hides it and the collection goes on (hide)",
              wait_for(lambda: js(id, "innerWidth") == beside and ask("calls")["inspection"]["connected"] is True
                       and ask("calls")["phase"]["name"] == "collecting", 5), ask("calls")["inspection"])
        ask("calls", action="close")
        check("closing API Calls ends the session (close)",
              wait_for(lambda: ask("calls")["inspection"]["session"] is False and js(id, "innerWidth") == wide, 5),
              ask("calls")["inspection"])

        # The user agent names the Safari this Mac has.
        agent = js(id, "navigator.userAgent")
        wanted = f"Version/{safari()} Safari/605.1.15"
        check(f"the user agent says {wanted}", agent.endswith(wanted), agent)

        # The page's process, named by WebKit, ended; the tab on screen comes back.
        crashed = ask("crash", id=id, quiet=True)
        check("WebKit names the page's process (_webProcessIdentifier)", crashed.get("crashed", 0) > 0, crashed)
        check("…and the tab on screen comes back on its page",
              wait_for(lambda: settled(id, page) and js(id, "document.title") == "A10 page", 10), tab(id))

        # The extension fixture: WebKit's extension engine starts at macOS 15.4.
        major, minor = (int(x) for x in (macos.split(".") + ["0"])[:2])
        if (major, minor) < (15, 4):
            notes.append(f"macOS {macos}: no extension engine, extension checks skipped")
        else:
            ask("ext-answer", answer="yes")
            ask("ext-folder", path=str(FIXTURE), yes=True)

            def fixture():
                return next((e for e in ask("extensions")["extensions"] if e.get("source") == str(FIXTURE)), None)

            until("the fixture to load", lambda: fixture() and fixture()["loaded"], 20)
            ext = fixture()
            check("the fixture loads with no error", ext["loaded"] and ext["errors"] == [], ext)
            ask("shelf", seed=True)
            page_id = ask("ext-page", id=ext["id"], path="page.html")["id"]
            until("the fixture's page to load", lambda: not tab(page_id)["loading"], 10)
            tree = later(page_id, "chrome.bookmarks.getTree()")
            titles = [c.get("title") for c in tree.get("value", [{}])[0].get("children", [{}])[0].get("children", [])]
            check("chrome.bookmarks.getTree() answers with Escale's bookmarks (shim)",
                  "WebKit" in titles and "Swift" in titles, tree)
            history = later(page_id, "chrome.history.search({text: ''})")
            check("chrome.history.search() refused: the manifest never asked for history",
                  "never asked for" in history.get("error", ""), history)
            groups = later(page_id, "chrome.tabGroups.get(1)")
            check("chrome.tabGroups.get() answers that there are none, not a made-up group",
                  "no tab groups" in groups.get("error", ""), groups)

            pids = running()
            if len(pids) != 1 or bring_forward(pids[0]) != "true":
                raise AssertionError(f"could not bring world {WORLD} to the front (processes {pids})")
            until("the world's app to be in front", lambda: frontmost()[1] == pids[0], 5)
            started = time.monotonic()
            ask("ext-press", id=ext["id"], yes=True)

            def popup():
                """Its page's size, or what the bench said instead (no popup open)."""
                reply = ask("ext-popup", id=ext["id"], js="JSON.stringify([innerWidth, innerHeight])", quiet=True)
                return json.loads(reply["value"]) if "value" in reply else reply.get("error")

            sized = wait_for(lambda: popup() in (POPUP, CLOSED), REVEAL + 1, every=0.05) and popup() == POPUP
            took = time.monotonic() - started
            if not sized and popup() == CLOSED:
                inconclusive.append("the popup closed before it could be measured (in front: %s, pid %s): " % frontmost() +
                                    "leave the Mac alone while the scenario runs")
            else:
                check(f"the popup comes to the size its page asks for, {POPUP[0]} × {POPUP[1]}", sized, popup())
            if sized:
                notes.append(f"popup at {POPUP[0]} × {POPUP[1]} after {took:.2f} s")
            ask("ext-remove", id=ext["id"], yes=True)
            check("the fixture is removed",
                  wait_for(lambda: fixture() is None, 10), fixture())

        for note in notes:
            print(f"  note {note}")
        if inconclusive:
            failures.append("inconclusive, " + "; ".join(inconclusive))
        if failures:
            raise AssertionError("\n  " + "\n  ".join(failures))
        print("ok: the private WebKit names and the extension shim checked here work on this macOS")
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
