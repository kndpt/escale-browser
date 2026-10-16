#!/usr/bin/env python3
"""A split from the keyboard and the Tabs menu: focus, swap, move out, separate.

Three loopback pages make one split. Bound keys walk the focus through it both
ways and ⌘L follows the page in focus; the Tabs menu and a bound key each swap,
take a page out and separate. With no split shown the five items are disabled
and their keys change nothing. The keys are saved before launch, as Settings
saves them; recording them is keyboard_settings.py's concern. The focus ring is
drawn from the focused page, asserted here as state, not as pixels.
The standard runner owns a random world and a loopback fixture.
"""
from http.server import ThreadingHTTPServer
from threading import Thread
import json
import suite as s

# ⌥⇧⌘ and a letter: no default uses them and the recorder accepts them.
MODS = ('cmd', 'opt', 'shift')
MASK = 1048576 | 524288 | 131072
KEYS = {'nextPanel': (38, 'j'), 'previousPanel': (40, 'k'), 'swapPanel': (31, 'o'),
        'movePanelOut': (32, 'u'), 'separatePanels': (7, 'x')}
TITLES = {'nextPanel': 'Next Panel', 'previousPanel': 'Previous Panel', 'swapPanel': 'Swap with Next Panel',
          'movePanelOut': 'Move Out of Split', 'separatePanels': 'Separate Split'}


def bench(*args):
    return json.loads(s.command(str(s.ROOT / 'bench'), '--world', s.WORLD, '--json', *map(str, args)))


def short(value):
    return value[:8].lower()


def active():
    return short(next(t['id'] for t in s.tabs() if t['active']))


def groups():
    return [dict(members=list(map(short, g['members'])), active=short(g['active'])) for g in bench('panels')['groups']]


def press(action):
    code, char = KEYS[action]
    bench('press', code, char, *MODS)


def menu(action):
    item = bench('panels', 'menu', TITLES[action])
    assert 'error' not in item, item
    s.require(f'{TITLES[action]} shows its bound key', item['key'].lower(), KEYS[action][1])
    return item['enabled']


def split(expected, focused, held=None):
    # The group keeps the page last in focus in it; a page taken out leaves its first.
    s.wait_for('split', lambda: dict(groups=groups(), active=active()),
               dict(groups=[dict(members=expected, active=held or focused)], active=focused))


def addressed(url):
    bench('press', 37, 'l', 'cmd')
    s.until(f'⌘L edits {url}', lambda: bench('probe')['typed'] == url)
    bench('press', 53, '\x1b')


def run():
    server = ThreadingHTTPServer(('127.0.0.1', 0), s.Page)
    Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    with s.world(server):
        # Store uses Data, as Preferences does. Never touch a production suite.
        data = json.dumps({'overrides': {action: [{'key': char, 'modifiers': MASK}]
                                         for action, (_, char) in KEYS.items()}}).encode().hex()
        s.command('defaults', 'write', s.SUITE, 'keyboard.bindings', '-data', data)
        s.launch()
        bench('ui', 'welcome', 'off')
        bench('resize', 1180, 780)
        urls = [base + '/' + name for name in ('alpha', 'bravo', 'charlie')]
        a, b, c = (short(s.open_ordinary(url)) for url in urls)
        url = dict(zip((a, b, c), urls))

        print('no split: disabled items, inert keys', flush=True)
        count = len(s.tabs())
        for action in KEYS:
            s.require(f'{TITLES[action]} disabled without a split', menu(action), False)
            press(action)
        s.require('keys outside a split change nothing', (groups(), active(), len(s.tabs())), ([], c, count))

        print('focus: next and previous wrap through three pages', flush=True)
        bench('select', a)
        assert bench('panels', 'add', b, a, 'right')['accepted']
        assert bench('panels', 'add', c, a, 'right')['accepted']
        split([a, b, c], c)
        pages = {short(p['id']): p['page'] for p in bench('panels')['pages']}
        for action, focused in (('nextPanel', a), ('nextPanel', b), ('nextPanel', c),
                                ('previousPanel', b), ('previousPanel', a), ('previousPanel', c)):
            press(action)
            split([a, b, c], focused)
            if action == 'nextPanel':
                addressed(url[focused])
        # The menu's items are the same commands: from c, Previous then Next.
        assert menu('previousPanel')
        split([a, b, c], b)
        assert menu('nextPanel')
        split([a, b, c], c)
        press('nextPanel')
        split([a, b, c], a)

        print('swap: menu, then key, then the last page', flush=True)
        assert menu('swapPanel')
        split([b, a, c], a)
        press('swapPanel')
        split([b, c, a], a)
        press('swapPanel')
        split([b, a, c], a)
        s.require('swaps keep every page', {short(p['id']): p['page'] for p in bench('panels')['pages']}, pages)

        print('move out: menu, then key', flush=True)
        assert menu('movePanelOut')
        split([b, c], a, held=b)
        s.require('a page out of the split has no panel commands', menu('nextPanel'), False)
        assert bench('panels', 'add', a, b, 'right')['accepted']
        split([b, c, a], a)
        press('movePanelOut')
        split([b, c], a, held=b)

        print('separate: menu, then key', flush=True)
        bench('select', b)
        split([b, c], b)
        assert menu('separatePanels')
        s.wait_for('menu separates', lambda: dict(groups=groups(), active=active()), dict(groups=[], active=b))
        assert bench('panels', 'add', c, b, 'right')['accepted']
        split([b, c], c)
        press('separatePanels')
        s.wait_for('key separates', lambda: dict(groups=groups(), active=active()), dict(groups=[], active=c))
        for action in KEYS:
            s.require(f'{TITLES[action]} disabled once separated', menu(action), False)
        s.require('every page stayed', len(s.tabs()), count)
        print('ok: keys and Tabs menu walk, swap, move out and separate a split; disabled without one')


if __name__ == '__main__':
    run()
