#!/usr/bin/env python3
"""The address field, driven by real keys.

What is typed into the field, what it offers, the row the arrow keys walk
to, its refusals and ⌘K's switcher are held by the field's own owner
(Sources/Escale/Address/Field.swift) rather than by Browser; Browser keeps
whether the field is up and what Return, ⌘K and a row do to the tabs. The
rules themselves are Swift tests (Tests/EscaleTests/FieldTests.swift). This
checks the wiring through the app, with keys posted to the app as a whole
(`bench press`) and text inserted through the field's own editor
(`bench field`), and the state read back with `bench probe`:

1. First launch: a blank tab, the field standing on it with the keyboard in it.
2. Typed a key at a time: the most visited place first, its ending drawn
   after the caret; ↓ walks to the first row; Escape lets go of the row
   first, and the field stays on a blank tab.
3. Three pages opened through the field (Return). ⌘L raises the field over
   the page with its address and the keyboard; Escape puts the page back and
   forgets what was typed.
4. ⌘K: the other open pages, most recently looked at first, the first
   already picked; Return switches to it. ⌘K twice with ⌘ held: letting go
   of ⌘ takes the second.
5. A blank typed and Return: refused, the field stays up, no tab moves.
6. ⌃Tab while the field is up: the field goes with what was typed.
7. With spaces on, a new space: its blank tab has the field, empty and with
   the keyboard; back to the first space, its page, and nothing typed.

Runs in the shared runner's unique world, with pre-cleanup diagnostics.
The synthetic history and loopback pages never require a personal profile.
Every failed check stops at its expected/actual state instead of continuing
through dependent keyboard actions.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import threading
import time
import suite as harness

FOLDER = harness.SOCKET.parent
OFTEN = ["fieldalpha.example.test", "fieldbeta.example.test"]
# Foundation's JSONEncoder writes a Date as seconds since 1 January 2001.
EPOCH_2001 = 978_307_200

# Key codes as a keyboard sends them, and the characters AppKit gives them.
RETURN, ESCAPE, TAB, DOWN = ("36", "\r"), ("53", "\x1b"), ("48", "\t"), ("125", "")
L, K, T = ("37", "l"), ("40", "k"), ("17", "t")


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/") or "home"
        body = f"<title>Field {name}</title><h1>{name}</h1>".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def bench(*args, deadline=30):
    return harness.command(str(harness.ROOT / "bench"), "--world", harness.WORLD,
                           *args, seconds=deadline)


def ask(*args, deadline=30):
    return json.loads(bench("--json", *args, deadline=deadline))


def press(key, *mods):
    bench("press", *key, *mods, deadline=10)


def probe():
    return ask("probe")


def settle(what, **expected):
    return harness.wait_for(what, probe, expected, seconds=5)


def active():
    return next(tab["url"] for tab in ask("tabs")["tabs"] if tab["active"])


def count():
    return len(ask("tabs")["tabs"])


def seed():
    """history.json as the app writes it, before first launch."""
    now = time.time() - EPOCH_2001
    places = [{"url": f"https://{key}/", "key": key, "title": key, "count": n, "last": now - 60}
              for key, n in zip(OFTEN, (50, 40))]
    FOLDER.mkdir(parents=True, exist_ok=True)
    (FOLDER / "history.json").write_text(json.dumps(places))


def go(url):
    """An address typed into the field and Return, as the field's delegate takes it."""
    bench("field", url, "go", deadline=30)
    harness.until(f"{url} on screen", lambda: active() == url, 15)


def exercise(base):
    one, two, three = f"{base}/one", f"{base}/two", f"{base}/three"

    # 1. The blank tab of a first launch: the field, and the keyboard in it.
    settle("first launch", fieldShowing=True, fieldFocused=True, typed="", summoning=False)

    # 2. A key at a time, the ending drawn after the caret, ↓ and Escape.
    typed = ask("field", "fieldal", "type")
    harness.require("typed a key at a time: typed", typed.get("typed"), "fieldal")
    harness.require("typed a key at a time: first offer", (typed.get("offers") or [None])[0], OFTEN[0])
    harness.require("typed a key at a time: the field shows the ending", typed.get("field"), OFTEN[0])
    press(DOWN)
    settle("↓", picked=0, fieldFocused=True)
    press(ESCAPE)
    settle("Escape with a row picked", picked=-1, fieldShowing=True, typed="fieldal")

    # 3. Pages opened through the field; ⌘L and Escape over one.
    go(one)
    press(T, "cmd")
    settle("⌘T", fieldShowing=True, fieldFocused=True, typed="")
    go(two)
    press(T, "cmd")
    go(three)
    press(L, "cmd")
    settle("⌘L over a page", fieldShowing=True, fieldFocused=True, typed=three, summoning=False)
    press(ESCAPE)
    settle("Escape over a page", fieldShowing=False, typed="", offers=[])

    # 4. ⌘K and Return: the most recent other page. ⌘K twice: the second.
    press(K, "cmd")
    state = settle("⌘K", summoning=True, fieldShowing=True, fieldFocused=True, picked=0)
    harness.require("⌘K: the other pages, most recent first", state.get("offers"), ["Field two", "Field one"])
    press(RETURN)
    harness.until("⌘K then Return on /two", lambda: active() == two, 10)
    settle("after ⌘K", summoning=False, fieldShowing=False, typed="")
    press(K, "cmd")
    settle("⌘K from /two", summoning=True, offers=["Field three", "Field one"])
    press(K, "cmd")
    harness.until("⌘K twice, ⌘ let go, on /one", lambda: active() == one, 10)
    settle("after the walk", summoning=False, fieldShowing=False)

    # 5. Nothing that can be gone to: refused, the field stays.
    before = probe().get("refusals", 0)
    press(L, "cmd")
    bench("field", " ", deadline=30)
    tabs = count()
    press(RETURN)
    settle("a blank and Return", refusals=before + 1, fieldShowing=True)
    harness.require("a blank and Return: tabs", count(), tabs)
    harness.require("a blank and Return: tab on screen", active(), one)
    press(ESCAPE)

    # 6. Another tab with the field up: it goes, and what was typed with it.
    press(L, "cmd")
    bench("field", "half typed", deadline=30)
    press(TAB, "ctrl")
    settle("⌃Tab with the field up", fieldShowing=False, typed="", offers=[])

    # 7. Spaces: a new one's blank tab has the field, empty, with the keyboard.
    bench("ui", "spaces", "on", deadline=10)
    press(L, "cmd")
    bench("field", "carried over", deadline=30)
    bench("space", "new", "Other", deadline=15)
    settle("a new space", fieldShowing=True, fieldFocused=True, typed="")
    bench("space", "go", "1", deadline=15)
    settle("back to the first space", fieldShowing=False, typed="")


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    with harness.world(server):
        seed()
        harness.launch()
        exercise(base)
        print("ok: typing, ↓, Escape, ⌘T, ⌘L, ⌘K and its walk, a refusal, ⌃Tab and a space change, "
              "each with the field's state and focus as expected")


if __name__ == "__main__":
    main()
