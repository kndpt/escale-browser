#!/usr/bin/env python3
"""Exercise fetched and legacy favicon canvases in an isolated browser.

Swift pixel regressions in IconsTests assert the artwork geometry. This app
scenario checks fetch/persistence/restart wiring, a host's file from before
sources were written being fetched again, and two apps on one host
(/spreadsheets and /document, as on docs.google.com) each keeping its own
icon, opened together while the first one's icon is on its way. Only
synthetic loopback pages and this run's world are used; no personal icon
cache is read.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import socket
import struct
import threading
import time
import uuid
import zlib

import suite as harness


def png(legacy=False, colour=(40, 150, 210)):
    def chunk(kind, data):
        return (struct.pack('>I', len(data)) + kind + data
                + struct.pack('>I', zlib.crc32(kind + data)))
    rows = []
    for y in range(32):
        row = b''.join(bytes((*colour, 255 if not legacy or (x < 16 and y >= 16) else 0))
                       for x in range(32))
        rows.append(b'\x00' + row)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 32, 32, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(b''.join(rows))) + chunk(b'IEND', b''))


APPS = {'spreadsheets': (30, 160, 80), 'document': (60, 110, 230)}
ASKED = []


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        icon = self.path.endswith('.png')
        app = self.path.split('/')[1]
        if icon:
            ASKED.append(self.path)
        if icon and self.path[1:-4] in APPS:
            if self.path == '/spreadsheets.png':
                time.sleep(1.5)
            body = png(colour=APPS[self.path[1:-4]])
        elif icon:
            body = png()
        elif app in APPS:
            body = f'<title>{app}</title><link rel="icon" href="/{app}.png"><h1>{app}</h1>'.encode()
        else:
            body = (b'<title>Fresh canvas</title><link rel="icon" href="/icon.png">'
                    b'<h1>Local favicon fixture</h1>')
        self.send_response(200)
        self.send_header('Content-Type', 'image/png' if icon else 'text/html')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


class Server(ThreadingHTTPServer):
    address_family = socket.AF_INET6

    def server_bind(self):
        # Both loopbacks: 127.0.0.1, and NAME.localhost, which may be ::1.
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()


def bench(*args):
    return json.loads(harness.command(str(harness.ROOT / 'bench'), '--world', harness.WORLD,
                                      '--json', *map(str, args), seconds=35))


def main():
    server = Server(('::', 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    origin = f'http://127.0.0.1:{server.server_port}'
    folder = harness.SOCKET.parent
    icons = folder / 'icons'
    with harness.world(server):
        harness.command('defaults', 'write', harness.SUITE, 'glyph', '-string', 'icons')
        icons.mkdir(parents=True)
        legacy = png(legacy=True)
        (icons / 'legacy.invalid.png').write_bytes(legacy)
        # A fresh file from before sources were written: fetched once more.
        (icons / '127.0.0.1.png').write_bytes(png())
        (folder / 'bookmarks.json').write_text(json.dumps([
            {'id': str(uuid.uuid4()), 'title': 'Legacy canvas (offline)', 'url': 'https://legacy.invalid/'},
            {'id': str(uuid.uuid4()), 'title': 'Fresh canvas', 'url': origin},
        ]))
        harness.launch()
        bench('ui', 'welcome', 'off')
        bench('resize', 1100, 760)
        bench('bookmark', origin, 'new')
        harness.until('fetched favicon persisted',
                      lambda: b'Escale favicon 2' in (icons / '127.0.0.1.png').read_bytes(), 15)
        encoded = (icons / '127.0.0.1.png').read_bytes()
        harness.require('new PNG canvas', struct.unpack('>II', encoded[16:24]), (32, 32))
        assert b'Escale favicon 2' in encoded, 'missing per-file raster version'
        ident = next(t['id'] for t in harness.tabs() if t['url'].rstrip('/') == origin)
        bench('pin', ident, 'on')
        bench('bookmark', origin + '/ordinary', 'new')
        ordinary = next(t['id'] for t in harness.tabs() if t['url'] == origin + '/ordinary')
        loaded = bench('wait', ordinary, 15)
        assert not loaded.get('loading') and not loaded.get('failure') and not loaded.get('timeout'), loaded
        harness.require('a page declaring the host\'s icon keeps no file', sorted(p.name for p in icons.iterdir()),
                        ['127.0.0.1.png', 'legacy.invalid.png'])
        # Two apps on one host, each declaring its own icon: the root's is the host's.
        for app in APPS:
            bench('bookmark', f'{origin}/{app}/d/1', 'new')
            harness.until(f'{app} icon kept', lambda: (icons / f'127.0.0.1~{app}.png').exists(), 15)
        sheet, doc = ((icons / f'127.0.0.1~{app}.png').read_bytes() for app in APPS)
        assert sheet != doc != encoded, 'two apps on one host share an icon file'
        assert (icons / '127.0.0.1.png').read_bytes() == encoded, 'an app replaced the host\'s icon'
        # A host never seen, both apps opened together: the doc asks while
        # the sheet's slow icon is on its way, and still keeps its own.
        apps = f'http://apps.localhost:{server.server_port}'
        for app in APPS:
            bench('bookmark', f'{apps}/{app}/d/1', 'new')
        harness.until('both icons kept', lambda: (icons / 'apps.localhost.png').exists()
                      and (icons / 'apps.localhost~document.png').exists(), 15)
        time.sleep(2)
        harness.require('one file each', sorted(p.name for p in icons.glob('apps.localhost*')),
                        ['apps.localhost.png', 'apps.localhost~document.png'])
        assert (icons / 'apps.localhost.png').read_bytes() != (icons / 'apps.localhost~document.png').read_bytes()
        asked = len(ASKED)
        bench('bookmark', f'{origin}/spreadsheets/d/2', 'new')
        again = next(t['id'] for t in harness.tabs() if t['url'].endswith('/spreadsheets/d/2'))
        bench('wait', again, 15)
        harness.require('a fresh app icon is not asked again', ASKED[asked:], [])
        bench('press', 12, 'q', 'cmd')
        harness.until('app quit', lambda: not harness.running(), 15)
        harness.launch()
        assert (icons / '127.0.0.1.png').read_bytes() == encoded
        assert (icons / '127.0.0.1~document.png').read_bytes() == doc
        assert (icons / 'legacy.invalid.png').read_bytes() == legacy
        shelf = bench('shelf')
        assert 'Legacy canvas (offline)' in json.dumps(shelf) and 'Fresh canvas' in json.dumps(shelf)
        print('ok: fetched PNG is versioned, both caches survive restart, offline bookmark remains available, '
              'two apps on one host keep their own icons')


if __name__ == '__main__':
    main()
