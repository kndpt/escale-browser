#!/usr/bin/env python3
"""Distinguish automatically discarded pages from merely unloaded entries.

Uses real ordinary tabs and an open bookmark in an owned world. State
assertions alone do not qualify native hover help or VoiceOver.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
import json
import suite as h


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        body = (f'<title>{self.path[1:]}</title><h1>{self.path}</h1>'
                '<p>Local sleeping indicator fixture</p><textarea></textarea>').encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def bench(*args):
    return json.loads(h.command(str(h.ROOT / 'bench'), '--world', h.WORLD,
                                '--json', *map(str, args)))


def row(ident):
    return next(t for t in h.tabs() if t['id'] == ident)


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Page)
    Thread(target=server.serve_forever, daemon=True).start()
    origin = f'http://127.0.0.1:{server.server_port}'
    with h.world(server):
        h.command('defaults', 'write', h.SUITE, 'sleep.after', '-float', '2')
        h.launch()
        bench('ui', 'sidebar', 'on')
        bench('ui', 'shelf', 'on')
        bench('resize', 1100, 800)
        saved = h.open_ordinary(origin + '/Saved-page')
        shelf = bench('shelf', 'keep')
        h.require('saved page linked to an open bookmark',
                  any(r.get('live') for r in shelf['rows']), True)
        ordinary = h.open_ordinary(origin + '/Sleeping-page')
        active = h.open_ordinary(origin + '/Active-page')
        h.until('bookmark automatically sleeps', lambda: row(saved)['sleeping'], 15)
        h.until('ordinary tab automatically sleeps', lambda: row(ordinary)['sleeping'], 15)
        h.require('active page has no sleep marker', row(active)['sleeping'], False)
        h.require('bookmark has no live view', row(saved)['view'], '')
        h.require('ordinary tab has no live view', row(ordinary)['view'], '')
        bench('select', ordinary)
        h.require('wake clears marker immediately', row(ordinary)['sleeping'], False)
        h.loaded_page(ordinary, '/Sleeping-page', 15, 'woken tab')
        bench('select', saved)
        h.require('bookmark wake clears marker', row(saved)['sleeping'], False)
        h.loaded_page(saved, '/Saved-page', 15, 'woken bookmark')
        bench('pin', saved, 'on')
        bench('select', active)
        bench('idle', 'critical')
        h.until('pressure discards ordinary page', lambda: row(ordinary)['sleeping'], 15)
        h.require('pressure needs no preview for marker', row(ordinary)['picture'], 0)
        h.require('pinned bookmark remains protected', row(saved)['sleeping'], False)
        bench('select', saved)
        bench('press', 13, 'w', 'cmd')
        h.until('closed pin has no page', lambda: row(saved)['asleep'], 10)
        h.require('closed pin is not sleeping', row(saved)['sleeping'], False)
        bench('press', 12, 'q', 'cmd')
        h.until('test app quit', lambda: not h.running(), 15)
        h.launch()
        h.until('saved session restored', lambda: len(h.tabs()) >= 3, 15)
        unloaded = [t for t in h.tabs() if t['asleep']]
        h.require('session has unopened entries', bool(unloaded), True)
        h.require('unopened session entries are not Sleeping',
                  any(t['sleeping'] for t in unloaded), False)
        print('PASS: automatic tab/bookmark markers, wake, pressure, pin protection and lazy restore')


if __name__ == '__main__':
    main()
