#!/usr/bin/env python3
"""The Tabs rows keep their slots while the column swaps copies.

The column is a plain stack while its rows fit and a scrolling copy when they
do not (ViewThatFits). A folder opened and shut in quick turns, in a window
whose height sits between the two, swaps the copies while the folder's spring
is still running. The selected tab's row, the one holding the sliding grey
(matchedGeometryEffect), then left its slot by about twenty points and ran over
its neighbour before it came back.

The rows' frames come from `./bench panels` (layout, sampled while the springs
run). Every loose tab row must stay a whole step under the one above it, at
window heights across the band where the swap happens. The scenario asserts
that at least one height did swap, so a green run cannot come from a window
that never reached the boundary. Run after ./build.sh debug; the world is owned
by the shared runner and pages are served from loopback.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
import json
import time
import suite as h

TABS = 9
SELECTED = TABS - 1   # the last row, so a scrolled copy is scrolled to it and shows
TOLERANCE = 1.5   # points; the rows sit on whole-point slots at rest


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


def slots(order):
    """Top of each loose tab row, in tab order; rows not laid out are left out."""
    frames = {e['id'].lower(): e['frame'][1] for e in bench('panels')['entries']}
    found = {}
    for ident in order:
        for full, top in frames.items():
            if full.startswith(ident.lower()):
                found[ident] = top
    return found


def drift(order, step):
    """How far each row is from the slot the first row implies."""
    now = slots(order)
    known = [ident for ident in order if ident in now]
    if len(known) < 2:
        return {}
    first = known[0]
    return {ident: now[ident] - now[first] - (order.index(ident) - order.index(first)) * step for ident in known[1:]}


def rapid(order, step, timeline, seconds=2.2):
    """Fire the folder calls on their timeline, sampling the rows between them."""
    start = time.monotonic()
    pending = list(timeline)
    worst = {}
    while time.monotonic() - start < seconds:
        if pending and time.monotonic() - start >= pending[0][0]:
            _, verb, name = pending.pop(0)
            bench('shelf', verb, name)
            continue
        for ident, off in drift(order, step).items():
            if abs(off) > abs(worst.get(ident, 0)):
                worst[ident] = off
    return worst


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Page)
    Thread(target=server.serve_forever, daemon=True).start()
    origin = f'http://127.0.0.1:{server.server_port}'
    with h.world(server):
        h.launch()
        bench('ui', 'sidebar', 'on')
        bench('ui', 'shelf', 'on')
        bench('shelf', 'seed')
        bench('resize', 1180, 1000)
        opened = [h.open_ordinary(origin + f'/tab-{n}') for n in range(TABS)]
        order = [t['id'] for t in h.tabs() if t['url']]
        h.require('every tab has a row of its own', len(order), TABS)
        bench('select', order[SELECTED])
        time.sleep(0.8)
        bench('shelf', 'close', 'Reading')
        time.sleep(0.8)

        # Whole window, everything plain: the slots and the step at rest.
        bench('shelf', 'open', 'Reading')
        time.sleep(0.8)
        rest = slots(order)
        h.require('every row is laid out', len(rest), TABS)
        step = (rest[order[-1]] - rest[order[0]]) / (TABS - 1)
        last = rest[order[-1]]
        bench('shelf', 'close', 'Reading')

        timeline = [(0.0, 'open', 'Reading'), (0.19, 'close', 'Reading'), (0.33, 'open', 'Reading'),
                    (0.42, 'open', 'Deeper'), (0.56, 'close', 'Deeper'), (0.70, 'close', 'Reading')]
        crossed = []
        # Open Reading needs the rows' bottom, about last + 2 steps: windows
        # around that height are where opening Deeper as well tips into a scroll.
        for height in range(int(last + 2 * step) - 8, int(last + 3 * step) + 16, 8):
            bench('resize', 1180, height)
            time.sleep(0.8)
            bench('shelf', 'open', 'Reading')
            bench('shelf', 'open', 'Deeper')
            time.sleep(0.9)
            # Scrolled copy: the last row rises from where the plain one puts it.
            swapped = slots(order)[order[-1]] < last + step - 1
            bench('shelf', 'close', 'Deeper')
            bench('shelf', 'close', 'Reading')
            time.sleep(0.9)
            if swapped:
                crossed.append(height)
            worst = rapid(order, step, timeline)
            drifted = {i: round(v, 1) for i, v in worst.items() if abs(v) > TOLERANCE}
            h.require(f'rows left their slots at window height {height}', drifted, {})
            time.sleep(0.6)
        h.require('the run reached the height where the copies swap', bool(crossed), True)
        print(f'PASS: tab rows keep their slots while the column swaps copies (swapped at {crossed})')


if __name__ == '__main__':
    main()
