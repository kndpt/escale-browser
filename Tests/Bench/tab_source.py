#!/usr/bin/env python3
"""Closing a tab opened from a link goes back to the page the link was in.

Real ⌘W and real clicks on a loopback page, in a row where the page is not
next to where the fallback would land: [A, B, C] with A on screen, so a link
opened from A sits at [A, N, B, C] and the neighbour on the right is B.

- ⌘⇧-click and a link with target=_blank (which lands at the far end of the
  row) each close back to A, not to B or C.
- A tab opened by the address bar or a bookmark keeps the neighbour rule.
- When A is gone by the time N closes, N falls back to its right neighbour.

The cross on the tab calls the same Browser.close as ⌘W. The middle button is
not exercised: `bench tap … middle` hands WebKit an event without a middle
button number, so the click navigates the page itself. Runs through the
shared runner's owned world; pages are synthetic loopback documents.
"""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
import suite as s


def bench(*args):
    return json.loads(s.command(str(s.ROOT / 'bench'), '--world', s.WORLD, '--json', *map(str, args)))


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip('/') or 'home'
        body = (f'<title>Source {name}</title><h1>{name}</h1>'
                f'<a id="link" href="/from-{name}">Link</a><br>'
                f'<a id="blank" href="/blank-{name}" target="_blank">Blank</a>').encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def row():
    return [tab['id'] for tab in s.tabs() if not tab['bench']]


def active():
    return next(tab['id'] for tab in s.tabs() if tab['active'])


def close_active():
    before = len(row())
    bench('press', 13, 'w', 'cmd')
    s.until('tab closed', lambda: len(row()) == before - 1)


def opened(before):
    s.until('new tab', lambda: len(row()) == len(before) + 1)
    return next(ident for ident in row() if ident not in before)


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Page)
    Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    with s.world(server):
        s.launch()
        a = s.open_ordinary(base + '/a')
        b = s.open_ordinary(base + '/b')
        s.open_ordinary(base + '/c')

        def source():
            bench('select', a)
            s.require('source on screen', active(), a)
            return row()

        def follow(kind):
            before = source()
            if kind == 'cmd-shift':
                bench('tap', a, '#link', 'cmd', 'shift')
            else:
                bench('tap', a, '#blank')
            new = opened(before)
            s.until('new tab settled', lambda: not next(t for t in s.tabs() if t['id'] == new)['loading'], 15)
            bench('select', new)
            s.require(f'{kind} tab on screen', active(), new)
            # A window a page asks for joins the far end of the row, the
            # others sit beside their source: either way it is not where the
            # neighbour rule would have gone.
            s.require(f'{kind} tab is not the source', new != a, True)
            return new

        for kind in ('cmd-shift', 'blank'):
            new = follow(kind)
            close_active()
            s.require(f'{kind}: closing returns to the source', active(), a)
            s.require(f'{kind}: row is as it was', row()[:2], [a, b])
        print('ok: ⌘⇧-click and target=_blank tabs close back to their source')

        # Independent of any link: the neighbour rule stays.
        before = source()
        s.ask('bookmark', url=base + '/d', new=True)
        fresh = opened(before)
        bench('select', fresh)
        index = row().index(fresh)
        expected = [i for i in row() if i != fresh]
        expected = expected[min(index, len(expected) - 1)]
        close_active()
        s.require('a tab not opened by a link lands on its neighbour', active(), expected)
        print('ok: a tab opened without a link keeps the neighbour rule')

        # The source is gone: predictable fallback to the right neighbour.
        follow('cmd-shift')
        bench('select', a)
        close_active()
        s.until('source closed', lambda: a not in row())
        linked = active()
        s.require('link tab follows the closed source', row().index(linked), 0)
        neighbour = row()[1]
        close_active()
        s.require('source gone: falls back to the right neighbour', active(), neighbour)
        print('ok: a closed source falls back to the neighbour')


if __name__ == '__main__':
    main()
