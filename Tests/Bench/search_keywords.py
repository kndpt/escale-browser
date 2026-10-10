#!/usr/bin/env python3
"""Search keywords in Bearings, through real keys and a loopback template.

The rules (parsing, refusal, encoding) are Swift tests
(Tests/EscaleTests/KeywordTests.swift). This checks the wiring: a keyword
written in the world's settings before launch, `lo hello wörld` typed a key
at a time, the first row is the keyword's, with the words encoded into its
template and the engine's row gone (its wording is a Swift test), nothing
reaches the server before Return, and Return opens that address. Then an
unknown keyword and a keyword with no words still end on the engine's row;
neither is submitted, so nothing leaves the Mac. Not covered: editing the
list in Settings, or transfer.
"""

from http.server import ThreadingHTTPServer
import json
import threading
import suite as s

requests = []
RETURN, ESCAPE = ("36", "\r"), ("53", "\x1b")


class Page(s.Page):
    def do_GET(self):
        requests.append(self.path)
        super().do_GET()


def bench(*args, deadline=30):
    return json.loads(s.command(str(s.ROOT / "bench"), "--world", s.WORLD, "--json", *args, seconds=deadline))


def press(key):
    bench("press", *key, deadline=10)


def rows():
    return [(row["kind"], row["url"]) for row in bench("probe")["offerDetails"]]


def active():
    return next(tab["url"] for tab in s.tabs() if tab["active"])


def exercise(base):
    wanted = f"{base}/find?q=hello%20w%C3%B6rld"

    # The row, first, in place of the engine's; nothing sent while typing.
    s.wait_for("the field on the first blank tab", lambda: bench("probe"), {"fieldShowing": True, "fieldFocused": True})
    bench("field", "lo hello wörld", "type")
    s.until("the keyword's row", lambda: rows() and rows()[0][0] == "keyword", 5)
    found = rows()
    s.require("first row", found[0], ("keyword", wanted))
    s.require("no engine row beside it", [row for row in found if row[0] == "search"], [])
    s.require("requests before Return", [path for path in requests if path.startswith("/find")], [])

    # Return opens the template with the words encoded.
    press(RETURN)
    s.until("the template on screen", lambda: active() == wanted, 15)
    s.until("the template asked for", lambda: "/find?q=hello%20w%C3%B6rld" in requests, 10)

    # An unknown keyword, or a keyword alone, stays an ordinary search.
    for typed in ("zz hello", "lo"):
        bench("field", typed, "type")
        s.until(f"{typed!r}: the engine's row", lambda: rows() and rows()[-1][0] == "search", 5)
        s.require(f"{typed!r}: no keyword row", [row for row in rows() if row[0] == "keyword"], [])
        press(ESCAPE)
        s.until(f"{typed!r}: the field let go", lambda: not bench("probe")["fieldShowing"], 5)


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    with s.world(server):
        s.command("defaults", "write", s.SUITE, "search.keywords", "-string", f"lo {base}/find?q=%s")
        s.launch()
        exercise(base)
        print("ok: a keyword's row first, nothing sent while typing, Return opens its encoded template; "
              "an unknown keyword and a bare one stay ordinary searches")


if __name__ == "__main__":
    main()
