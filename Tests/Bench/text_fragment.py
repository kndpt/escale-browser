#!/usr/bin/env python3
"""Copy Link with Highlight: the copied link scrolls to the passage in a new tab.

1. Over a passage found once, the right-click menu has one Copy Link with
   Highlight (WebKit's own where it has one, else Escale's); the link it
   copies scrolls the passage into view in a new tab.
2. A passage found twice and selected with the mouse: the selection menu's
   link carries the words around it, and the new tab opens on that
   occurrence, not the first.
3. Selected in a field, the right-click menu has no entry; selected in a
   frame, the entry copies the plain address and the line at the bottom
   says so.

Not covered: shadow roots, Chromium opening the link, and how the selection
menu looks (a visual review). The clipboard is used, then put back.
Runs in its own world from build/Escale.app (./build.sh debug first), pages
from 127.0.0.1 only; exits non-zero with the expected and observed state.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import subprocess
import sys
import threading
import suite as s

FILLER = "".join(f"<p>Filler paragraph {n} keeps the passages apart.</p>" for n in range(50))
PAGE = f"""<!doctype html><meta charset=utf-8><title>Passages</title>
<body style="font:16px/1.5 -apple-system">{FILLER}
<p id=unique>The quick brown fox jumps over the lazy dog.</p>{FILLER}
<p id=first>Alpha said: restart the server now, please.</p>{FILLER}
<p id=second>Beta said: restart the server now, quickly.</p>{FILLER}
<p>Same words.</p>{FILLER}<p id=twin>Same words.</p>{FILLER}
<textarea id=field>Words inside a text field</textarea>
<iframe id=frame srcdoc="<p id=inner>Words inside a frame</p>"></iframe>{FILLER}</body>""".encode()

ENTRY = "Copy Link with Highlight"
SENTINEL = "escale text fragment sentinel"


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(PAGE)))
        self.end_headers()
        self.wfile.write(PAGE)

    def log_message(self, *args):
        pass


def bench(*args):
    return json.loads(s.command(str(s.ROOT / "bench"), "--world", s.WORLD, "--json", *map(str, args), seconds=35))


def clipboard():
    return subprocess.run(["pbpaste"], capture_output=True, text=True, timeout=5).stdout


def put(text):
    subprocess.run(["pbcopy"], input=text, text=True, timeout=5)


def window_point(tab, js):
    """Runs `js`, which returns a point in the page, and gives that point in the window."""
    x, y, width = bench("eval", tab, f"(() => {{ const p = ({js})(); return [p[0], p[1], innerWidth]; }})()")["value"]
    frame = bench("probe")["pageFrame"]
    scale = frame[2] / width  # page zoom and magnification
    return frame[0] + x * scale, frame[1] + y * scale


def passage(ident, start, end, at):
    """A point of a passage of `ident`'s text, scrolled to the middle: `at` is x within its rectangle."""
    return f"""() => {{ const el = document.getElementById('{ident}'); el.scrollIntoView({{block: 'center'}});
        const r = document.createRange(); r.setStart(el.firstChild, {start}); r.setEnd(el.firstChild, {end});
        const b = r.getBoundingClientRect(); return [{at}, b.top + b.height / 2]; }}"""


def menu_at(x, y):
    return [item["title"] for item in bench("pointer", "menu", x, y)["items"]]


def copied_from_menu(x, y):
    put(SENTINEL)
    items = menu_at(x, y)
    s.require("the right-click menu offers the entry once", items.count(ENTRY), 1)
    bench("pointer", "choose", items.index(ENTRY))
    return s.until("something copied", lambda: clipboard() != SENTINEL and clipboard())


def opens_on(link, ident, other=None):
    """The link in a new tab: the passage scrolled into view, and not the other one."""
    tab = bench("open", link)["id"]
    s.until("the link loaded", lambda: not bench("wait", tab, 1).get("loading"), 20)
    look = f"""(() => {{ const at = id => id ? document.getElementById(id).getBoundingClientRect().top : null;
        return JSON.stringify([at('{ident}'), {f"at('{other}')" if other else "null"}, innerHeight]); }})()"""

    def seen():
        top, elsewhere, height = json.loads(bench("eval", tab, look)["value"])
        return 0 <= top < height and (elsewhere is None or not 0 <= elsewhere < height)
    s.until(f"{ident} scrolled into view by {link}", seen, 10)
    bench("close", tab)


