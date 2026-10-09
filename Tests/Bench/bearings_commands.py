#!/usr/bin/env python3
"""Bearings runs a browser command typed after `>`, by real keys.

Uses suite.py's owned world and a loopback page. ⌘T, then `> pin` typed a key
at a time, offers commands only, without Change Pinned Letter while the page
has no pin; Return pins the page underneath, closes Bearings and makes no tab.
The letter command is offered once there is a pin. Clicking a row, and each
command's own effect, are not covered here.
"""
import json
from http.server import ThreadingHTTPServer
from threading import Thread
import suite as s


def bench(*args):
    return json.loads(s.command(str(s.ROOT / 'bench'), '--world', s.WORLD, '--json', *args))


def press(code, chars, *mods):
    return bench('press', str(code), chars, *mods)


def active():
    return next(tab for tab in s.tabs() if tab['active'])


def state():
    probe = bench('probe')
    return {'opening': probe['openingTab'], 'focused': probe['fieldFocused'], 'showing': probe['fieldShowing'],
            'offers': probe['offers'], 'kinds': sorted({x['kind'] for x in probe['offerDetails']}),
            'picked': probe['picked'], 'pinned': bool(active()['pin']), 'tabs': len(s.tabs())}


def ask(typed):
    """⌘T and the query typed a key at a time."""
    press(17, 't', 'cmd')
    s.wait_for('Cmd T opens Bearings', state, {'opening': True, 'focused': True}, 5)
    bench('field', typed, 'type')
    return state()


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), s.Page)
    Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    with s.world(server):
        s.launch()
        bench('ui', 'welcome', 'off')
        bench('field', base + '/commands', 'go')
        page = active()['id']
        bench('wait', page, '10')
        tabs = len(s.tabs())

        asked = ask('> pin')
        s.require('commands only', asked['kinds'], ['command'])
        s.require('the matching command, chosen', (asked['offers'][0], asked['picked']), ('Pin or Unpin Tab', 0))
        assert 'Change Pinned Letter' not in asked['offers'], asked

        press(36, '\r')
        s.wait_for('Return runs the command and closes Bearings', state,
                   {'pinned': True, 'showing': False, 'opening': False, 'tabs': tabs}, 5)
        s.require('the page underneath stays', active()['id'], page)

        s.require('available once pinned', ask('> pinned letter')['offers'], ['Change Pinned Letter'])
        # Escape lets go of the chosen row, then closes, as in ⌘K.
        press(53, '\x1b')
        s.wait_for('Escape lets go of the row', state, {'picked': -1, 'showing': True}, 5)
        press(53, '\x1b')
        s.wait_for('Escape closes Bearings', state, {'showing': False, 'pinned': True, 'tabs': tabs}, 5)
        print('ok: > lists available commands only; Return runs one, closes Bearings, makes no tab')


if __name__ == '__main__':
    main()
