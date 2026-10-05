#!/usr/bin/env python3
"""Bearings learns from the rows taken, in the app, by real keys.

Uses suite.py's owned world and a loopback server whose pages are titled
"Suite handlers-…". Four pages visited 5, 3, 2 and 1 times answer `handlers`
in that order; the scenario checks that walking teaches nothing, that a row
taken by Return and one taken by its own click action lead the next `handlers`
without touching another query, that a changed habit wins, that a bookmark's
environment choice counts for its row, that private search learns nothing,
and that what was learned survives a relaunch, goes with Clear History and
stays in its Space, whose deletion takes its file.
"""
import json
import time
from http.server import ThreadingHTTPServer
from threading import Thread
import suite as s

FIRST_SPACE = '00000000-0000-0000-0000-000000000001'
NAMES = ('alpha', 'beta', 'gamma', 'delta')
ONE, TWO = '2F0C9A43-94B6-4F56-8C55-0B8E0B1D0A01', '2F0C9A43-94B6-4F56-8C55-0B8E0B1D0A02'


def bench(*args):
    return json.loads(s.command(str(s.ROOT / 'bench'), '--world', s.WORLD, '--json', *args))


def press(code, chars, *mods):
    return bench('press', str(code), chars, *mods)


def active():
    return next(tab for tab in s.tabs() if tab['active'])


def offers():
    return [x['url'] for x in bench('probe')['offerDetails']]


def habits(space=FIRST_SPACE):
    """What is on disk, once the coalesced write (1.5 s) has had its moment."""
    time.sleep(2.5)
    path = s.SOCKET.parent / f'habits-{space}.json'
    return json.loads(path.read_text()) if path.exists() else None


def ask(typed):
    """⌘T and the query typed a key at a time; the rows it offers."""
    press(17, 't', 'cmd')
    bench('field', typed, 'type')
    return offers()


def walk_to(index):
    for _ in range(index + 1):
        press(125, '')
    s.until('Down reaches the row', lambda: bench('probe')['picked'] == index, 5)


