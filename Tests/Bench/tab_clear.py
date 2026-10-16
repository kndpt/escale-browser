#!/usr/bin/env python3
"""Clear, at the Tabs heading: what it closes and what it leaves.

Real ordinary tabs in an owned world: three loose tabs, a pin, a bookmark's
own tab and a tab in a second Space. Clear closes exactly the loose tabs of
the Space on screen, lands on an awake tab that stays, and the second Space
keeps its tab. A Space with only loose tabs is left with one blank tab, which
Clear then has nothing to close in. That last Clear is a real click on the
heading's button, at its place in a column with an empty shelf.

Then Undo, in a third Space of fifteen tabs: after Clear, the line's button,
pressed as VoiceOver presses it, and after Close Other Tabs, ⇧⌘T, each bring
every tab back in its order with the one looked at selected and the only one
loaded. Once the line has gone, so has Undo: ⇧⌘T reopens one tab. It does
not cover the line's look, nor panels, which come back as separate tabs.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
import json
import suite as h


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        body = f'<title>{self.path[1:]}</title><h1>{self.path}</h1>'.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def bench(*args):
    return json.loads(h.command(str(h.ROOT / 'bench'), '--world', h.WORLD, '--json', *map(str, args)))


def urls():
    return sorted(t['url'].rsplit('/', 1)[-1] for t in h.tabs() if t['url'])


def addresses():
    return [t['url'] for t in h.tabs() if t['url']]


def undone(what, order, looked):
    h.until(f'{what} undone', lambda: addresses() == order, 10)
    rows = h.tabs()
    h.require(f'{what}: those tabs only', len(rows), len(order))
    h.require(f'{what}: the tab looked at', next(t for t in rows if t['active'])['url'], looked)
    h.require(f'{what}: only it loaded', [t['url'] for t in rows if t['view'] or not t['asleep']], [looked])
    h.require(f'{what}: the line has gone', bench('undo')['label'], '')


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Page)
    Thread(target=server.serve_forever, daemon=True).start()
    origin = f'http://127.0.0.1:{server.server_port}'
    with h.world(server):
        h.launch()
        bench('ui', 'sidebar', 'on')
        bench('ui', 'shelf', 'on')
        bench('resize', 1100, 800)
        # A bookmark with a tab of its own, kept on the shelf.
        kept = h.open_ordinary(origin + '/kept')
        bench('select', kept)
        h.require('shelf took the active tab', any(r['tab'] for r in bench('shelf', 'keep')['rows']), True)
        # A pin, put down so that nothing awake stays but the bookmark's tab.
        pinned = h.open_ordinary(origin + '/pinned')
        bench('pin', pinned, 'on')
        # The other Space keeps its own tab.
        bench('space', 'new', 'Other')
        bench('space', 'go', 2)
        elsewhere = h.open_ordinary(origin + '/elsewhere')
        bench('space', 'go', 1)
        loose = [h.open_ordinary(origin + f'/loose-{n}') for n in (1, 2, 3)]
        bench('select', loose[1])
        h.until('loose tabs are all counted', lambda: bench('shelf')['clearable'] == 3, 10)

        answer = bench('shelf', 'clear')
        h.require('nothing left to clear', answer['clearable'], 0)
        rest = urls()
        h.require('pin and bookmark tab stay, loose tabs go', [u for u in rest if u], ['kept', 'pinned'])
        row = next(t for t in h.tabs() if t['active'])
        h.require('landed on a tab that stayed', row['url'].rsplit('/', 1)[-1] in ('kept', 'pinned'), True)
        h.require('one tab looked at', sum(1 for t in h.tabs() if t['active']), 1)
        h.require('the pin is still a pin', next(t for t in h.tabs() if t['url'].endswith('/pinned'))['pin'] != '', True)

        # Nothing loose now: a second Clear changes nothing.
        before = urls()
        bench('shelf', 'clear')
        h.require('second Clear is a no-op', urls(), before)

        # The other Space kept its tab, and clearing there leaves a blank one.
        bench('space', 'go', 2)
        h.require('other Space kept its tab', urls(), ['elsewhere'])
        # The hand rests on the heading while the list fills under it: hover
        # is the window server's, and a cursor left elsewhere by an earlier
        # scenario reached it only by luck.
        bench('pointer', 'move', 287, 160)
        second = h.open_ordinary(origin + '/second')
        h.require('two loose tabs to clear', bench('shelf')['clearable'], 2)
        # The button itself: the bin sits at the heading's end, 160 points down,
        # and is drawn only while the pointer is on the heading, so the pointer
        # goes there first, as a hand does, and the click follows.
        # The move is a hint to the hover state, which the window server may
        # deliver late; a press before it shows is tried again, never assumed.
        for attempt in range(3):
            bench('pointer', 'move', 287, 160)
            bench('hit', 287, 160, 'click', 'live')
            try:
                h.until('the click cleared the tabs', lambda: [t['url'] for t in h.tabs()] == [''], 4)
                break
            except Exception:
                if attempt == 2:
                    raise
        answer = bench('shelf')
        rows = h.tabs()
        h.require('a blank tab stands in', [t['url'] for t in rows], [''])
        h.require('and it is the one looked at', rows[0]['active'], True)
        h.require('nothing left to clear there', answer['clearable'], 0)
        bench('space', 'go', 1)
        h.require('first Space untouched by that', urls(), ['kept', 'pinned'])

        bench('space', 'new', 'Many')
        bench('space', 'go', 3)
        many = [h.open_ordinary(f'{origin}/many-{n}') for n in range(15)]
        bench('select', many[4])
        order = addresses()
        bench('shelf', 'clear')
        h.require('the line offers all fifteen', bench('undo')['count'], 15)
        # Once SwiftUI has drawn the line.
        h.until('VoiceOver finds its Undo', lambda: bench('undo')['button'] == bench('undo')['label'], 5)
        h.require('pressed as VoiceOver does', bench('undo', 'press')['pressed'], True)
        undone('Clear', order, f'{origin}/many-4')

        rows = h.tabs()
        bench('select', rows[7]['id'])
        bench('ui', 'closeothers', 'on')
        h.require('only the one kept', addresses(), [order[7]])
        h.require('the line offers the others', bench('undo')['count'], 14)
        bench('press', 17, 't', 'cmd', 'shift')
        undone('Close Other Tabs', order, order[7])

        bench('ui', 'closeothers', 'on')
        h.until('the line goes, and Undo with it', lambda: [bench('undo')[k] for k in ('label', 'button')] == ['', None], 10)
        bench('press', 17, 't', 'cmd', 'shift')
        h.until('⇧⌘T then reopens one', lambda: len(addresses()) == 2, 10)
        print('PASS: Clear closes the loose tabs of the Space on screen only, keeps pins and bookmarks, lands on a tab or a blank one; '
              'Undo brings back Clear or Close Other Tabs whole, one page loaded, until the line goes')


if __name__ == '__main__':
    main()