def exercise(base):
    bench("ui", "welcome", "off")
    bench("field", base + "/", "go")
    tab = next(t for t in s.tabs() if t["active"])["id"]
    s.until("the page loaded", lambda: "quick brown fox" in bench("text", tab).get("text", ""), 20)
    page = base + "/"

    x, y = window_point(tab, passage("unique", 4, 19, "b.left + b.width / 2"))
    bench("eval", tab, """(() => { const t = document.getElementById('unique').firstChild, r = document.createRange();
        r.setStart(t, 4); r.setEnd(t, 19); getSelection().removeAllRanges(); getSelection().addRange(r); return 1; })()""")
    link = copied_from_menu(x, y)
    s.require("the right-click menu's link is a text fragment", link.startswith(page + "#:~:text="), True)
    opens_on(link, "unique")
    print("ok: the right-click menu links a passage found once, and the link scrolls to it")

    bench("eval", tab, "getSelection().removeAllRanges(); 1")
    left = window_point(tab, passage("second", 11, 33, "b.left + 2"))
    right = window_point(tab, passage("second", 11, 33, "b.right - 2"))
    bench("drag", *left, *right, "live")
    x, y, width, height = s.until("the selection menu", lambda: bench("probe").get("selection"), 10)
    put(SENTINEL)
    # The link is the round end of the menu's capsule.
    bench("pointer", "move", x + width - height / 2, y + height / 2)
    bench("hit", x + width - height / 2, y + height / 2, "click", "live")
    link = s.until("the selection menu's link copied", lambda: clipboard() != SENTINEL and clipboard())
    s.require("a repeated passage carries the words around it", link,
              page + "#:~:text=Beta%20said%3A-,restart%20the%20server%20now,-%2C%20quickly.")
    s.require("and says so", bench("probe")["announcement"], "Link with highlight copied")
    opens_on(link, "second", "first")
    print("ok: the selection menu links a repeated passage to the one selected")

    script = (s.ROOT / "Sources/Escale/Page/Scripts/text-fragment.js").read_text()
    bench("eval", tab, """(() => { const t = document.getElementById('twin').firstChild, r = document.createRange();
        r.setStart(t, 0); r.setEnd(t, 10); getSelection().removeAllRanges(); getSelection().addRange(r); return 1; })()""")
    s.require("a passage nothing around tells apart gets no fragment", bench("eval", tab, script).get("value"), None)
    print("ok: a passage no nearby words tell apart is not linked to")

    x, y = window_point(tab, """() => { getSelection().removeAllRanges(); const f = document.getElementById('field');
        f.scrollIntoView({block: 'center'}); f.focus(); f.setSelectionRange(0, 5);
        const b = f.getBoundingClientRect(); return [b.left + 10, b.top + 10]; }""")
    s.require("no entry over a field", ENTRY in menu_at(x, y), False)
    bench("pointer", "cancel")

    link = copied_from_menu(*window_point(tab, """() => { getSelection().removeAllRanges();
        const f = document.getElementById('frame'), d = f.contentDocument, t = d.getElementById('inner').firstChild;
        f.scrollIntoView({block: 'center'}); const r = d.createRange(); r.setStart(t, 0); r.setEnd(t, 5);
        d.getSelection().removeAllRanges(); d.getSelection().addRange(r); f.focus();
        const o = f.getBoundingClientRect(), b = r.getBoundingClientRect();
        return [o.left + b.left + b.width / 2, o.top + b.top + b.height / 2]; }"""))
    s.require("a frame's text copies the plain address", link, page)
    s.require("and says so", "can't be linked" in bench("probe")["announcement"], True)
    print("ok: no entry in a field; a frame's text copies the address and says so")


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    kept = clipboard()
    try:
        with s.world(server):
            s.launch()
            exercise(f"http://127.0.0.1:{server.server_port}")
    finally:
        put(kept)


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
