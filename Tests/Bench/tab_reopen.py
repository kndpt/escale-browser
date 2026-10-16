#!/usr/bin/env python3
"""⇧⌘T in two Spaces: each brings back its own closed tabs, names included.

Real ordinary tabs in an owned world, closed with ⌘W and reopened with ⇧⌘T.
The second Space closes two tabs, one of them named; then the first closes
one more than a Space keeps, the last of them named. The first keeps its own
newest, and the second still has both of its own: one Space never makes room
in another's. Each reopened tab has its name back. It does not cover the
History menu or the extension `sessions` API, which read the same list as
`tabs`' `closed`, nor what the rule keeps (ClosedTabsTests).
"""
from http.server import ThreadingHTTPServer
from threading import Thread
import json
import suite as h

# Browser.Ghost.kept
KEPT = 10
W, T = (13, 'w'), (17, 't')


def bench(*args):
    return json.loads(h.command(str(h.ROOT / 'bench'), '--world', h.WORLD, '--json', *map(str, args)))


def closed():
    return bench('tabs')['closed']


def active():
    return next(t for t in h.tabs() if t['active'])


def close(ident):
    bench('select', ident)
    bench('press', *W, 'cmd')
    h.until('tab closed', lambda: all(t['id'] != ident for t in h.tabs()), 10)


def reopen(url, name):
    bench('press', *T, 'cmd', 'shift')
    h.until(f'{url} back', lambda: active()['url'] == url, 10)
    h.require(f'{url} named', active()['name'], name)


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), h.Page)
    Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    with h.world(server):
        h.launch()
        bench('space', 'new', 'Other')
        bench('space', 'go', 2)
        theirs = [h.open_ordinary(f'{base}/two-{n}') for n in ('a', 'b')]
        bench('select', theirs[0])
        bench('ui', 'renametab', 'Theirs')
        for ident in theirs:
            close(ident)
        h.require('second Space lists its own', closed(), ['Theirs', 'Suite two-b'])

        bench('space', 'go', 1)
        mine = [h.open_ordinary(f'{base}/one-{n}') for n in range(KEPT + 1)]
        bench('select', mine[-1])
        bench('ui', 'renametab', 'Mine')
        for ident in mine:
            close(ident)
        h.require('first Space keeps its newest', closed(),
                  [f'Suite one-{n}' for n in range(1, KEPT)] + ['Mine'])
        reopen(f'{base}/one-{KEPT}', 'Mine')

        bench('space', 'go', 2)
        h.require('second Space kept both', closed(), ['Theirs', 'Suite two-b'])
        reopen(f'{base}/two-b', '')
        reopen(f'{base}/two-a', 'Theirs')
        h.require('in their places', [t['url'] for t in h.tabs() if t['url']], [f'{base}/two-a', f'{base}/two-b'])
        h.require('nothing left to reopen there', closed(), [])
        print('PASS: each Space reopens its own closed tabs with their names; closing many in one leaves the other\'s')


if __name__ == '__main__':
    main()
