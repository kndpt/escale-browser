#!/usr/bin/env python3
"""Actual held-button native Back/Forward history menus.

Run after ./build.sh debug in an exclusive UI slot. The shared runner owns the
world. Pointer events enter AppKit's queue; menu observations are native NSMenu
items, never Tab.recent. Choosing invokes that menu item's actual action.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
from urllib.parse import urlsplit
import json
import suite as h

class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlsplit(self.path).path
        name = path.rsplit('/', 1)[-1]
        title = '' if '/untitled/' in path else f'<title>{name.upper()} page</title>'
        body = (title + f'<h1>{name}</h1><p>Local control regression</p>').encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *_): pass

def bench(*args):
    return json.loads(h.command(str(h.ROOT / 'bench'), '--world', h.WORLD, '--json', *args, seconds=30))

def active(): return next(t for t in bench('tabs')['tabs'] if t['active'])

def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Page)
    Thread(target=server.serve_forever, daemon=True).start()
    with h.world(server):
        h.launch()
        bench('resize', '1180', '780')
        bench('ui', 'size', 'standard')
        base = f'http://127.0.0.1:{server.server_port}'
        for side in (True, False):
            bench('ui', 'sidebar', 'on' if side else 'off')
            bench('ui', 'bar', 'on')
            back_x, forward_x = (340, 373) if side else (127, 158)
            for unnamed in (False, True):
                bench('ui', 'look', 'dark' if unnamed else 'light')
                bench('press', '17', 't', 'cmd')
                path = '/untitled/' if unnamed else '/named/'
                urls = {name: f'{base}{path}{name}?token=' + ('long-value-' * 40) + '#section' for name in 'abcd'}
                for name in 'abcd':
                    bench('field', urls[name], 'go')
                    h.wait_for('loaded ' + name, active, {'url': urls[name], 'loading': False})
                # The field goes once the page is chosen; a press while it is
                # still on screen is the field's, not the toolbar's.
                h.wait_for('field put away', lambda: {'field': bench('probe')['fieldShowing']}, {'field': False})
                tab = active()['id']
                def menu(back, names):
                    # A displaced foreground app cancels native tracking. Retry
                    # that explicit interruption, never a wrong menu or active-app failure.
                    for attempt in range(3):
                        value = bench('pointer', 'hold', str(back_x if back else forward_x), '20')
                        if value['tracking'] or value['active']: break
                        print('interrupted: app lost foreground during native hold; attempt', attempt + 1, flush=True)
                    h.require('real native menu is tracking: ' + json.dumps(value), value['tracking'], True)
                    rows = value['items']
                    h.require('native menu count', len(rows), len(names))
                    for row, name in zip(rows, names):
                        text = row['title'] + ' ' + row.get('subtitle', '')
                        assert 'token=' not in text and '#section' not in text, text
                        assert (path + name) in text, text
                        if not unnamed: assert name.upper() + ' page' in text, text
                    model = bench('history', tab, 'back' if back else 'forward')
                    h.require('model matches current menu', [v['url'] for v in model['items']], [urls[n] for n in names])
                    return value
                menu(True, 'cba')
                bench('pointer', 'choose', '1')
                h.wait_for('native menu jump to B preserves exact URL', active, {'url': urls['b'], 'loading': False})
                menu(True, 'a'); bench('pointer', 'cancel')
                menu(False, 'cd'); bench('pointer', 'cancel')
                menu(True, 'a'); bench('pointer', 'choose', '0')
                h.wait_for('native menu jump to A', active, {'url': urls['a'], 'loading': False})
                h.require('Back unavailable at A', bench('pointer', 'hold', str(back_x), '20')['tracking'], False)
                h.require('disabled Back preserves A', active()['url'], urls['a'])
                menu(False, 'bcd'); bench('pointer', 'choose', '2')
                h.wait_for('native menu jump forward to D', active, {'url': urls['d'], 'loading': False})
                bench('pointer', 'click', str(back_x), '20')
                h.wait_for('single click still goes back', active, {'url': urls['c'], 'loading': False})
                bench('pointer', 'click', str(forward_x), '20')
                h.wait_for('single click still goes forward', active, {'url': urls['d'], 'loading': False})
                bench('press', '33', '[', 'cmd')
                h.wait_for('keyboard goes back', active, {'url': urls['c'], 'loading': False})
                bench('press', '30', ']', 'cmd')
                h.wait_for('keyboard goes forward', active, {'url': urls['d'], 'loading': False})
                print('ok: native reopen, exact URLs, clicks and keys', 'sidebar' if side else 'strip', 'untitled' if unnamed else 'titles', flush=True)

if __name__ == '__main__': main()
