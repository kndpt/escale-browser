#!/usr/bin/env python3
"""Each bookmark is a button to VoiceOver, in the column and in the panel.

Reads the accessibility tree from outside, as VoiceOver and Full Keyboard
Access do, with tab_access.py's helpers. In the column: the Bookmarks heading
and a folder are buttons that say whether they are open and fold on a press;
an open bookmark says whether it is on screen, offers Copy Link, Close Tab and
its menu, and a press opens it again once closed; its environment is an action
of its own. Then the strip's door opens the menu, whose Manage Bookmarks… is
pressed, and the panel's folder and site rows are pressed the same way.
Needs Accessibility access for the app that runs this script. Not covered:
Sleeping in the value (BookmarkAccessTests), how VoiceOver speaks it, and the
Full Keyboard Access key that lists actions. Run after ./build.sh debug; the
world is owned by the shared runner and pages are served from loopback. The
seeded sites are never pressed, so nothing leaves this Mac.
"""
import json
import subprocess
from http.server import ThreadingHTTPServer
from threading import Thread
import suite as h
from tab_access import AX, Page, app, bench, labelled, offered, perform

FOLDING = ('Expanded', 'Collapsed')


def one(root, title, keep=lambda found: True):
    """The one button named `title` that `keep` accepts, once it is drawn."""
    def find():
        found = [f for f in labelled(root, title) if f['role'] == 'AXButton' and keep(f)]
        return found[0] if len(found) == 1 else None
    return h.until(f'one button named {title}', find, 15)


def row(title):
    return next((r for r in bench('shelf')['rows'] if r['title'] == title), None)


def panels():
    probe = bench('probe')
    return {'panel': probe['bookmarks'], 'menu': probe['bookmarksDropdown']}


def column(root, origin):
    url = f'{origin}/kept'
    h.open_ordinary(url)
    bench('shelf', 'keep')
    bench('shelf', 'seed')

    heading = one(root, 'Bookmarks', lambda f: f['value'] in FOLDING)
    h.require('the heading says it is open', heading['value'], 'Expanded')
    perform(heading, 'AXPress')
    h.wait_for('its press folds the bookmarks', lambda: {'folded': bench('shelf')['folded']}, {'folded': True})
    h.until('the heading says it is shut', lambda: one(root, 'Bookmarks', lambda f: f['value'] in FOLDING)['value'] == 'Collapsed', 10)
    perform(one(root, 'Bookmarks', lambda f: f['value'] in FOLDING), 'AXPress')
    h.wait_for('a second press unfolds them', lambda: {'folded': bench('shelf')['folded']}, {'folded': False})

    # The seed's sites come in a folder of their own.
    folder = one(root, 'Bench')
    h.require('a shut folder says so', folder['value'], 'Collapsed')
    perform(folder, 'AXPress')
    h.wait_for('its press opens the folder', lambda: {'open': row('Bench')['open']}, {'open': True})
    h.until('the folder says it is open', lambda: one(root, 'Bench')['value'] == 'Expanded', 10)
    h.require('a folder inside is a button too', one(root, 'Reading')['value'], 'Collapsed')

    site = one(root, 'kept')
    h.require('the bookmark on screen says so', site['value'], 'Active')
    for action in ('Copy Link', 'Close Tab', 'AXShowMenu'):
        h.require(f'the open bookmark offers {action}', offered(site, action) is not None, True)
    h.open_ordinary(f'{origin}/other')
    h.until('the bookmark behind says it is open', lambda: one(root, 'kept')['value'] == 'Open', 10)

    perform(one(root, 'kept'), 'Copy Link')
    h.wait_for('Copy Link copies its address',
               lambda: {'said': bench('probe')['announcement']}, {'said': f'Link copied: {url}'})
    perform(one(root, 'kept'), 'Close Tab')
    h.wait_for('Close Tab closes its tab', lambda: {'tab': row('kept')['tab']}, {'tab': False})
    h.until('a shut bookmark has no state', lambda: one(root, 'kept')['value'] == '', 10)
    h.require('a shut bookmark offers no Copy Link', offered(one(root, 'kept'), 'Copy Link'), None)
    perform(one(root, 'kept'), 'AXPress')
    h.wait_for('its press opens it again', lambda: {'tab': row('kept')['tab'], 'live': row('kept')['live']},
               {'tab': True, 'live': True})

    bench('environments', 'kept', 'set', json.dumps([{'name': 'Local', 'url': f'{origin}/local'}]))
    perform(one(root, 'kept'), 'Open LOCAL')
    h.until('its environment opens from its action', lambda: h.at(f'{origin}/local') is not None, 15)


def panel(root, origin):
    bench('ui', 'sidebar', 'off')
    h.open_ordinary(f'{origin}/elsewhere')
    door = one(root, 'Bookmarks', lambda f: f['value'] not in FOLDING)
    perform(door, 'AXPress')
    h.wait_for('the door opens the menu', panels, {'panel': False, 'menu': True})
    perform(one(root, 'Manage Bookmarks…'), 'AXPress')
    h.until('its foot opens the panel', lambda: panels()['panel'], 10)
    # The menu stays up over the panel, as it does for the pointer; the door shuts it.
    perform(door, 'AXPress')
    h.wait_for('the door shuts the menu', panels, {'panel': True, 'menu': False})

    folder = one(root, 'Bench')
    h.require('a folder in the panel is shut', folder['value'], 'Collapsed')
    perform(folder, 'AXPress')
    h.until('its press opens it', lambda: one(root, 'Bench')['value'] == 'Expanded', 10)
    one(root, 'WebKit')
    perform(one(root, 'kept'), 'AXPress')
    h.until('a site opens from the panel', lambda: h.at(f'{origin}/kept') is not None, 15)
    h.wait_for('and the panel closes', panels, {'panel': False, 'menu': False})
    perform(door, 'AXPress')
    h.wait_for('the door opens the menu again', panels, {'panel': False, 'menu': True})
    if one(root, 'Bench')['value'] == 'Collapsed':
        perform(one(root, 'Bench'), 'AXPress')
    # The menu reads each bookmark's tab as the column does: the one just
    # opened is on screen, the one opened earlier is open behind it.
    h.until('the menu says which bookmark is on screen and which is open',
            lambda: sorted(f['value'] for f in labelled(root, 'kept') if f['role'] == 'AXButton') == ['Active', 'Open'], 10)
    perform(door, 'AXPress')
    h.wait_for('the door shuts it', panels, {'panel': False, 'menu': False})


def main():
    if not AX.AXIsProcessTrusted():
        raise AssertionError('this script needs Accessibility access for the app that runs it '
                             '(System Settings › Privacy & Security › Accessibility)')
    server = ThreadingHTTPServer(('127.0.0.1', 0), Page)
    Thread(target=server.serve_forever, daemon=True).start()
    origin = f'http://127.0.0.1:{server.server_port}'
    kept = subprocess.run(['pbpaste'], capture_output=True, text=True, timeout=5).stdout
    try:
        with h.world(server):
            h.launch()
            bench('resize', 1180, 800)
            root = app()
            bench('ui', 'sidebar', 'on')
            bench('ui', 'shelf', 'on')
            column(root, origin)
            panel(root, origin)
            print('PASS: every bookmark and folder is a button, in the column and the panel')
    finally:
        subprocess.run(['pbcopy'], input=kept, text=True, timeout=5)


if __name__ == '__main__':
    main()
