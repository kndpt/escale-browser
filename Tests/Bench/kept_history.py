#!/usr/bin/env python3
"""A tab made from another keeps its Back and Forward (#60).

A → B → C in a tab, then ⌘D, ⌘W with ⌘⇧T, a move to another Space (awake,
then asleep), Clear with ⌘⇧T while its Undo shows: each new tab's back list
is B, A and ⌘[ lands on B. The Spaces have their own WebKit stores, so the
move also restores the history into another store. A copy of a tab whose
last load failed goes to that address, not back to C; a private tab's copy
starts with no history, as before.

Run after ./build.sh debug. Keys go through the app's own dispatch, not the
Mac's keyboard. Not covered: a copy made while its source is still waking.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
import json
import socket
import suite as h


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.rsplit('/', 1)[-1]
        body = f'<title>{name.upper()} page</title><h1>{name}</h1>'.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def bench(*args):
    return json.loads(h.command(str(h.ROOT / 'bench'), '--world', h.WORLD, '--json', *args, seconds=30))


def active():
    return next(t for t in bench('tabs')['tabs'] if t['active'])


def other(source):
    """The active tab, and whether it is another than `source`."""
    tab = active()
    return dict(tab, new=tab['id'] != source)


def back(ident):
    return [item['url'] for item in bench('history', ident, 'back')['items']]


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Page)
    Thread(target=server.serve_forever, daemon=True).start()
    with h.world(server):
        h.launch()
        bench('resize', '1180', '780')
        bench('ui', 'spaces', 'on')
        base = f'http://127.0.0.1:{server.server_port}'

        def visit(prefix, private=False):
            """A new tab through A, B and C → its id and the three URLs."""
            bench('press', '45' if private else '17', 'n' if private else 't', 'cmd', *(['shift'] if private else []))
            urls = [f'{base}/{prefix}/{name}' for name in 'abc']
            for url in urls:
                bench('field', url, 'go')
                h.wait_for('loaded ' + url, active, {'url': url, 'loading': False})
            ident = active()['id']
            h.until('A and B behind C', lambda: back(ident) == urls[1::-1])
            return ident, urls

        def arrived(what, source, urls):
            """The new active tab is at C with B, A behind it, and ⌘[ goes to B."""
            tab = h.wait_for(what + ' at C', lambda: other(source),
                             {'new': True, 'url': urls[2], 'loading': False}, 20)
            h.until(what + ' keeps B and A behind C', lambda: back(tab['id']) == urls[1::-1], 10)
            bench('press', '33', '[', 'cmd')
            h.wait_for(what + ' goes back to B', active, {'id': tab['id'], 'url': urls[1], 'loading': False})
            return tab

        source, urls = visit('duplicate')
        bench('press', '2', 'd', 'cmd')
        arrived('⌘D copy', source, urls)
        h.require('original keeps its history', back(source), urls[1::-1])
        h.require('original stays at C', next(t for t in h.tabs() if t['id'] == source)['url'], urls[2])
        print('ok: ⌘D', flush=True)

        # Sent somewhere that fails, the tab names that address while its
        # list is still on C: the copy goes to the address, without a list.
        source, urls = visit('failed')
        # A port just let go of refuses; a low one would be blocked by WebKit
        # as restricted rather than fail.
        with socket.socket() as spare:
            spare.bind(('127.0.0.1', 0))
            refused = f'http://127.0.0.1:{spare.getsockname()[1]}/refused'
        bench('field', refused, 'go')
        h.until('load failed', lambda: active().get('failure') and active()['url'] == refused)
        bench('press', '2', 'd', 'cmd')
        copy = h.wait_for('copy of a failed load', lambda: other(source), {'new': True, 'url': refused})
        h.require('copy goes where the tab was sent, not back to C', copy['url'], refused)
        h.require('copy of a failed load carries no list', back(copy['id']), [])
        print('ok: ⌘D after a failed load', flush=True)

        source, urls = visit('reopen')
        bench('press', '13', 'w', 'cmd')
        h.until('closed', lambda: all(t['id'] != source for t in h.tabs()))
        bench('press', '17', 't', 'cmd', 'shift')
        arrived('⌘⇧T reopen', source, urls)
        print('ok: ⌘⇧T', flush=True)

        bench('space', 'new', 'Elsewhere')
        bench('space', 'go', '1')
        source, urls = visit('move')
        before = active()
        bench('space', 'transfer', source, '2')
        moved = arrived('moved tab', source, urls)
        h.require('moved to the other Space', moved['space'] != before['space'], True)
        h.require('into the other Space\'s store', moved['store'] != before['store'], True)
        print('ok: move to another Space and store', flush=True)

        source, urls = visit('asleep')
        bench('press', '17', 't', 'cmd')
        bench('field', f'{base}/other', 'go')
        h.wait_for('other page', active, {'url': f'{base}/other', 'loading': False})
        h.require('put to sleep', bench('sleep', source)['asleep'], True)
        bench('space', 'transfer', source, '1')
        arrived('moved sleeping tab', source, urls)
        print('ok: move a sleeping tab', flush=True)

        # Clear closes the row together; ⌘⇧T while its Undo shows brings it
        # all back, the tab looked at with its history.
        source, urls = visit('clear')
        h.require('nothing left to clear', bench('shelf', 'clear')['clearable'], 0)
        h.until('closed by Clear', lambda: all(t['id'] != source for t in h.tabs()))
        bench('press', '17', 't', 'cmd', 'shift')
        arrived('tab back from Undo Clear', source, urls)
        print('ok: Undo Clear', flush=True)

        source, urls = visit('private', private=True)
        h.require('private tab', active()['shy'], True)
        bench('press', '2', 'd', 'cmd')
        copy = h.wait_for('private copy at C', lambda: other(source),
                          {'new': True, 'url': urls[2], 'loading': False, 'shy': True}, 20)
        h.require('private copy starts without history', back(copy['id']), [])
        print('ok: a private copy keeps today\'s behaviour', flush=True)


if __name__ == '__main__':
    main()
