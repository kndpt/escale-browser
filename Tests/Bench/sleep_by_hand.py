#!/usr/bin/env python3
"""Put tabs to sleep by hand: Sleep Tab from a tab's menu, Sleep Other Tabs.

A regular tab off screen is slept from its context menu (a native right
press) and shows as sleeping with a picture kept; the tab on screen offers no
Sleep Tab; a pinned tab and a tab holding typed text are refused, and the
refusal is announced with its reason. Sleep Other Tabs and Sleep Tab run from
keys bound in the test world's settings, as the shortcut settings save them.
The hand-slept tab wakes at its scroll position with its history. Whether the
picture covers the wake is wake_transition.py's. Run after ./build.sh debug,
in front: the menus need the pointer. The world is owned by the shared runner
and pages are served from loopback.
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


def menu(ident):
    """The tab's own context menu, opened by a right press on its row."""
    entry = h.until(f'row of {ident}', lambda: next(
        (e for e in bench('panels')['entries'] if e['id'].lower().startswith(ident.lower())), None), 10)
    x, y, w, height = entry['frame']
    state = bench('pointer', 'menu', x + min(w / 3, 45), y + height / 2)
    assert state['tracking'], state
    return [item['title'] for item in state['items']]


def choose(ident, title):
    titles = menu(ident)
    assert title in titles, titles
    bench('pointer', 'choose', titles.index(title))


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

        titles = menu(current)
        bench('pointer', 'cancel')
        h.require('the tab on screen offers no Sleep Tab', 'Sleep Tab' in titles, False)
        h.require('but offers Sleep Other Tabs', 'Sleep Other Tabs' in titles, True)

        choose(heavy, 'Sleep Tab')
        said('Tab asleep')
        h.require('hand-slept tab shows as sleeping', row(heavy)['sleeping'], True)
        h.require('hand-slept tab let its page go', row(heavy)['view'], '')
        h.require('hand-slept tab keeps a picture', row(heavy)['picture'] > 0, True)
        print('ok: Sleep Tab from the context menu', flush=True)

        choose(pinned, 'Sleep Tab')
        said('Kept awake: pinned')
        h.require('pinned tab stays awake', row(pinned)['sleeping'], False)
        choose(draft, 'Sleep Tab')
        said('Kept awake: holding something typed')
        h.require('typed tab stays awake', row(draft)['sleeping'], False)
        h.require('typed text kept', h.ask('eval', id=draft, js="document.querySelector('#draft').value")
                  .get('value'), 'unsent words')
        print('ok: pinned and typed tabs refused with their reason', flush=True)

        bench('press', 6, 'z', 'cmd', 'opt')
        said('1 tab asleep, 2 kept awake: pinned, holding something typed')
        h.require('Sleep Other Tabs slept the spare tab', row(spare)['sleeping'], True)
        h.require('the tab on screen stays awake', row(current)['sleeping'], False)
        print('ok: Sleep Other Tabs from its key', flush=True)

        bench('select', heavy)
        h.require('wake clears the marker', row(heavy)['sleeping'], False)
        h.loaded_page(heavy, 'heavy', 15, 'woken tab')
        h.until('scroll position restored', lambda: abs(h.ask('eval', id=heavy, js='scrollY')['value'] - 600) < 5, 10)
        h.require('history kept across sleep', bench('history', heavy, 'back')['items'], prior)
        print('ok: a hand-slept tab wakes where it was', flush=True)

        bench('press', 7, 'x', 'cmd', 'opt')
        said('Tab asleep')
        h.require('Sleep Tab key left the tab', row(heavy)['active'], False)
        h.require('and slept it', row(heavy)['sleeping'], True)
        print('PASS: Sleep Tab and Sleep Other Tabs by hand, refusals, wake')


if __name__ == '__main__':
    main()
