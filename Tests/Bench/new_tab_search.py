#!/usr/bin/env python3
"""New Tab recent tabs and bookmark environments, through real keyboard events.

Uses suite.py's unique world/launcher and a local page counter. Assertions cover
focus order, exact destinations, no duplicate/reload, private isolation, closing,
sleep and Space changes.
"""
import json
from urllib.parse import parse_qs, urlsplit
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


def press(code, chars, *mods):
    return bench('press', str(code), chars, *mods)


def active():
    return next(tab for tab in s.tabs() if tab['active'])


def observed():
    """Where the keyboard, the chosen row and the page stand, for a failure."""
    state = bench('probe')
    return {'picked': state['picked'], 'fieldFocused': state['fieldFocused'],
            'fieldShowing': state['fieldShowing'], 'typed': state['typed'],
            'offers': [(x['kind'], x['url']) for x in state['offerDetails']],
            'tab': active()['id'], 'url': active()['url']}


def walk_down():
    """Down to the first row, and wait until it is the chosen one.

    The press call answers after a fixed 0.4 s, not when the field has taken the
    key. A Down the field did not take, followed by Return, submits the typed
    words instead; waiting here fails on the missing choice with
    the state, not ten seconds later on a page that never loaded.
    """
    press(125, '\uf701')
    s.wait_for('Down chooses the first row', observed, {'picked': 0}, 5)


