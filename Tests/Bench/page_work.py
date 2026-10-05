#!/usr/bin/env python3
"""The work Escale's own scripts do in a page stays with what it serves.

Every page gets a few scripts from Escale: the reading bar's scroll reporter,
the forms script (drafts, typing, full screen, sign-ins) and, when turned on,
middle-button scrolling. They must not keep working for something no one
asked for, and turning a setting off must stop its work in the page already
up, not only in the next one:

- a page whose DOM changes all the time, where no password went out, is not
  searched for sign-in boxes on each change;
- after a password goes out, the page is watched for its sign-in to go away,
  at a bounded rate; once it has gone (and the offer to keep the password is
  up) the watch stops;
- scrolling tells the browser where the page is only while the reading bar is
  shown, and says nothing about the caret unless it is in a sign-in box, whose
  suggestions have to follow it;
- with passwords neither saved nor filled, a password sent is not reported
  and nothing looks for sign-in boxes — on the page already up, on the next
  one, and again once saving is back on; a list of accounts already hanging
  from a sign-in box goes when filling is turned off;
- middle-button scrolling under way stops when the setting is turned off,
  leaving no frame loop behind, and works again when it is turned back on;
- what does not change: a draft typed with real keys keeps its tab awake, the
  caret in a text box keeps ⌘← for the text, and a sign-in sent and done in
  place still brings the offer to keep the password.

The page counts, from its own head, what the injected scripts do: messages
posted to Escale by handler and kind, searches for password boxes (the
`input[type="password"]` query the forms script makes), geometry reads,
MutationObserver callbacks and animation frames asked for. The scripts are
the ones the app injects; nothing is copied here. Real input (`key`, `tap`,
`press`) where the behaviour depends on it; the middle button's own press is
dispatched in the page — its handling is not under test, its stop is.

CPU time of the app and of the WebKit processes it is responsible for
(`responsibility_get_pid_responsible_for_pid`, not the parent pid) is printed
for each timed window as a diagnostic; it is not asserted.

Runs in its own world (ESCALE_WORLD, default "a08-page-work"), launched
through fresh.sh from build/Escale.app — ./build.sh first — and wiped
afterwards unless KEEP=1. Pages come from a local server on 127.0.0.1.
`ESCALE_SKIP_KEYCHAIN=1` omits only the account-list assertion when the macOS
`security` process is unavailable; the page-side saving/filling assertions run.
Exits non-zero, with expected and actual state for every failed check.
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
WORLD = os.environ.get("ESCALE_WORLD", "a08-page-work")
FOLDER = Path.home() / "Library/Application Support" / f"Escale ({WORLD})"
BINARY = str(REPO / "build/probe" / WORLD / "Escale.app/Contents/MacOS/Escale")
SUITE = f"com.kndpt.escale.test.{WORLD}"
SKIP_KEYCHAIN = os.environ.get("ESCALE_SKIP_KEYCHAIN") == "1"

# Counts kept by the page, from before any script of Escale's that runs at the
# end of the document. `reset()` starts a window; `churn` changes the DOM
# every `every` ms; `glide` scrolls by script every 16 ms.
COUNTERS = """<script>
(function () {
  var zero = function () {
    return {post: {}, kinds: {}, looks: 0, rects: 0, observed: 0, frames: 0, followed: 0};
  };
  window.counts = zero();
  window.reset = function () { window.counts = zero(); return true; };
  var handlers = window.webkit && window.webkit.messageHandlers;
  var names = ['escaleScroll', 'escaleForms', 'escaleVeil', 'escaleImage', 'escaleMiddle', 'escaleStore'];
  var real = Object.getPrototypeOf(handlers.escaleScroll).postMessage;
  Object.getPrototypeOf(handlers.escaleScroll).postMessage = function (message) {
    var self = this, name = 'other';
    names.forEach(function (n) { try { if (handlers[n] === self) name = n; } catch (e) {} });
    counts.post[name] = (counts.post[name] || 0) + 1;
    if (message && message.kind) {
      counts.kinds[message.kind] = (counts.kinds[message.kind] || 0) + 1;
      if (message.kind === 'focus') {
        counts.typing = message.typing;
        if (message.rect) counts.followed++;
      }
    }
    return real.apply(this, arguments);
  };
  var query = Document.prototype.querySelectorAll;
  Document.prototype.querySelectorAll = function (selector) {
    if (selector === 'input[type="password"]') counts.looks++;
    return query.apply(this, arguments);
  };
  var rect = Element.prototype.getBoundingClientRect;
  Element.prototype.getBoundingClientRect = function () { counts.rects++; return rect.apply(this, arguments); };
  var Observer = window.MutationObserver;
  window.MutationObserver = function (callback) {
    return new Observer(function () { counts.observed++; return callback.apply(this, arguments); });
  };
  window.MutationObserver.prototype = Observer.prototype;
  var frame = window.requestAnimationFrame;
  window.requestAnimationFrame = function (f) { counts.frames++; return frame.call(window, f); };
  window.churn = function (ms, every) {
    var n = 0;
    var timer = setInterval(function () {
      var line = document.createElement('div');
      line.textContent = 'line ' + (n++);
      document.getElementById('live').appendChild(line);
      var live = document.getElementById('live');
      if (live.childNodes.length > 20) live.removeChild(live.firstChild);
    }, every || 20);
    setTimeout(function () { clearInterval(timer); }, ms);
    return true;
  };
  window.glide = function (ms) {
    var end = performance.now() + ms;
    var timer = setInterval(function () {
      window.scrollBy(0, 5);
      if (performance.now() > end) clearInterval(timer);
    }, 16);
    return true;
  };
})();
</script>"""

PAGES = {
    "/work": "<title>A08 work</title>" + COUNTERS + """
