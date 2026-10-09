#!/usr/bin/env python3
"""Local GitHub Bearings with real keys and shared-memory observations.

Fixtures stamp failed-navigation metadata over built loopback pages. Only the
offered owner/repo#N is opened on github.com, and closed at once; assertions
about live status extraction/auth remain separate.
"""
import json
from http.server import ThreadingHTTPServer
from threading import Thread
import suite as s


def bench(*args):
    return json.loads(s.command(str(s.ROOT / 'bench'), '--world', s.WORLD, '--json', *args))


def github(**request):
    return bench('github', json.dumps(request))


def press(code, chars, *mods):
    return bench('press', str(code), chars, *mods)


def snapshot():
    return bench('probe')


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), s.Page)
    Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    url = 'https://github.com/fixture/browser/pull/'
    with s.world(server):
        s.launch()
        bench('resize', '1100', '760')
        bench('field', base + '/one', 'go')
        first = next(t for t in s.tabs() if t['active'])['id']
        bench('wait', first, '10')
        github(action='tab', url=url + '1/files#draft')
        press(17, 't', 'cmd')
        bench('field', base + '/two', 'go')
        second = next(t for t in s.tabs() if t['active'])['id']
        bench('wait', second, '10')
        github(action='tab', url=url + '2/commits')
        bench('select', first)
        github(action='history', entries=[
            {'url': url + '1', 'title': 'Fix keyboard', 'age': -10},
            {'url': url + '1/files', 'title': 'Review keyboard', 'age': -11},
            {'url': url + '2', 'title': 'Keyboard second', 'age': -20},
        ] + [{'url': url + str(i), 'title': 'Other change', 'age': -i * 10} for i in range(3, 15)]
          + [{'url': url + '15', 'title': 'Needle change', 'age': -300}])
        count, pages = len(s.tabs()), bench('space')['pages']
        press(40, 'k', 'cmd', 'shift')
        state = snapshot()
        s.require('GitHub shortcut takes focus', state['fieldFocused'], True)
        s.require('mode is real GitHub search', state['github']['open'], True)
        s.require('opening does not create a tab', len(s.tabs()), count)
        s.require('opening does not build a page', bench('space')['pages'], pages)
        s.require('group before six-row cut', len(state['github']['rows']), 6)
        s.require('active tab offered', state['github']['rows'][0]['tab'], True)
        s.require('subview preserved', state['github']['rows'][0]['url'], url + '1/files#draft')
        bench('field', 'Needle')
        s.require('search beyond six candidates', [r['number'] for r in github()['rows']], [15])
        bench('field', 'keyboard')
        github(action='back')
        s.require('back preserves text', snapshot()['typed'], 'keyboard')
        press(40, 'k', 'cmd', 'shift')
        s.require('mode switch preserves text', snapshot()['typed'], 'keyboard')
        picked = github()['picked']
        press(40, 'k', 'cmd', 'shift')
        s.require('asking again keeps the open search', (snapshot()['typed'], github()['picked']), ('keyboard', picked))
        github(action='memory')
        press(125, '\uf701')
        before = github()
        github(action='observe', number=1, state='merged')
        after = github()
        s.require('reply changes shared reading', after['rows'][0]['state'], 'merged')
        s.require('reply does not reorder', [r['id'] for r in after['rows']], [r['id'] for r in before['rows']])
        s.require('reply preserves selection', after['picked'], before['picked'])
        press(36, '\r')
        s.require('Return resumes exact existing tab', next(t for t in s.tabs() if t['active'])['id'], second)
        s.require('Return creates no duplicate', len(s.tabs()), count)
        s.require('Return retains built page', bench('space')['pages'], pages)
        s.require('resume dismisses search', snapshot()['fieldShowing'], False)
        bench('select', first)
        press(40, 'k', 'cmd', 'shift')
        bench('field', 'no-such-local-issue')
        press(36, '\r')
        s.require('no match stays local', len(s.tabs()), count)
        s.require('no web-search fallback', snapshot()['github']['open'], True)
        press(53, '\x1b')
        s.require('one Escape closes GitHub', snapshot()['fieldShowing'], False)
        press(40, 'k', 'cmd', 'shift')
        bench('field', 'fixture/browser#1')
        state = github()
        s.require('known reference is the only offer', (state['offer'], state['rows'][0]['number']), ('', 1))
        bench('field', 'Octo/Never#42')
        state = github()
        offer = 'https://github.com/Octo/Never/issues/42'
        s.require('unknown reference offered and picked', (state['offer'], state['picked']),
                  (offer, 'page:github.com/octo/never/issues/42'))
        s.require('offer opens nothing before Return', len(s.tabs()), count)
        press(36, '\r')
        opened = next(t for t in s.tabs() if t['active'])
        s.require('Return opens the reference on github.com', opened['url'], offer)
        s.require('in a new tab of the Space', len(s.tabs()), count + 1)
        press(13, 'w', 'cmd')
        bench('select', first)
        press(17, 't', 'cmd')
        press(40, 'k', 'cmd', 'shift')
        press(13, 'w', 'cmd')
        s.require('Cmd W cancels intention only', len(s.tabs()), count)
        press(40, 'k', 'cmd', 'shift')
        press(40, 'k', 'cmd')
        s.require('Cmd K returns to tab search', snapshot()['summoning'], True)
        s.require('Cmd K ends GitHub', github()['open'], False)
        press(37, 'l', 'cmd')
        s.require('Cmd L remains address editing', snapshot()['typed'], url + '1/files#draft')
        press(45, 'n', 'cmd', 'shift')
        press(40, 'k', 'cmd', 'shift')
        state = github()
        s.require('private search is private', state['private'], True)
        s.require('private search cannot see ordinary history or tabs', state['rows'], [])
        press(40, 'k', 'cmd', 'shift')
        s.require('asking again keeps the private search', (github()['open'], github()['private']), (True, True))
        press(53, '\x1b')
        s.require('private cancellation makes no tab', len(s.tabs()), count)
        press(40, 'k', 'cmd', 'shift')
        bench('space', 'new', 'GitHub isolated', 'fresh')
        s.require('Space change cancels search', github()['open'], False)
        press(40, 'k', 'cmd', 'shift')
        s.require('other Space has no leaked results', github()['rows'], [])
        print('PASS GitHub local search, grouping, native keys, shared reply, stable selection, tab reuse, reference offer, cancellation and privacy')


if __name__ == '__main__':
    main()
