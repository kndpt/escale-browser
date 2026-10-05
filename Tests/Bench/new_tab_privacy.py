#!/usr/bin/env python3
"""An ordinary search must not navigate a private tab dragged onto the shelf.

One isolated world, two local pages and production shelf/drop actions reproduce
this without races. The private page keeps its identity, address and DOM state;
the ordinary destination receives exactly one new ordinary tab.
"""
import json
from http.server import ThreadingHTTPServer
from threading import Thread
import suite as s


def bench(*args):
    return json.loads(s.command(str(s.ROOT / 'bench'), '--world', s.WORLD, '--json', *args))


def active():
    return next(t for t in s.tabs() if t['active'])


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), s.Page)
    Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    try:
        s.command(str(s.ROOT / 'fresh.sh'), 'wipe')
        s.command('defaults', 'write', s.SUITE, 'bench', '-bool', 'YES')
        s.launch()
        bench('ui', 'welcome', 'off')
        bench('ui', 'sidebar', 'on')
        bench('ui', 'shelf', 'on')
        bench('field', base + '/ordinary', 'go')
        ordinary = active()['id']
        bench('wait', ordinary, '10')
        bench('press', '45', 'n', 'cmd', 'shift')
        bench('field', base + '/private', 'go')
        private = active()['id']
        bench('wait', private, '10')
        bench('eval', private, "window.privateDraft = 'keep me'; 'set'")
        shelf = bench('shelf', 'keep')
        title = next(row['title'] for row in shelf['rows'] if row['live'])
        bench('environments', title, 'set', json.dumps([
            {'name': 'PRIVATE', 'url': base + '/private'},
            {'name': 'PUBLIC', 'url': base + '/public'}]))
        bench('select', ordinary)
        count = len(s.tabs())
        bench('press', '17', 't', 'cmd')
        bench('field', title, 'type')
        bench('press', '48', '\t')
        bench('press', '48', '\t')
        s.require('PUBLIC selected', bench('probe')['environment'], 'PUBLIC')
        bench('press', '36', '\r')
        s.require('ordinary search remains ordinary', active()['shy'], False)
        s.require('ordinary destination', active()['url'], base + '/public')
        s.require('one ordinary tab created', len(s.tabs()), count + 1)
        kept = next(t for t in s.tabs() if t['id'] == private)
        s.require('private page retains privacy', kept['shy'], True)
        s.require('private page is not navigated', kept['url'], base + '/private')
        s.require('private page retains its draft', bench('eval', private, 'window.privateDraft')['value'], 'keep me')
        print('ok: ordinary bookmark search never reuses or navigates a linked private page')
    finally:
        s.command(str(s.ROOT / 'fresh.sh'), 'wipe')
        server.shutdown()


if __name__ == '__main__':
    main()