<body style="height:30000px;margin:0">
<form id="f" onsubmit="return false" style="padding:20px">
  <input id="u" name="u"> <input id="p" type="password"> <button id="go" type="button">Sign in</button>
</form>
<textarea id="t" style="margin:20px"></textarea>
<div id="live"></div>
</body>""",
    "/typing": "<title>A08 typing</title>" + COUNTERS + """
<body style="margin:0"><textarea id="t" style="margin:40px;width:300px;height:80px"></textarea>
<p id="away" style="height:200px">elsewhere</p></body>""",
    "/other": "<title>A08 other</title><h1>other</h1>",
}


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        body = PAGES.get(self.path.split("?")[0], "<title>A08 missing</title>").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
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


def js(id, script):
    return ask("eval", id=id, js=script)["value"]


def counts(id):
    return json.loads(js(id, "JSON.stringify(counts)"))


def tabs():
    return ask("tabs")["tabs"]


def tab(id):
    return next((t for t in tabs() if t["id"] == id), None)


def at(url):
    return next((t for t in tabs() if t["url"] == url), None)


def running():
    lines = subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True, text=True).stdout
    return [int(line.split(None, 1)[0]) for line in lines.splitlines()
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


# CPU time, from the kernel's own accounting of each process.
class Usage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16), ("user", ctypes.c_uint64), ("system", ctypes.c_uint64),
                ("idle_wakeups", ctypes.c_uint64), ("interrupt_wakeups", ctypes.c_uint64),
                ("pageins", ctypes.c_uint64), ("wired", ctypes.c_uint64), ("resident", ctypes.c_uint64),
                ("footprint", ctypes.c_uint64), ("start", ctypes.c_uint64), ("exit", ctypes.c_uint64)]


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


LIBC = ctypes.CDLL(None)
LIBPROC = ctypes.CDLL("/usr/lib/libproc.dylib")
LIBC.responsibility_get_pid_responsible_for_pid.argtypes = [ctypes.c_int]
LIBC.responsibility_get_pid_responsible_for_pid.restype = ctypes.c_int
TIMEBASE = Timebase()
LIBC.mach_timebase_info(ctypes.byref(TIMEBASE))


def cpu_ms(pid):
    """User + system CPU of pid, in ms, or None once it is gone."""
    usage = Usage()
    if LIBPROC.proc_pid_rusage(pid, 0, ctypes.byref(usage)) != 0:
        return None
    return (usage.user + usage.system) * TIMEBASE.numer / TIMEBASE.denom / 1e6


def webkit(app):
    """The WebKit processes the app is responsible for, by kind."""
    lines = subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True, text=True).stdout
    found = {}
    for line in lines.splitlines():
        pid, comm = line.split(None, 1)
        if "com.apple.WebKit." in comm and LIBC.responsibility_get_pid_responsible_for_pid(int(pid)) == app:
            found.setdefault(comm.rsplit(".", 1)[-1], []).append(int(pid))
    return found


def cpu(app):
    """CPU so far of the app and of its WebContent processes, in ms."""
    pages = webkit(app).get("WebContent", [])
    return {"app": cpu_ms(app), "pages": sum(cpu_ms(p) or 0 for p in pages)}


def main():
    if not (REPO / "build/Escale.app").exists():
        raise AssertionError("no build/Escale.app: run ./build.sh first")
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    work, typing, other = f"{base}/work", f"{base}/typing", f"{base}/other"
    failures = []
    timed = {}

    def check(what, ok, found):
        if not ok:
            failures.append(f"{what}; found {found}")

    def load(id, url):
        """The tab on url, loaded, with the counters of a fresh document."""
        ask("go", id=id, url=url)
        until(f"{url} to load", lambda: tab(id)["view"] == url and not tab(id)["loading"]
              and js(id, "typeof counts") == "object", 10)

    def measure(id, name, script, seconds):
        """Counts and CPU over one timed window, after `script` starts it."""
        js(id, "reset()")
        app = running()[0]
        before = cpu(app)
        js(id, script)
        time.sleep(seconds + 0.4)
        after = cpu(app)
        found = counts(id)
        timed[name] = {"counts": found, "cpu_ms": {k: round(after[k] - before[k], 1) for k in after}}
        return found

    def sent(id):
        """A name and password typed with real keys, and the button pressed with a real click."""
        js(id, "document.getElementById('u').value = ''; document.getElementById('p').value = ''; "
               "document.getElementById('u').focus(); true")
        ask("key", id=id, text="someone")
        js(id, "document.getElementById('p').focus(); true")
        ask("key", id=id, text="hunter22")
        ask("tap", id=id, selector="#go")

    try:
        run([REPO / "fresh.sh", "wipe"], deadline=60)
        run(["defaults", "write", SUITE, "bench", "-bool", "YES"])
        run([REPO / "fresh.sh", "again"], deadline=60)
        until("the bench to answer", lambda: bench("tabs", deadline=5, check=False).returncode == 0, 60)
        app = running()[0]

        bench("bookmark", work, "new", deadline=30)
        until(f"{work} to load", lambda: at(work) and not at(work)["loading"], 10)
        id = at(work)["id"]
        ask("select", id=id)
        until("the counters", lambda: js(id, "typeof counts") == "object", 10)

        # 1. A page that changes all the time; no password went out.
        found = measure(id, "churn, nothing sent", "churn(4000, 20)", 4)
        check("a changing page where no password went out is not searched for sign-ins (≤ 2 looks in 4 s)",
              found["looks"] <= 2, found)

        # 2. Scrolling, reading bar on, caret in no sign-in box.
        found = measure(id, "scroll, reading bar on", "glide(3000)", 3)
        check("the reading bar hears where the page is while it scrolls (> 30 reports in 3 s)",
              found["post"].get("escaleScroll", 0) > 30, found)
        check("…and nothing is said about the caret, which is in no sign-in box",
              found["kinds"].get("focus", 0) == 0 and found["looks"] == 0, found)

        # 3. The reading bar off: the page already up, the next one, back on.
        ask("ui", reading=False)
        found = measure(id, "scroll, reading bar off", "glide(3000)", 3)
        check("reading bar off: the page already up stops reporting its scroll",
              found["post"].get("escaleScroll", 0) == 0, found)
        load(id, work)
        found = measure(id, "scroll, reading bar off, next page", "glide(1500)", 1.5)
        check("reading bar off: the next page does not report its scroll",
              found["post"].get("escaleScroll", 0) == 0, found)
        ask("ui", reading=True)
        found = measure(id, "scroll, reading bar back on", "glide(1500)", 1.5)
        check("reading bar back on: the page already up reports its scroll again",
              found["post"].get("escaleScroll", 0) > 15, found)

        # 4. The caret in the password box: what hangs from it follows it.
        js(id, "window.scrollTo(0, 0); document.getElementById('p').focus(); true")
        found = measure(id, "scroll, caret in the password box", "glide(1000)", 1)
        check("the caret in a sign-in box: its place follows the page as it scrolls (> 10 in 1 s)",
              found["followed"] > 10, found)
        js(id, "document.getElementById('p').blur(); true")

        # 5. A password sent; the sign-in done in place.
        js(id, "reset()")
        sent(id)
        check("a password sent is reported once",
              wait_for(lambda: counts(id)["kinds"].get("submit", 0) == 1, 2), counts(id))
        found = measure(id, "churn after a password went out", "churn(3000, 20)", 3)
        check("after a password went out the page is watched at a bounded rate (≤ 40 looks in 3 s)",
              found["looks"] <= 40, found)
        check("…but watched", found["looks"] >= 3, found)
        js(id, "reset(); document.getElementById('f').remove(); true")
        check("the sign-in gone in place is reported as settled",
              wait_for(lambda: counts(id)["kinds"].get("settled", 0) == 1, 3), counts(id))
        check("…and the offer to keep the password comes up",
              wait_for(lambda: ask("probe")["offering"], 5), ask("probe"))
        found = measure(id, "churn after the sign-in settled", "churn(2000, 20)", 2)
        check("once settled the watch stops (≤ 2 looks in 2 s)", found["looks"] <= 2, found)

        # 6. Passwords neither saved nor filled.
        # One account kept for the test server, under the world's own label
        # (Vault.label), which the wipe removes: its list is what hangs from
        # the password box. Readable by any app (-A): made by `security`, it
        # would otherwise have the app ask the keychain. Kept only from here:
        # the first time the caret enters a box with an account kept for the
        # site, the page's answers wait for several seconds (5 to 21 s here,
        # on the base as well), which the timed steps above can't absorb.
        if not SKIP_KEYCHAIN:
            run(["security", "add-internet-password", "-l", f"Escale ({WORLD})", "-s", "127.0.0.1",
                 "-a", "kept", "-w", "not-this-one", "-A"])
        load(id, work)
        if not SKIP_KEYCHAIN:
            ask("tap", id=id, selector="#p")
            check("the caret in the password box: the accounts kept for the site hang from it",
                  wait_for(lambda: ask("probe")["suggesting"], 40, every=0.5), ask("probe"))
        ask("ui", filling=False)
        if not SKIP_KEYCHAIN:
            check("filling off: the list of accounts already up goes",
                  wait_for(lambda: not ask("probe")["suggesting"], 1), ask("probe"))
            # Gone again, so that nothing about it reaches the steps after this one.
            run(["security", "delete-internet-password", "-l", f"Escale ({WORLD})"], check=False)
        js(id, "document.getElementById('p').blur(); true")
        ask("ui", saving=False)
        js(id, "reset()")
        sent(id)
        time.sleep(1)
        found = counts(id)
        check("passwords off, the page already up: a password sent is not reported",
              found["kinds"].get("submit", 0) == 0, found)
        check("…nothing looks for sign-in boxes and nothing hangs from one",
              found["looks"] == 0 and found["followed"] == 0, found)
        load(id, work)
        js(id, "reset()")
        sent(id)
        time.sleep(1)
        found = counts(id)
        check("passwords off, the next page: a password sent is not reported, nothing looks for sign-ins",
              found["kinds"].get("submit", 0) == 0 and found["looks"] == 0 and found["followed"] == 0, found)
        ask("ui", saving=True)
        js(id, "reset()")
        sent(id)
        check("saving back on, the page already up: a password sent is reported again",
              wait_for(lambda: counts(id)["kinds"].get("submit", 0) == 1, 2), counts(id))
        ask("ui", filling=True)
        js(id, "reset(); document.getElementById('p').blur(); document.getElementById('p').focus(); true")
        check("filling back on: the caret in the password box is placed again",
              wait_for(lambda: counts(id)["followed"] >= 1, 2), counts(id))
        js(id, "document.getElementById('p').blur(); true")

        # 7. Drafts and typing, unchanged.
        load(id, work)
        ask("tap", id=id, selector="#t")
        ask("key", id=id, text="a draft")
        bench("bookmark", other, "new", deadline=30)
        until(f"{other} to load", lambda: at(other) and not at(other)["loading"], 10)
        ask("select", id=at(other)["id"])
        said = ask("sleep", id=id)["said"]
        check("a draft typed with real keys keeps its tab awake", said == "holding something typed", said)
        ask("select", id=id)
        load(id, typing)
        ask("tap", id=id, selector="#t")
        check("the caret in a text box: the page says so", wait_for(lambda: counts(id).get("typing") is True, 2),
              counts(id))
        ask("press", code=123, chars="", mods=["cmd"])
        time.sleep(1)
        check("…and ⌘← stays with the text", tab(id)["url"] == typing, tab(id))
        ask("tap", id=id, selector="#away")
        check("the caret out of it: the page says so", wait_for(lambda: counts(id).get("typing") is False, 2),
              counts(id))
        ask("press", code=123, chars="", mods=["cmd"])
        check("…and ⌘← goes back", wait_for(lambda: tab(id)["url"] == work, 3), tab(id))

        # 8. Middle-button scrolling under way, turned off, turned back on.
        ask("ui", autoscroll=True)
        load(id, work)
        press = ("window.scrollTo(0, 0); var at = {clientX: 400, clientY: 300, bubbles: true}; "
                 "document.body.dispatchEvent(new MouseEvent('mousedown', Object.assign({button: 1}, at))); "
                 "document.body.dispatchEvent(new MouseEvent('mousemove', {clientX: 400, clientY: 350, bubbles: true})); "
                 "true")
        js(id, press)
        check("middle-button scrolling moves the page", wait_for(lambda: js(id, "scrollY") > 50, 3),
              js(id, "scrollY"))
        ask("ui", autoscroll=False)
        time.sleep(0.5)
        y, frames = js(id, "scrollY"), counts(id)["frames"]
        time.sleep(1.5)
        moved, asked = js(id, "scrollY") - y, counts(id)["frames"] - frames
        timed["autoscroll, 1.5 s after it was turned off"] = {"moved": moved, "frames": asked}
        check("turned off, the scrolling under way stops", moved == 0, f"{moved} px more")
        check("…and asks for no more frames", asked <= 1, f"{asked} frames")
        js(id, press)
        time.sleep(1)
        check("turned off, a middle press no longer scrolls", js(id, "scrollY") == 0, js(id, "scrollY"))
        ask("ui", autoscroll=True)
        js(id, press)
        check("turned back on, the page already up scrolls again", wait_for(lambda: js(id, "scrollY") > 50, 3),
              js(id, "scrollY"))
        js(id, "document.body.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape', bubbles: true})); true")

        print(json.dumps({"app": app, "webkit": webkit(app), "windows": timed}, indent=1))
        if failures:
            raise AssertionError("\n  " + "\n  ".join(failures))
        print("ok: page scripts work only for what is on, stop when it is turned off, "
              "and drafts, typing and the offer to keep a password are unchanged")
        return 0
    except (AssertionError, subprocess.TimeoutExpired, OSError) as failure:
        if timed:
            print(json.dumps({"windows": timed}, indent=1))
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