def enter_environments():
    """The right arrow at the end of the line enters the environments; a first
    one may only take the grey completion after the caret."""
    press(124, '\uf703')
    if not bench('probe')['environmentFocused']:
        press(124, '\uf703')


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Page)
    Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    urls = [base + '/' + name for name in ('old', 'second', 'third', 'fourth')]
    environments = [{'name': 'PROD', 'url': base + '/prod', 'colour': 'rose'},
                    {'name': 'DEV', 'url': base + '/dev?chosen=1#start', 'colour': 'blue'},
                    {'name': 'STAGING', 'url': base + '/staging'}]
    with s.world(server):
        folder = s.SOCKET.parent
        folder.mkdir(parents=True, exist_ok=True)
        (folder / 'bookmarks.json').write_text(json.dumps([
            {'id': '45C67F3B-0714-445A-9EE5-4EFA75599BBC', 'title': 'Project Atlas',
             'url': base + '/prod', 'environments': [dict(item, id=f'45C67F3B-0714-445A-9EE5-4EFA75599BB{i}') for i, item in enumerate(environments)]}]))
        s.launch()
        bench('ui', 'welcome', 'off')
        bench('resize', '1100', '760')
        bench('ui', 'sidebar', 'off')
        s.require('first launch has no recents', bench('probe')['offers'], [])
        ids = []
        for url in urls:
            bench('field', url, 'go')
            ids.append(active()['id'])
            bench('wait', ids[-1], '10')
            before = len(s.tabs())
            press(17, 't', 'cmd')
            s.require('Cmd T opens only search', len(s.tabs()), before)
            s.require('Cmd T keeps the page underneath', active()['id'], ids[-1])
            s.require('search has pending new tab intent', bench('probe')['openingTab'], True)
        bench('select', ids[0])
        press(17, 't', 'cmd')
        state = bench('probe')
        s.require('new tab keyboard focus', state['fieldFocused'], True)
        s.require('three recent rows', len(state['offers']), 3)
        s.require('three most recently visited tabs', [x['id'][:8].lower() for x in state['offerDetails']], [ids[0], ids[3], ids[2]])
        s.require('open result identity', [x['kind'] for x in state['offerDetails']], ['open'] * 3)
        count, loads = len(s.tabs()), requests.count('/old')
        views = bench('space')['pages']
        for _ in range(12):
            press(53, '\x1b')
            s.require('Escape closes only search', bench('probe')['fieldShowing'], False)
            press(17, 't', 'cmd')
        s.require('repeated opening creates no tabs', len(s.tabs()), count)
        s.require('repeated opening creates no pages', bench('space')['pages'], views)
        s.require('underlying page is never reloaded', requests.count('/old'), loads)
        press(13, 'w', 'cmd')
        s.require('Cmd W dismisses pending search', len(s.tabs()), count)
        s.require('Cmd W keeps the current page', active()['id'], ids[0])
        press(17, 't', 'cmd')
        walk_down()
        press(36, '\r')
        s.require('Return selects the existing tab', active()['id'], ids[0])
        s.require('returning to current tab dismisses search', bench('probe')['fieldShowing'], False)
        s.require('no duplicate tab', len(s.tabs()), count)
        s.require('no reload', requests.count('/old'), loads)
        press(17, 't', 'cmd')
        bench('field', 'Suite fourth', 'type')
        s.require('typing finds an open tab', bench('probe')['offerDetails'][0]['id'][:8].lower(), ids[3])
        walk_down()
        press(36, '\r')
        s.require('query Return selects existing tab', active()['id'], ids[3])
        press(13, 'w', 'cmd')
        press(17, 't', 'cmd')
        assert ids[3] not in [x['id'][:8].lower() for x in bench('probe')['offerDetails']]
        for term in ('fourth', 'FoUrT', 'Suite fourth'):
            bench('field', term, 'type')
            results = bench('probe')['offerDetails']
            assert any(x['kind'] == 'visited' and x['url'] == urls[3] for x in results), results
        walk_down()
        press(36, '\r')
        s.require('history Return reopens the closed page', active()['url'], urls[3])
        press(13, 'w', 'cmd')
        bench('select', ids[0])
        press(17, 't', 'cmd')
        bench('sleep', ids[2])
        bench('field', 'Suite third', 'type')
        assert next(x for x in s.tabs() if x['id'] == ids[2])['asleep']
        walk_down()
        press(36, '\r')
        s.require('sleeping result selected', active()['id'], ids[2])
        bench('wait', ids[2], '10')
        press(17, 't', 'cmd')
        bench('field', 'Project Atlas', 'type')
        s.require('bookmark has configured environments', bench('probe')['offerDetails'][0]['environments'], ['PROD', 'DEV', 'STAGING'])
        enter_environments()
        state = bench('probe')
        s.require('Right enters selector', state['environmentFocused'], True)
        s.require('default environment is visible', state['environment'], 'PROD')
        press(124, '\uf703')
        s.require('Right advances to DEV', bench('probe')['environment'], 'DEV')
        press(124, '\uf703')
        s.require('Right advances to STAGING', bench('probe')['environment'], 'STAGING')
        press(124, '\uf703')
        s.require('Right wraps to PROD', bench('probe')['environment'], 'PROD')
        s.require('Right keeps environment focus', bench('probe')['environmentFocused'], True)
        s.require('Right keeps query', bench('probe')['typed'], 'Project Atlas')
        press(123, '\uf702')
        s.require('Left wraps to STAGING', bench('probe')['environment'], 'STAGING')
        press(123, '\uf702')
        s.require('Left goes back to DEV', bench('probe')['environment'], 'DEV')
        # Standard 1100×760 fixture: the field's top is fixed at 28 % of the
        # page's height, and STAGING sits inside this selected row at this
        # window position (measured: y 332–359). A chip click must
        # change only the choice, never activate the row underneath it.
        behind = active()['id']
        bench('hit', '487', '345', 'click', 'live')
        s.require('inline chip click chooses STAGING', bench('probe')['environment'], 'STAGING')
        s.require('chip click does not navigate', active()['id'], behind)
        s.require('chip click keeps search', bench('probe')['openingTab'], True)
        press(123, '\uf702')
        s.require('keyboard resumes after chip click', bench('probe')['environment'], 'DEV')
        press(53, '\x1b')
        state = bench('probe')
        s.require('Escape leaves environment focus', state['environmentFocused'], False)
        s.require('Escape keeps New Tab', state['fieldShowing'], True)
        s.require('Escape keeps query', state['typed'], 'Project Atlas')
        enter_environments()
        press(123, '\uf702')
        s.require('Left wraps to STAGING', bench('probe')['environment'], 'STAGING')
        press(124, '\uf703')
        press(124, '\uf703')
        press(123, '\uf702')
        s.require('Left goes back to PROD', bench('probe')['environment'], 'PROD')
        s.require('Left keeps environment focus', bench('probe')['environmentFocused'], True)
        press(124, '\uf703')
        s.require('Right chooses DEV before Return', bench('probe')['environment'], 'DEV')
        press(36, '\r')
        s.until('exact environment URL', lambda: active()['url'] == environments[1]['url'], 10)
        chosen = active()['id']
        bench('wait', chosen, '10')
        # A linked open bookmark keeps its active environment in recent and
        # typed results. Return still switches to it; only an explicit choice
        # changes its environment, in the same page.
        press(17, 't', 'cmd')
        current = bench('probe')['offerDetails'][0]
        s.require('recent linked bookmark badge', current['activeEnvironment'], 'DEV')
        assert current['bookmark']
        bench('field', 'chosen', 'type')
        walk_down()
        s.require('typed open bookmark keeps badge', bench('probe')['offerDetails'][0]['activeEnvironment'], 'DEV')
        before_loads = requests.count('/dev?chosen=1')
        press(36, '\r')
        s.require('plain Return keeps active environment', active()['url'], environments[1]['url'])
        s.require('plain Return keeps linked tab', active()['id'], chosen)
        s.require('plain Return never reloads it', requests.count('/dev?chosen=1'), before_loads)
        bench('select', ids[0])
        press(40, 'k', 'cmd')
        switcher = bench('probe')
        s.require('switcher retains linked badge', switcher['offerDetails'][0]['activeEnvironment'], 'DEV')
        press(48, '\t')
        s.require('Cmd K Tab switches to GitHub', bench('probe')['github']['open'], True)
        s.require('Cmd K Tab does not enter environments', bench('probe')['environmentFocused'], False)
        press(48, '\t')
        s.require('Tab switches back to Tabs', bench('probe')['github']['open'], False)
        press(53, '\x1b')
        bench('select', chosen)
        press(17, 't', 'cmd')
        bench('field', 'chosen', 'type')
        enter_environments()
        s.require('Right starts at active environment', bench('probe')['environment'], 'DEV')
        press(124, '\uf703')
        press(36, '\r')
        s.until('open bookmark changes environment', lambda: active()['url'] == base + '/staging', 10)
        s.require('environment choice keeps linked tab', active()['id'], chosen)
        bench('bookmark', base + '/staging', 'new')
        press(17, 't', 'cmd')
        plain = bench('probe')['offerDetails'][0]
        s.require('same URL ordinary tab has no badge', plain['activeEnvironment'], '')
        s.require('same URL ordinary tab has no bookmark link', plain['bookmark'], '')
        press(53, '\x1b')
        press(13, 'w', 'cmd')
        bench('select', chosen)
        press(17, 't', 'cmd')
        bench('field', 'Project Atlas', 'type')
        walk_down()
        press(36, '\r')
        s.wait_for('normal Return opens bookmark default', observed, {'url': base + '/prod'}, 10)
        s.require('default keeps the bookmark page identity', active()['id'], chosen)
        # The maximum saved list keeps its last value reachable without widening
        # the panel; changing configuration while visible clears stale focus.
        press(17, 't', 'cmd')
        many = [{'name': f'Environment {i:02d} with a deliberately long project label',
                 'url': base + f'/environment/{i:02d}'} for i in range(20)]
        bench('environments', 'Project Atlas', 'set', json.dumps(many))
        bench('field', 'Project Atlas', 'type')
        enter_environments()
        press(123, '\uf702')
        s.require('last of twenty environments reachable', bench('probe')['environment'], many[-1]['name'].upper())
        press(124, '\uf703')
        s.require('twenty environments wrap back to first', bench('probe')['environment'], many[0]['name'].upper())
        bench('environments', 'Project Atlas', 'set', json.dumps(environments))
        s.require('updated bookmark clears stale environment focus', bench('probe')['environmentFocused'], False)
        # Private search must neither reveal nor reuse ordinary recent pages.
        private_count = len(s.tabs())
        press(45, 'n', 'cmd', 'shift')
        s.require('private search defers creation too', len(s.tabs()), private_count)
        s.require('private intent is explicit', bench('probe')['searchPrivate'], True)
        s.require('private recents exclude ordinary tabs', bench('probe')['offers'], [])
        bench('field', 'FoUrT', 'type')
        assert any(x['kind'] == 'visited' and x['url'] == urls[3] for x in bench('probe')['offerDetails'])
        bench('field', 'Project Atlas', 'type')
        enter_environments()
        press(124, '\uf703')
        press(36, '\r')
        s.until('private environment URL', lambda: active()['url'] == environments[1]['url'], 10)
        assert active()['id'] != chosen and active()['shy']
        s.require('private destination creates exactly one tab', len(s.tabs()), private_count + 1)
        private_id = active()['id']
        press(17, 't', 'cmd')
        s.require('Cmd T from private page keeps private context', bench('probe')['searchPrivate'], True)
        press(53, '\x1b')
        s.require('private Escape keeps the page', active()['id'], private_id)
        press(17, 't', 'cmd')
        press(37, 'l', 'cmd')
        s.require('Cmd L cancels new tab intent', bench('probe')['openingTab'], False)
        bench('field', base + '/private-edit', 'go')
        s.require('Cmd L edits the same private tab', active()['id'], private_id)
        s.require('Cmd L preserves tab count', len(s.tabs()), private_count + 1)
        bench('wait', private_id, '10')
        press(13, 'w', 'cmd')
        press(17, 't', 'cmd')
        bench('field', 'private-edit', 'type')
        assert not any(x['kind'] in ('visited', 'open') for x in bench('probe')['offerDetails'])
        press(17, 't', 'cmd')
        bench('ui', 'spaces', 'on')
        bench('space', 'new', 'Empty')
        s.require('Space change clears pending new-tab intent', bench('probe')['openingTab'], False)
        s.require('new Space has no recent tabs', bench('probe')['offers'], [])
        bench('field', 'FoUrT', 'type')
        assert not any(x['kind'] == 'visited' for x in bench('probe')['offerDetails'])
        bench('field', 'Project Atlas', 'type')
        assert not any(x['kind'] == 'bookmark' for x in bench('probe')['offerDetails'])
        bench('field', base + '/sole-pin', 'go')
        pin = active()['id']
        bench('wait', pin, '10')
        bench('pin', pin, 'on')
        press(13, 'w', 'cmd')
        s.require('closing the last pin leaves it sleeping behind search', active()['asleep'], True)
        s.require('last pin close creates no blank tab', len(s.tabs()), 1)
        walk_down()
        press(36, '\r')
        s.require('choosing the same sleeping pin wakes it', active()['asleep'], False)
        s.require('pin identity survives', active()['id'], pin)
        # Words typed apart find a page named with dashes: open tab,
        # ⌘K and, once closed, history; the search row keeps the typed text.
        words_url = base + '/iso--checkout--orchestrator-handlers'
        press(17, 't', 'cmd')
        bench('field', words_url, 'go')
        named = active()['id']
        assert named != pin
        bench('wait', named, '10')
        bench('select', pin)
        press(17, 't', 'cmd')
        typed = 'Orchestrator   handlers'
        bench('field', typed, 'type')
        state = bench('probe')
        first, last = state['offerDetails'][0], state['offerDetails'][-1]
        s.require('words find the open tab', (first['kind'], first['id'][:8].lower()), ('open', named))
        s.require('web search is last', last['kind'], 'search')
        asked = [v for values in parse_qs(urlsplit(last['url']).query).values() for v in values]
        assert typed in asked, last['url']
        s.require('field keeps the typed text', state['typed'], typed)
        walk_down()
        press(36, '\r')
        s.require('Return selects the tab found by words', active()['id'], named)
        s.require('its address is unchanged', active()['url'], words_url)
        bench('select', pin)
        press(40, 'k', 'cmd')
        bench('field', 'orchestrator hand', 'type')
        s.require('Cmd K finds by words', bench('probe')['offerDetails'][0]['url'], words_url)
        # "suite" is only in the title, "127" only in the address.
        bench('field', 'suite 127 handl', 'type')
        s.require('words spread across title and address', bench('probe')['offerDetails'][0]['url'], words_url)
        press(53, '\x1b')
        bench('select', named)
        press(13, 'w', 'cmd')
        press(17, 't', 'cmd')
        bench('field', 'orchestrator handlers', 'type')
        assert any(x['kind'] == 'visited' and x['url'] == words_url for x in bench('probe')['offerDetails'])
        bench('field', 'orchestrator gateway', 'type')
        s.require('every word is required', [x['kind'] for x in bench('probe')['offerDetails']], ['search'])
        press(53, '\x1b')
        print('ok: words across separators, linked environment badges, inline mouse/keyboard choices, deferred tabs, repeated cancel without pages, current/existing tab reuse, recency, sleeping tabs, environment keyboard, private and Space isolation')


if __name__ == '__main__':
    main()