def close_new(before):
    """The tab a choice opened, closed again: the history keeps the page."""
    s.until('choice opened a page', lambda: len(s.tabs()) == before + 1, 10)
    bench('wait', active()['id'], '10')
    press(13, 'w', 'cmd')
    s.until('back to the tabs before', lambda: len(s.tabs()) == before, 10)


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), s.Page)
    Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    page = {name: f'{base}/handlers-{name}' for name in NAMES}
    with s.world(server):
        folder = s.SOCKET.parent
        folder.mkdir(parents=True, exist_ok=True)
        (folder / 'bookmarks.json').write_text(json.dumps([
            {'id': ONE, 'title': 'Atlas one', 'url': base + '/one',
             'environments': [{'id': ONE[:-2] + '11', 'name': 'PROD', 'url': base + '/one'},
                              {'id': ONE[:-2] + '12', 'name': 'DEV', 'url': base + '/one-dev'}]},
            {'id': TWO, 'title': 'Atlas two', 'url': base + '/two',
             'environments': [{'id': TWO[:-2] + '21', 'name': 'PROD', 'url': base + '/two'},
                              {'id': TWO[:-2] + '22', 'name': 'DEV', 'url': base + '/two-dev'}]}]))
        s.launch()
        bench('ui', 'welcome', 'off')
        bench('resize', '1100', '760')
        bench('ui', 'sidebar', 'off')
        for name, times in zip(NAMES, (5, 3, 2, 1)):
            for _ in range(times):
                bench('field', page[name], 'go')
                bench('wait', active()['id'], '10')
        bench('field', base + '/home', 'go')
        home = active()['id']
        bench('wait', home, '10')
        tabs = len(s.tabs())

        before = ask('handlers')
        s.require('frecency orders the pages', before[:4], [page[n] for n in NAMES])
        s.require('the web search is last', bench('probe')['offerDetails'][-1]['kind'], 'search')
        # Walking the list and leaving it teaches nothing.
        walk_to(3)
        press(126, '')
        press(53, '\x1b')
        s.require('walking learns nothing', ask('handlers'), before)
        press(53, '\x1b')
        s.require('nothing written for a walk', habits(), None)

        # Return on the fourth row: the next handlers leads with it; another
        # query does not move.
        ask('handlers')
        walk_to(3)
        press(36, '\r')
        close_new(tabs)
        learned = ask('handlers')
        s.require('the row taken by Return leads', learned[0], page['delta'])
        s.require('nothing added or lost', sorted(learned), sorted(before))
        s.require('another query is untouched', ask('handlers-')[0], page['alpha'])
        press(53, '\x1b')
        saved = habits()
        s.require('one query learned', [entry['query'] for entry in saved], ['handlers'])
        assert saved[0]['picks'][0]['to'].startswith('page:127.0.0.1/handlers-delta :'), saved

        # Taken twice by the row's click action: the changed habit wins.
        for _ in range(2):
            rows = ask('handlers')
            bench('row', str(rows.index(page['gamma'])))
            close_new(tabs)
        changed = ask('handlers')
        s.require('the habit changed on its second choice', changed[:2], [page['gamma'], page['delta']])
        press(53, '\x1b')

        # A bookmark's environment chosen: its row leads the next query. The
        # walk rings the environment the bookmark is on and the right arrow
        # chooses the next one; Tab would switch Bearings' mode instead.
        atlas = ask('atlas')
        s.require('bookmarks in their order', atlas[:2], [base + '/one', base + '/two'])
        walk_to(1)
        press(124, '')
        s.require('DEV chosen', bench('probe')['environment'], 'DEV')
        press(36, '\r')
        s.until('environment opened', lambda: active()['url'] == base + '/two-dev', 10)
        bench('wait', active()['id'], '10')
        press(13, 'w', 'cmd')
        bench('select', home)
        s.require('the chosen bookmark leads', ask('atlas')[0], base + '/two')
        press(53, '\x1b')
        known = habits()
        s.require('bookmark learned by identity', [p['to'] for e in known if e['query'] == 'atlas' for p in e['picks']],
                  ['bookmark:' + TWO])

        # Private search: the same rows, nothing learned.
        press(45, 'n', 'cmd', 'shift')
        s.require('private search', bench('probe')['searchPrivate'], True)
        bench('field', 'handlers', 'type')
        rows = offers()
        walk_to(rows.index(page['beta']))
        press(36, '\r')
        s.until('private page opened', lambda: active()['url'] == page['beta'] and active()['shy'], 10)
        press(13, 'w', 'cmd')
        bench('select', home)
        s.require('private choice not written', habits(), known)

        # A relaunch reads it back.
        s.command(str(s.ROOT / 'fresh.sh'), 'stop')
        s.launch()
        bench('ui', 'welcome', 'off')
        s.require('learned order after relaunch', ask('handlers')[:2], [page['gamma'], page['delta']])
        press(53, '\x1b')

        # Another Space learns apart, and takes its file when deleted.
        bench('ui', 'spaces', 'on')
        created = bench('space', 'new', 'Other')
        other = next(x['id'] for x in created['spaces'] if x['name'] == 'Other')
        bench('field', base + '/handlers-epsilon', 'go')
        bench('wait', active()['id'], '10')
        ask('epsilon')
        walk_to(0)
        press(36, '\r')
        mine = habits(other)
        s.require('learned in its own Space', [e['query'] for e in mine], ['epsilon'])
        assert all(e['query'] != 'epsilon' for e in habits()), 'another Space leaked in'
        bench('space', 'delete')
        s.require('a deleted Space takes its file', habits(other), None)

        # Clear History takes what was learned with it.
        bench('ui', 'clearHistory', 'on')
        s.require('cleared with the history', habits(), [])
        print('ok: walking learns nothing; Return and the row action lead the next query; '
              'a changed habit wins; environment choice counts; private learns nothing; '
              'relaunch, Space and Clear History')


if __name__ == '__main__':
    main()
