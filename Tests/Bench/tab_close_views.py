#!/usr/bin/env python3
"""A closed tab gets no new page view.

Closing the tab on screen published its changes while the stage still showed
it, and the stage asked the closing tab for its view: a new one was built, with
its message handlers and scripts, and never let go. Each New Tab, page and ⌘W
left one WKUserContentController behind, about 80 KB in the browser and as
much in WebKit.

Real ordinary tabs in an owned world: TABS times a page opened from New Tab
and closed with ⌘W. Live WKUserContentController objects are counted in the
browser process with `heap`, after a first cycle and after the rest: the count
must not grow with the closed tabs. Not covered: closing a parked tab, moving
a tab to another Space, and the memory each leak cost.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
import json
import re
import subprocess
import suite as h

TABS = 10


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        body = f'<title>{self.path[1:]}</title><h1>{self.path}</h1>'.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def bench(*args):
    return json.loads(h.command(str(h.ROOT / 'bench'), '--world', h.WORLD, '--json', *map(str, args)))


def controllers():
    pid = subprocess.run(['pgrep', '-f', h.BINARY], capture_output=True, text=True).stdout.split()[0]
    out = subprocess.run(['heap', '-s', pid], capture_output=True, text=True, timeout=60).stdout
    found = re.search(r'^\s*(\d+)\s+\d+\s+[\d.]+\s+WKUserContentController\s', out, re.M)
    if not found:
        raise AssertionError('heap listed no WKUserContentController')
    return int(found.group(1))


def cycle(origin, n):
    h.open_ordinary(f'{origin}/closed-{n}')
    bench('press', 13, 'w', 'cmd')
    h.until(f'tab {n} closed', lambda: len(h.tabs()) == 1, 10)


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Page)
    Thread(target=server.serve_forever, daemon=True).start()
    origin = f'http://127.0.0.1:{server.server_port}'
    with h.world(server):
        h.launch()
        h.open_ordinary(origin + '/kept')
        cycle(origin, 0)
        first = controllers()
        for n in range(1, TABS):
            cycle(origin, n)
        h.require(f'live content controllers after {TABS - 1} more closed tabs', controllers(), first)
        print(f'closed tabs: {TABS} closed, {first} content controllers before and after')


if __name__ == '__main__':
    main()
