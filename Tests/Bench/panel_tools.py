#!/usr/bin/env python3
"""The capsule of a split page, revealed by the pointer and pressed natively.

A composition's capsule exists only while the pointer is over a page's top
band, so no command of the bench can stand in for the hand: the scenario moves
the pointer there, then presses each of its four buttons with posted AppKit
events and asserts what the composition did. Both tab layouts and both looks.
The standard runner owns a random world and loopback fixtures.
--require-reduced-motion refuses a disabled system setting rather than
mistaking a normal-motion run for accessibility qualification.
"""
from argparse import ArgumentParser
from http.server import ThreadingHTTPServer
from threading import Thread
import json
import time
import suite as s

# Metrics.panelTool / panelToolsInset and the capsule's padding, scaled by the
# interface size as ChromeMetrics.length does (half points on Retina).
FACTOR = {'compact': 0.9, 'standard': 1.125, 'large': 1.35}


def length(value, size='standard'):
    return round(value * FACTOR[size] * 2) / 2


def bench(*args):
    return json.loads(s.command(str(s.ROOT / 'bench'), '--world', s.WORLD, '--json', *map(str, args)))


def short(value):
    return value[:8].lower()


def state():
    value = bench('panels')
    for group in value['groups']:
        group['members'] = list(map(short, group['members']))
        group['active'] = short(group['active'])
    for key in ('entries', 'pages'):
        for entry in value[key]:
            entry['id'] = short(entry['id'])
    return value


def page(id):
    return next(p for p in state()['pages'] if p['id'] == id)


def settled():
    previous = None; identical = 0
    def stable():
        nonlocal previous, identical
        now = state()
        current = [p.get('frame') for p in now['pages']] + [e['frame'] for e in now['entries']]
        identical = identical + 1 if current == previous else 0
        previous = current
        return identical >= 3
    s.until('native page and row geometry settles', stable, 5)


def tool(frame, index, size='standard'):
    """Centre of the capsule's button `index` over a page at `frame`."""
    x, y, w, _ = frame
    side = length(24, size); pad = length(3, size)
    left = x + w / 2 - (4 * side + 2 * pad) / 2
    return left + pad + side * (index + 0.5), y + length(8, size) + length(2, size) + side / 2


def reveal(id, size='standard'):
    """The real pointer over the page's top band, and the capsule it brings."""
    frame = page(id)['frame']
    # A hand comes in from the page: a pointer already inside the band when the
    # composition changed gets no new entry, so leave it first.
    bench('pointer', 'move', frame[0] + frame[2] / 2, frame[1] + frame[3] / 2)
    bench('pointer', 'move', frame[0] + frame[2] / 2, frame[1] + 6)
    time.sleep(0.6)
    return frame


def press(id, index, size='standard'):
    frame = reveal(id, size)
    x, y = tool(frame, index, size)
    bench('pointer', 'move', x, y)
    time.sleep(0.3)
    bench('pointer', 'click', x, y)
    time.sleep(0.5)


def assemble(base, prefix):
    """Three ordinary pages side by side, the first one focused."""
    ids = []
    for name in ('a', 'b', 'c'):
        bench('bookmark', f'{base}/{prefix}-{name}', 'new')
        id = next(t['id'] for t in bench('tabs')['tabs'] if t['active']); ids.append(short(id))
        loaded = bench('wait', id, 10)
        assert not loaded['loading'] and not loaded.get('failure') and not loaded.get('timeout'), loaded
    a, b, c = ids
    bench('select', a)
    assert bench('panels', 'add', b, a, 'right')['accepted']
    assert bench('panels', 'add', c, a, 'right')['accepted']
    settled()
    assert state()['groups'][0]['members'] == [a, b, c], state()['groups']
    return a, b, c


def journey(base, layout, look):
    name = f'{layout}-{look}'
    print('capsule:', name, flush=True)
    a, b, c = assemble(base, name)
    group = lambda: state()['groups'][0]
    # Swap: the middle page trades places with the next one.
    press(b, 0)
    assert group()['members'] == [a, c, b], group()
    settled()
    # Orientation: the composition turns, all its pages stay mounted.
    identities = {p['id']: p['page'] for p in state()['pages'] if p['id'] in (a, b, c)}
    assert group()['horizontal']
    press(a, 1)
    assert not group()['horizontal'], group()
    settled()
    press(a, 1)
    assert group()['horizontal'], group()
    settled()
    assert {p['id']: p['page'] for p in state()['pages'] if p['id'] in identities} == identities
    # Move out: the last page leaves the split and stays an ordinary tab.
    last = group()['members'][-1]
    press(last, 2)
    assert state()['groups'] and last not in group()['members'] and len(group()['members']) == 2, state()['groups']
    assert any(t['id'].startswith(last) for t in bench('tabs')['tabs'])
    settled()
    # Close: the capsule's cross closes that page and only that page.
    first, second = group()['members']
    press(first, 3)
    assert not any(t['id'].startswith(first) for t in bench('tabs')['tabs']), first
    assert not state()['groups'], state()['groups']
    for id in (second, last):
        bench('panels', 'close', id)


def main(require_reduced_motion=False):
    server = ThreadingHTTPServer(('127.0.0.1', 0), s.Page)
    Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    with s.world(server):
        s.launch()
        if require_reduced_motion:
            s.require('actual macOS Reduce Motion setting', bench('probe')['reduceMotion'], True)
        bench('ui', 'welcome', 'off'); bench('ui', 'spaces', 'on')
        bench('resize', 1180, 780)
        for layout in ('sidebar', 'strip'):
            bench('ui', 'sidebar', 'on' if layout == 'sidebar' else 'off')
            for look in ('light', 'dark'):
                bench('ui', 'look', look)
                settled()
                journey(base, layout, look)
        if require_reduced_motion:
            s.require('macOS Reduce Motion stayed enabled', bench('probe')['reduceMotion'], True)
        print('ok: the capsule is revealed by the pointer and its four buttons act on their page, in both tab layouts and looks')


if __name__ == '__main__':
    parser = ArgumentParser(description=__doc__)
    parser.add_argument('--require-reduced-motion', action='store_true',
                        help='require the actual macOS setting; never change it')
    main(parser.parse_args().require_reduced_motion)
