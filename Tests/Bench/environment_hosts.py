#!/usr/bin/env python3
"""Host labels stay local to linked bookmarks without loading sleeping pages.

Loopback navigation exercises the shared badge rule in search and capture,
including ambiguous endpoints and priority over newer ordinary tabs.
The shared runner owns the random test world and cleanup on every exit.
"""
import json
from http.server import ThreadingHTTPServer
from threading import Thread
import suite as s

requests = []


class Page(s.Page):
    def do_GET(self):
        requests.append(self.path)
        super().do_GET()


def bench(*args):
    return json.loads(s.command(str(s.ROOT / 'bench'), '--world', s.WORLD, '--json', *args))


def entries(*args, name='WebKit'):
    return bench('environments', name, *args)


def press(code, chars, *mods):
    return bench('press', str(code), chars, *mods)


def capture_context(tab, label):
    bench('page-capture', tab, json.dumps({'action': 'take', 'mode': 'visible'}))
    state = s.until('capture completion', lambda: (v if not v['busy'] else None)
                    if (v := bench('page-capture', tab)) else None)
    s.require('capture succeeded', state['failure'], '')
    assert state['bytes'] > 0, state
    actual = [line for line in state['context'].splitlines() if line.startswith('Environment')]
    s.require('capture environment', actual, ['Environment (unverified label): ' + label] if label else [])
    bench('page-capture', tab, json.dumps({'action': 'close'}))


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Page)
    Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    alternate = f'http://localhost:{server.server_port}'
    saved = [{'name': 'PROD', 'url': base + '/app?chosen=1#start'},
             {'name': 'PREP', 'url': alternate + '/', 'colour': 'blue'}]
    with s.world(server):
        s.launch()
        bench('resize', '1100', '760')
        bench('ui', 'sidebar', 'on')
        bench('shelf', 'seed')
        entries('set', json.dumps(saved))
        entries('set', json.dumps([dict(saved[1], name='OTHER')]), name='Swift')
        opened = entries('open', 'PREP')
        tab = opened['tab'][:8].lower()
        s.loaded_page(tab, 'home', 15, 'saved root')
        for path in ['/', '/unloading-tasks', '/next?x=2#fragment']:
            bench('field', alternate + path, 'go')
            s.loaded_page(tab, path.strip('/').split('#')[0] or 'home', 15, 'host route')
            s.require('host badge', entries()['badge'], 'PREP')
        s.require('another bookmark cannot borrow the link', entries(name='Swift')['badge'], '')

        for sidebar in ('on', 'off'):
            bench('ui', 'sidebar', sidebar)
            press(17, 't', 'cmd')
            s.require('search shares host badge', bench('probe')['offerDetails'][0]['activeEnvironment'], 'PREP')
            press(125, '\uf701')
            s.require('walking onto the row rings the host environment', bench('probe')['environmentFocused'], True)
            press(124, '\uf703')
            press(123, '\uf702')
            s.require('selector starts at host environment', bench('probe')['environment'], 'PREP')
            press(53, '\x1b')
            press(53, '\x1b')
            press(53, '\x1b')

        capture_context(tab, 'PREP')

        # Choosing a destination still opens its stored route, in the same tab.
        s.require('destination retains tab', entries('open', 'PROD')['tab'], opened['tab'])
        s.loaded_page(tab, 'app?chosen=1', 15, 'saved destination')
        s.require('saved URL unchanged', entries()['address'], saved[0]['url'])
        shared = saved + [{'name': 'SECOND', 'url': base + '/second'}]
        entries('set', json.dumps(shared))
        s.require('exact URL disambiguates', entries()['badge'], 'PROD')
        bench('field', base + '/unknown', 'go')
        s.loaded_page(tab, 'unknown', 15, 'ambiguous route')
        s.require('ambiguous host has no badge', entries()['badge'], '')
        capture_context(tab, '')
        # One console endpoint, three clusters: each path claim follows its own
        # subpages, queries and fragments; a neighbouring name or a route
        # outside every claim shows none, and another host cannot borrow one.
        clusters = [{'name': name, 'url': base + f'/console/cluster-{name.lower()}/home', 'depth': 2}
                    for name in ('PROD', 'DEV', 'STAGING')]
        entries('set', json.dumps(clusters))
        for name, route in [('PROD', '/console/cluster-prod/home'), ('PROD', '/console/cluster-prod/topics?x=1#part'),
                            ('DEV', '/console/cluster-dev/topics'), ('STAGING', '/console/cluster-staging/home#top'),
                            ('', '/console/cluster-production/home'), ('', '/console/'), ('PROD', '/console/cluster-prod')]:
            bench('field', base + route, 'go')
            s.loaded_page(tab, route.split('#')[0].strip('/'), 15, 'console route')
            s.require('path badge at ' + route, entries()['badge'], name)
        capture_context(tab, 'PROD')
        bench('field', alternate + '/console/cluster-prod/home', 'go')
        s.loaded_page(tab, 'console/cluster-prod/home', 15, 'other host')
        s.require('path claim stays on its host', entries()['badge'], '')
        entries('set', json.dumps(shared))
        bench('field', 'data:text/html,<title>Outside</title>', 'go')
        s.until('outside navigation', lambda: entries()['address'].startswith('data:'))
        s.require('outside configured hosts', entries()['badge'], '')
        entries('open', 'PREP')
        s.loaded_page(tab, 'home', 15, 'return to configured host')
        bench('field', alternate + '/sleeping', 'go')
        s.loaded_page(tab, 'sleeping', 15, 'sleeping route')

        bench('bookmark', alternate + '/sleeping', 'new')
        ordinary = next(t['id'] for t in s.tabs() if t['active'])
        s.loaded_page(ordinary, 'sleeping', 15, 'unlinked page')
        capture_context(ordinary, '')
        press(17, 't', 'cmd')
        row = bench('probe')['offerDetails'][0]
        s.require('unlinked page has no badge', row['activeEnvironment'], '')
        s.require('unlinked page has no bookmark', row['bookmark'], '')
        press(53, '\x1b')
        bench('sleep', tab)
        s.require('linked page is asleep', entries()['built'], False)
        count, views = len(requests), bench('space')['pages']
        for sidebar in ('on', 'off'):
            bench('ui', 'sidebar', sidebar)
            entries('set', json.dumps(saved))
            s.require('sleeping host badge', entries()['badge'], 'PREP')
            press(17, 't', 'cmd')
            linked = next(r for r in bench('probe')['offerDetails'] if r['bookmark'])
            s.require('sleeping search badge', linked['activeEnvironment'], 'PREP')
            press(53, '\x1b')
        s.require('inspection creates no page', bench('space')['pages'], views)
        s.require('inspection sends no request', len(requests), count)
        s.require('inspection does not wake page', entries()['built'], False)
        # Older linked tabs must survive the three-open-result cutoff. A
        # matching closed bookmark also precedes ordinary tabs and history.
        recent = []
        for index in range(4):
            bench('bookmark', alternate + f'/recent/{index}', 'new')
            newest = next(t['id'] for t in s.tabs() if t['active'])
            recent.append(newest)
            s.loaded_page(newest, f'recent/{index}', 15, 'newer ordinary tab')
        count, views = len(requests), bench('space')['pages']
        press(17, 't', 'cmd')
        s.require('empty query retains most recent tab', bench('probe')['offerDetails'][0]['id'][:8].lower(), newest)
        bench('field', 'localhost', 'type')
        rows = bench('probe')['offerDetails']
        s.require('older environment tab ranks first', rows[0]['id'][:8].lower(), tab)
        s.require('first result remains linked', rows[0]['activeEnvironment'], 'PREP')
        assert all(row['environments'] for row in rows[:3]), rows
        assert len([r for r in rows if r['kind'] != 'search']) <= 6, rows
        s.require('priority does not select background tab', next(t['id'] for t in s.tabs() if t['active']), newest)
        s.require('priority does not wake linked page', entries()['built'], False)
        s.require('priority creates no page', bench('space')['pages'], views)
        s.require('priority sends no request', len(requests), count)
        bench('field', 'no-matching-fixture', 'type')
        assert not any(r['environments'] for r in bench('probe')['offerDetails'])
        press(53, '\x1b')
        press(40, 'k', 'cmd')
        bench('field', 'localhost', 'type')
        s.require('switcher keeps the most recent other tab first', bench('probe')['offerDetails'][0]['id'][:8].lower(), recent[-2])
        press(53, '\x1b')
        bench('ui', 'spaces', 'on')
        source = entries()
        bench('space', 'duplicate', 'Independent')
        bench('space', 'go', '2')
        # The copy owns a new bookmark with its own destinations and its own
        # linked tab; the badge is read from those copied values.
        copied = entries()
        assert copied['id'] != source['id'], (source, copied)
        assert copied['tab'] and copied['tab'] != source['tab'], (source, copied)
        s.require('Space copy keeps destinations', copied['entries'], source['entries'])
        s.require('Space copy badges its own linked tab', copied['badge'], 'PREP')
        s.require('Space copy remains unloaded', copied['built'], False)
        print('ok: host routes, path claims on a shared console, both layouts, selector, capture context, saved destinations, ambiguity, independent Space copy with its linked tab and sleeping pages without requests; matching environments precede newer ordinary results')


if __name__ == '__main__':
    main()
