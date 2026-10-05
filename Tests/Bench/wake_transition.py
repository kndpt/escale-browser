#!/usr/bin/env python3
"""Wake a real discarded page while a loopback fixture controls first paint.

Headers commit immediately; a blocking script holds the first useful content,
then an image holds load completion. This distinguishes commit, paint and finish
without guessing network delays.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Event, Thread
import json
import os
import socket
import time
import suite as h

paint = Event()
finish = Event()
paint.set()
finish.set()
started = Event()
revision = 1
fail_next = False


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        global fail_next
        if self.path == '/gate.js':
            started.set()
            paint.wait(15)
            body = b'/* paint may proceed */'
            kind = 'text/javascript'
        elif self.path == '/tail.svg':
            finish.wait(15)
            body = b'<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>'
            kind = 'image/svg+xml'
        else:
            if fail_next and self.path.startswith('/page'):
                self.connection.shutdown(socket.SHUT_RDWR)
                self.connection.close()
                return
            dynamic = f'Revision {revision}' if 'dynamic' in self.path else 'Static reference'
            # A changed solid background makes the visual blend measurable in
            # real-window video, independently of text antialiasing or blur.
            ground = '#794438' if 'dynamic' in self.path and revision % 2 == 0 else '#173849'
            body = (f'<html><head><title>Wake {self.path}</title><script src="/gate.js"></script>'
                    f'<style>body{{margin:0;background:{ground};color:#f1f7fb;font:18px -apple-system}}'
                    'main{padding:40px}p{height:160px;border-bottom:1px solid #72cad3}</style></head>'
                    f'<body><main><h1>{dynamic}</h1><div>{self.path}</div><img src="/tail.svg">' +
                    ''.join(f'<p>Section {i} — sharp text after waking</p>' for i in range(30)) +
                    '</main></body></html>').encode()
            kind = 'text/html; charset=utf-8'
        self.send_response(200)
        self.send_header('Content-Type', kind)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_):
        pass


def bench(*args):
    return json.loads(h.command(str(h.ROOT / 'bench'), '--world', h.WORLD, '--json', *args))


def row(ident):
    return next(t for t in h.tabs() if t['id'] == ident)


def ended(ident, flag):
    # Observe the short fade itself, rather than polling past its entire span.
    limit = time.monotonic() + 10
    while time.monotonic() < limit:
        current = row(ident)
        if not current[flag]:
            return current
        time.sleep(.01)
    raise AssertionError(f'{flag} did not end')


def run():
    global revision, fail_next
    server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    Thread(target=server.serve_forever, daemon=True).start()
    origin = f'http://127.0.0.1:{server.server_port}'
    samples = []
    baseline = os.environ.get('BASELINE') == '1'
    with h.world(server):
        h.command('defaults', 'write', h.SUITE, 'sleep.after', '-float', '2')
        h.command(str(h.ROOT / 'fresh.sh'), 'again')
        h.until('bench ready', lambda: h.SOCKET.exists(), 20)
        bench('ui', 'sidebar', 'on')
        bench('resize', '1100', '800')
        reduced = bench('probe').get('reduceMotion', False)
        for kind in ('static', 'dynamic'):
            url = origin + '/page-' + kind
            ident = h.open_ordinary(origin + '/history-' + kind)
            bench('field', url, 'go')
            h.loaded_page(ident, 'Section', 15, 'second history entry')
            prior = bench('history', ident, 'back')['items']
            h.ask('eval', id=ident, js='scrollTo(0, 600)')
            other = h.open_ordinary(origin + '/other-' + kind)
            h.until('automatic idle discard', lambda: row(ident)['asleep'], 15)
            h.require('compressed preview retained', row(ident)['picture'] > 0, True)
            if not baseline:
                h.require('automatic sleep earns Sleeping state', row(ident)['sleeping'], True)
            revision += 1
            paint.clear(); finish.clear(); started.clear()
            start = time.monotonic()
            bench('select', ident)
            h.until('committed fixture awaiting paint', started.is_set, 10)
            if not baseline:
                h.require('Sleeping ends as soon as wake starts', row(ident)['sleeping'], False)
            for index in range(5):
                current = row(ident)
                samples.append(dict(case=kind, elapsed=time.monotonic()-start, **current))
                if not baseline:
                    h.require('waiting page remains covered', current.get('returning', current['covered']), True)
                    h.require('no premature WebKit reveal', current['unpainted'], True)
                time.sleep(.2)
            paint.set()
            current = ended(ident, 'unpainted')
            samples.append(dict(case=kind+'-paint', elapsed=time.monotonic()-start, **current))
            if not baseline:
                h.require('preview survives into the fade', current['covered'], not reduced)
                if kind == 'static':
                    # didFinish can follow first paint inside the same fade.
                    # It must not clear the image retained by the first signal.
                    finish.set()
                    completed = ended(ident, 'loading')
                    if not reduced:
                        h.require('load completion preserves in-flight preview', completed['covered'], True)
                h.until('fade releases preview', lambda: not row(ident)['covered'], 2)
                h.require('paint removes placeholder', current['returning'], False)
            h.require('subresource still loading at first paint', current['loading'], True)
            finish.set()
            h.loaded_page(ident, 'Section', 15, kind)
            restored = h.ask('eval', id=ident, js='scrollY')['value']
            assert abs(restored-600) < 5, restored
            if kind == 'dynamic':
                assert f'Revision {revision}' in h.ask('text', id=ident)['text']
            h.require('history preserved across discard', bench('history', ident, 'back')['items'], prior)
            print(f'ok: {kind} sleep, paint before finish, scroll and fresh content', flush=True)
        if not baseline:
            h.command('defaults', 'write', h.SUITE, 'sleep.after', '-float', '36000')
            # A return can outlive the image, its selection and its Space.
            bench('select', other)
            h.require('explicit discard', bench('sleep', ident)['asleep'], True)
            paint.clear(); started.clear()
            bench('select', ident)
            h.until('slow return began', started.is_set, 10)
            bench('select', other)
            h.until('expired preview released', lambda: not row(ident)['covered'], 6)
            h.require('slow return still covered by status', row(ident)['returning'], True)
            bench('select', ident)
            bench('space', 'new', 'Wake isolation')
            paint.set()
            bench('space', 'go', '1')
            bench('select', ident)
            h.until('return across Spaces finishes', lambda: not row(ident)['returning'], 15)
            h.loaded_page(ident, 'Section', 15, 'Space return')
            print('ok: preview expiry, tab switch during return and Space return', flush=True)

            # Critical pressure removes the preview through production policy.
            bench('select', other)
            bench('idle', 'critical')
            h.until('critical discard', lambda: row(ident)['asleep'], 10)
            h.require('pressure drops preview', row(ident)['picture'], 0)
            paint.clear(); started.clear()
            bench('select', ident)
            h.until('unpictured return began', started.is_set, 10)
            h.require('neutral status without a preview', row(ident)['returning'], True)
            paint.set()
            h.until('unpictured return finishes', lambda: not row(ident)['returning'], 10)
            h.loaded_page(ident, 'Section', 15, 'unpictured return')
            print('ok: critical pressure wakes without a preview', flush=True)

            # Active and background WebKit process loss do not use a snapshot.
            for selected in (True, False):
                bench('select', ident if selected else other)
                paint.clear(); started.clear()
                bench('crash', ident)
                if not selected:
                    bench('select', ident)
                h.until('crash recovery began', started.is_set, 15)
                h.require('recovery has no obsolete preview', row(ident)['covered'], False)
                h.require('crash recovery has a status', row(ident)['returning'], True)
                paint.set()
                h.until('crash paints', lambda: not row(ident)['returning'], 15)
                h.loaded_page(ident, 'Section', 15, 'crash return')
            print('ok: foreground and background WebKit termination', flush=True)

            bench('select', other)
            h.loaded_page(other, 'Section', 15, 'other before failure')
            h.require('discard before failure', bench('sleep', ident)['asleep'], True)
            fail_next = True
            bench('select', ident)
            h.until('failed return ends cover', lambda: not row(ident)['returning'], 15)
            assert bench('wait', ident, '1').get('failure'), 'missing failure surface'
            fail_next = False
            print('ok: failed return exposes error and releases preview', flush=True)

        output = Path(os.environ.get('RESULTS', '/tmp/issue137-wake.json'))
        output.write_text(json.dumps(samples, indent=2))
        print(f'Timeline: {output}', flush=True)


if __name__ == '__main__':
    try:
        run()
    finally:
        paint.set(); finish.set()
