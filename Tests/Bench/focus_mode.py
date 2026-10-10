#!/usr/bin/env python3
"""Focus Mode through its own key, in both layouts, with and without Spaces.

In the column's mode the page frame takes the window, set in on every side,
with the column, rail and bar gone; across the top it matches the ⌘S fold.
During the mode ⌘L raises Bearings over the unchanged page frame, the top
band moves the window, and the band brought down shows the lights. Leaving it
restores the page frame, fold, bar and lights, and no saved setting changed.
⌘S during the mode leaves it with the tabs out. The binding is a fixture,
since the command has no default key. Not covered: the View menu item (same
action), the pointer resting on the top edge, and how it looks.
"""
import json
import subprocess
from http.server import ThreadingHTTPServer
from threading import Thread
import suite as h

WIDTH, HEIGHT = 1100, 760
# ⌘⇧O, written as Preferences stores bindings.
FOCUS = (31, 'o', 'cmd', 'shift')
LAYOUT_KEYS = ('sidebar', 'sidebar.bar', 'sidebar.hides', 'spaces', 'sidebar.width')


def ask(verb, *args):
    return json.loads(h.command(str(h.ROOT / 'bench'), '--world', h.WORLD, '--json', verb, *map(str, args)))


def state():
    probe = ask('probe')
    return {key: probe.get(key) for key in ('pageFrame', 'folded', 'bar', 'lightsHidden', 'peeking', 'fieldShowing')}


def alike(now, expected):
    """The expected values, the page frame within a point and a half: after a
    transition the web view's origin can stop a little off the whole point."""
    return all(all(abs(a - b) <= 1.5 for a, b in zip(now[k], v)) if k == 'pageFrame' else now[k] == v
               for k, v in expected.items())


def same(what, now, expected):
    if not alike(now, expected):
        raise AssertionError(f'{what}: expected {expected!r}, got {now!r}')


def settings():
    """The saved layout settings, read from the world's own defaults."""
    out = {}
    for key in LAYOUT_KEYS:
        read = subprocess.run(['defaults', 'read', h.SUITE, key], capture_output=True, text=True)
        out[key] = read.stdout.strip() if read.returncode == 0 else None
    return out


def settled(what, expected=None):
    """The window once the chrome has stopped moving: two equal readings."""
    last = {}

    def still():
        nonlocal last
        now = state()
        done = now == last and (expected is None or alike(now, expected))
        last = now
        return done
    h.until(what, still, 10)
    return last


def filled(name, frame):
    """Only the page's inset round it; the top may also keep the reading line's room."""
    x, y, width, height = frame
    margins = [round(m, 1) for m in (x, y, WIDTH - x - width, HEIGHT - y - height)]
    h.require(name + ' page fills the window ' + str(margins), all(0 < m <= 16 for m in margins), True)
    h.require(name + ' page set in evenly ' + str(margins), abs(margins[0] - margins[2]) <= 1, True)


def bearings(name, frame):
    ask('press', 37, 'l', 'cmd')
    h.wait_for(name + ' ⌘L', lambda: {k: ask('probe')[k] for k in ('fieldShowing', 'fieldFocused')},
               {'fieldShowing': True, 'fieldFocused': True}, 5)
    same(name + ' page frame under Bearings', state(), {'pageFrame': frame})
    ask('press', 53, '\x1b')
    h.wait_for(name + ' Escape', lambda: {'fieldShowing': ask('probe')['fieldShowing']}, {'fieldShowing': False}, 5)


def run():
    server = ThreadingHTTPServer(('127.0.0.1', 0), h.Page)
    Thread(target=server.serve_forever, daemon=True).start()
    with h.world(server):
        data = json.dumps({'overrides': {'focus': [{'key': 'o', 'modifiers': 1179648}]}}).encode().hex()
        h.command('defaults', 'write', h.SUITE, 'keyboard.bindings', '-data', data)
        h.launch()
        ask('ui', 'welcome', 'off')
        ask('resize', WIDTH, HEIGHT)
        h.open_ordinary(f'http://127.0.0.1:{server.server_port}/focus')
        checked = 0
        for spaces in ('on', 'off'):
            for sidebar, bar, folded in (('on', 'on', 'off'), ('on', 'off', 'on'), ('off', 'off', 'off')):
                name = f'spaces {spaces}, sidebar {sidebar}, bar {bar}, folded {folded}'
                for key, value in (('spaces', spaces), ('sidebar', sidebar), ('bar', bar), ('folded', folded)):
                    ask('ui', key, value)
                before = settled(name + ' before', {'folded': folded == 'on'})
                saved = settings()
                if sidebar == 'off':
                    # Across the top, Focus Mode is the fold.
                    ask('press', 1, 's', 'cmd')
                    fold = settled(name + ' ⌘S fold', {'folded': True, 'lightsHidden': True})
                    ask('press', 1, 's', 'cmd')
                    settled(name + ' ⌘S back', before)
                ask('press', *FOCUS)
                inside = settled(name + ' in focus', {'folded': True, 'bar': False, 'lightsHidden': True})
                filled(name, inside['pageFrame'])
                if sidebar == 'off':
                    same(name + ' same as the fold', inside, fold)
                else:
                    top = ask('hit', WIDTH / 2, 3)
                    h.require(name + ' top band moves the window', top['view'], 'Strip')
                    ask('ui', 'peek', 'on')
                    settled(name + ' band down', {'lightsHidden': False, 'peeking': True})
                    h.require(name + ' band moves the window', ask('hit', WIDTH / 2, 20)['view'], 'Strip')
                    ask('ui', 'peek', 'off')
                    settled(name + ' band up', {'lightsHidden': True, 'peeking': False})
                bearings(name, inside['pageFrame'])
                ask('press', *FOCUS)
                after = settled(name + ' restored', before)
                same(name + ' restored state', after, before)
                h.require(name + ' no setting changed', settings(), saved)
                checked += 1
        # ⌘S in Focus Mode leaves it with the tabs out.
        for key, value in (('spaces', 'on'), ('sidebar', 'on'), ('bar', 'on'), ('folded', 'on')):
            ask('ui', key, value)
        settled('⌘S setup', {'folded': True})
        ask('press', *FOCUS)
        settled('⌘S focus', {'bar': False, 'lightsHidden': True})
        ask('press', 1, 's', 'cmd')
        out = settled('⌘S leaves focus', {'folded': False, 'bar': True, 'lightsHidden': False})
        h.require('⌘S column and rail back', out['pageFrame'][0] > 100, True)
        print(f'ok: {checked} layouts in and out of Focus Mode; page frame, ⌘L, top band, lights, '
              'restored state and saved settings; ⌘S leaves it')


if __name__ == '__main__':
    run()
