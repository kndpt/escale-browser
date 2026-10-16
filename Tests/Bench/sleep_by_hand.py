#!/usr/bin/env python3
"""Put tabs to sleep by hand: Sleep Tab and Sleep Other Tabs.

Both run from keys bound in the test world's settings, as the shortcut
settings save them. Sleep Tab leaves a regular tab, which then shows as
sleeping with a picture kept; on a tab holding typed text it is refused and
the reason is announced. Sleep Other Tabs sleeps the tab that can sleep and
names what kept the pinned and the typed ones awake. The hand-slept tab wakes
at its scroll position with its history.

Not covered: the context menu's items, which call the same functions. The
bench's posted right press opens no SwiftUI context menu on a tab row (it does
on the page and the Space title), so they are checked by hand. Whether the
picture covers the wake is wake_transition.py's. Run after ./build.sh debug;
the world is owned by the shared runner and pages are served from loopback.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
import json
import suite as h

# ⌘⌥X and ⌘⌥Z: neither command has a key until one is chosen.
BOUND = 1048576 | 524288
KEYS = {'overrides': {'sleepTab': [{'key': 'x', 'modifiers': BOUND}],
                      'sleepOthers': [{'key': 'z', 'modifiers': BOUND}]}}


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip('/')
        body = (f'<title>{name}</title><h1>{name}</h1><textarea id="draft"></textarea>' +
                ''.join(f'<p style="height:160px">Section {i}</p>' for i in range(30))).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def bench(*args):
    return json.loads(h.command(str(h.ROOT / 'bench'), '--world', h.WORLD, '--json', *map(str, args)))


def row(ident):
    return next(t for t in h.tabs() if t['id'] == ident)


def said(text):
    h.until(f'announced "{text}"', lambda: bench('probe')['announcement'] == text, 10)


def sleep_tab(ident):
    bench('select', ident)
    bench('press', 7, 'x', 'cmd', 'opt')


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Page)
    Thread(target=server.serve_forever, daemon=True).start()
    origin = f'http://127.0.0.1:{server.server_port}'
    with h.world(server):
        # Only a hand puts a tab to sleep here.
        h.command('defaults', 'write', h.SUITE, 'sleep.after', '-float', '36000')
        h.command('defaults', 'write', h.SUITE, 'keyboard.bindings', '-data', json.dumps(KEYS).encode().hex())
        h.launch()
        bench('ui', 'sidebar', 'on')
        bench('resize', 1100, 800)

        heavy = h.open_ordinary(origin + '/first')
        bench('field', origin + '/heavy', 'go')
        h.loaded_page(heavy, 'heavy', 15, 'second history entry')
        prior = bench('history', heavy, 'back')['items']
        h.ask('eval', id=heavy, js='scrollTo(0, 600)')
        pinned = h.open_ordinary(origin + '/pinned')
        bench('pin', pinned, 'on')
        draft = h.open_ordinary(origin + '/draft')
        h.ask('tap', id=draft, selector='#draft')
        h.ask('key', id=draft, text='unsent words')
        h.until('typed draft', lambda: h.ask('eval', id=draft, js="document.querySelector('#draft').value")
                .get('value') == 'unsent words', 5)
        spare = h.open_ordinary(origin + '/spare')
        current = h.open_ordinary(origin + '/current')

        sleep_tab(draft)
        said('Kept awake: holding something typed')
        h.require('Sleep Tab left the typed tab', row(draft)['active'], False)
        h.require('typed tab stays awake', row(draft)['sleeping'], False)
        h.require('typed text kept', h.ask('eval', id=draft, js="document.querySelector('#draft').value")
                  .get('value'), 'unsent words')
        print('ok: a typed tab is refused with its reason', flush=True)

        sleep_tab(heavy)
        said('Tab asleep')
        h.require('Sleep Tab left the tab', row(heavy)['active'], False)
        h.require('hand-slept tab shows as sleeping', row(heavy)['sleeping'], True)
        h.require('hand-slept tab let its page go', row(heavy)['view'], '')
        h.require('hand-slept tab keeps a picture', row(heavy)['picture'] > 0, True)
        print('ok: Sleep Tab', flush=True)

        bench('select', current)
        bench('press', 6, 'z', 'cmd', 'opt')
        said('1 tab asleep, 2 kept awake: pinned, holding something typed')
        h.require('Sleep Other Tabs slept the spare tab', row(spare)['sleeping'], True)
        h.require('the pinned tab stays awake', row(pinned)['sleeping'], False)
        h.require('the tab on screen stays awake', row(current)['sleeping'], False)
        print('ok: Sleep Other Tabs, refusals named', flush=True)

        bench('select', heavy)
        h.require('wake clears the marker', row(heavy)['sleeping'], False)
        h.loaded_page(heavy, 'heavy', 15, 'woken tab')
        h.until('scroll position restored', lambda: abs(h.ask('eval', id=heavy, js='scrollY')['value'] - 600) < 5, 10)
        h.require('history kept across sleep', bench('history', heavy, 'back')['items'], prior)
        print('PASS: Sleep Tab and Sleep Other Tabs by key, refusals with reasons, wake where it was')


if __name__ == '__main__':
    main()
