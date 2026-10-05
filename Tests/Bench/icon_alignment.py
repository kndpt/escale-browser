#!/usr/bin/env python3
"""Exercise fetched and legacy favicon canvases in an isolated browser.

Swift pixel regressions in IconsTests assert the artwork geometry. This app
scenario checks fetch/persistence/restart wiring. Only synthetic loopback
pages and this run's world are used; no personal icon cache is read.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import struct
import threading
import uuid
import zlib

import suite as harness


def png(legacy=False):
    def chunk(kind, data):
        return (struct.pack('>I', len(data)) + kind + data
                + struct.pack('>I', zlib.crc32(kind + data)))
    rows = []
    for y in range(32):
        row = b''.join(bytes((40, 150, 210, 255 if not legacy or (x < 16 and y >= 16) else 0))
                       for x in range(32))
        rows.append(b'\x00' + row)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 32, 32, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(b''.join(rows))) + chunk(b'IEND', b''))


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        icon = self.path == '/icon.png'
        body = png() if icon else (b'<title>Fresh canvas</title><link rel="icon" href="/icon.png">'
                                   b'<h1>Local favicon fixture</h1>')
        self.send_response(200)
        self.send_header('Content-Type', 'image/png' if icon else 'text/html')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def bench(*args):
    return json.loads(harness.command(str(harness.ROOT / 'bench'), '--world', harness.WORLD,
                                      '--json', *map(str, args), seconds=35))


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    origin = f'http://127.0.0.1:{server.server_port}'
    folder = harness.SOCKET.parent
    icons = folder / 'icons'
    with harness.world(server):
        harness.command('defaults', 'write', harness.SUITE, 'glyph', '-string', 'icons')
        icons.mkdir(parents=True)
        legacy = png(legacy=True)
        (icons / 'legacy.invalid.png').write_bytes(legacy)
        (folder / 'bookmarks.json').write_text(json.dumps([
            {'id': str(uuid.uuid4()), 'title': 'Legacy canvas (offline)', 'url': 'https://legacy.invalid/'},
            {'id': str(uuid.uuid4()), 'title': 'Fresh canvas', 'url': origin},
        ]))
        harness.launch()
        bench('ui', 'welcome', 'off')
        bench('resize', 1100, 760)
        bench('bookmark', origin, 'new')
        harness.until('fetched favicon persisted', lambda: (icons / '127.0.0.1.png').exists(), 15)
        encoded = (icons / '127.0.0.1.png').read_bytes()
        harness.require('new PNG canvas', struct.unpack('>II', encoded[16:24]), (32, 32))
        assert b'Escale favicon 2' in encoded, 'missing per-file raster version'
        ident = next(t['id'] for t in harness.tabs() if t['url'].rstrip('/') == origin)
        bench('pin', ident, 'on')
        bench('bookmark', origin + '/ordinary', 'new')
        ordinary = next(t['id'] for t in harness.tabs() if t['url'] == origin + '/ordinary')
        loaded = bench('wait', ordinary, 15)
        assert not loaded.get('loading') and not loaded.get('failure') and not loaded.get('timeout'), loaded
        bench('press', 12, 'q', 'cmd')
        harness.until('app quit', lambda: not harness.running(), 15)
        harness.launch()
        assert (icons / '127.0.0.1.png').read_bytes() == encoded
        assert (icons / 'legacy.invalid.png').read_bytes() == legacy
        shelf = bench('shelf')
        assert 'Legacy canvas (offline)' in json.dumps(shelf) and 'Fresh canvas' in json.dumps(shelf)
        print('ok: fetched PNG is versioned, both caches survive restart, offline bookmark remains available')


if __name__ == '__main__':
    main()
