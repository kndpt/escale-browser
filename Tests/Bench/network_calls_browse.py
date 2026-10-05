#!/usr/bin/env python3
"""Browsing the API Calls panel: arrows, recording and response search.

Loopback only, on the handler of network_calls.py with a page of its own.
Asserted, through the production owner and real key presses:

- ↑ / ↓ from the opened call go to the newer / older call of the list as
  shown, stop at both ends, follow a filtered list, and ⌥↑ / ⌥↓ do the same;
  stepping quickly reads fewer responses than calls passed.
- Pause keeps every row, lets a call under way finish, never lists a call
  made while paused (even one finishing after resuming), keeps rows
  readable; Clear empties the list in either state without changing it, and
  nothing cleared comes back; quick toggles and another tab keep the state.
- The search finds a word only present in a response never opened, in
  several responses, several times in one, in an address only and in both,
  whatever its case, in JSON and text; not in binary, empty or past-limit
  responses, which are counted as such; a response arriving during the
  search; no stale result after quick typing or Clear; All widens it to the
  page's document; the opened match marks the tree's search or the text.

Runs in its own world through the shared runner (suite.py) after ./build.sh.
"""
import json
import time
from http.server import ThreadingHTTPServer
from threading import Thread
import suite as s
import network_calls as base

WORD = "Zephyrine"
BIG = json.dumps({"rows": [{"i": i, "pad": "x" * 90} for i in range(6500)], "late": WORD})

PAGE = """<!doctype html><title>Calls fixture</title><h1>Calls fixture</h1><script>
window.done = true;
async function seq(count, tag) {
  window.done = false;
  for (let i = 0; i < count; i++) await fetch('/api/n?i=' + i + '&t=' + tag).then(r => r.text());
  window.done = true;
}
async function slow(tag) { await fetch('/api/slow-word?t=' + tag).then(r => r.text()); }
async function words(tag) {
  window.done = false;
  const q = '?t=' + tag;
  for (const path of ['/api/profile', '/api/team', '/api/zephyrine-card', '/api/zephyrine', '/api/plain',
                      '/api/bytes', '/api/large', '/api/empty'])
    await fetch(path + q).then(r => r.arrayBuffer());
  window.done = true;
}
</script>"""


class Handler(base.Handler):
    def do_GET(self):
        path = self.path.split('?')[0]
        if path == '/':
            self.send(200, PAGE, 'text/html; charset=utf-8', [('cache-control', 'no-store')])
        elif path == '/api/n':
            self.send(200, json.dumps({"n": self.path.split('i=')[1].split('&')[0], "items": ["a", "b"]}))
        elif path == '/api/profile':
            self.send(200, json.dumps({"user": {"id": 7, "name": WORD, "city": "Lyon"}, "roles": ["admin"],
                                       "settings": {"theme": "dark", "tips": list(range(40))}}))
        elif path == '/api/team':
            self.send(200, json.dumps({"members": [WORD, WORD.lower(), WORD.upper()], "size": 3}))
        elif path == '/api/zephyrine-card':
            self.send(200, json.dumps({"ok": True}))
        elif path == '/api/zephyrine':
            self.send(200, json.dumps({"owner": WORD}))
        elif path == '/api/plain':
            self.send(200, "line one\nline two\n" * 40 + "the name " + WORD.lower() + " is in plain text\n", 'text/plain')
        elif path == '/api/bytes':
            self.send(200, bytes(range(256)) + WORD.encode() + bytes(range(256)), 'application/octet-stream')
        elif path == '/api/large':
            self.send(200, BIG)
        elif path == '/api/empty':
            self.send(200, b'', 'application/json')
        elif path == '/api/slow-word':
            time.sleep(3)
            try:
                self.send(200, json.dumps({"late": WORD + "-slow"}))
            except OSError:
                pass
        else:
            super().do_GET()


def serve():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    base.PORTS.update(a=server.server_port, b=server.server_port, dead=1)
    Thread(target=server.serve_forever, daemon=True).start()
    return server


calls = base.calls
bench = base.bench
js = base.js


def arrow(down, option=False):
    """A real arrow press on the app, as the keyboard sends it."""
    bench('press', 125 if down else 126, '' if down else '', *(['opt'] if option else []))


def tagged(tag):
    return [row for row in calls()['rows'] if ('t=' + tag) in row['url']]


def shown_tagged(tag):
    rows = {row['id']: row for row in calls()['rows']}
    return [ident for ident in calls()['shown'] if ('t=' + tag) in rows[ident]['url']]


def settled(label, condition, seconds=15):
    s.until(label, condition, seconds)


def search(text):
    calls(action='filter', search=text)


def search_done(text):
    wanted = text.strip() if len(text.strip()) >= 2 else ''
    settled('search for ' + repr(text), lambda: (lambda state: state['needle'] == wanted and not state['running'])(calls()['search']), 20)
    return calls()


def body_read(label):
    settled(label, lambda: (calls().get('body') or {}).get('kind') not in (None, 'reading'), 15)
    return calls()


def key_of(url):
    return url.split('/api/')[1].split('?')[0]


def main():
    server = serve()
    page = f"http://127.0.0.1:{base.PORTS['a']}/"
    with s.world(server):
        s.launch()
        bench('ui', 'look', 'light')
        bench('resize', 1360, 860)
        tab = base.open_tab(page)
        base.press('n', 45)
        base.collecting()
        state = calls()
        s.require('recording by default', state['recording'], True)

        # ↑ / ↓ from the opened call, newest first.
        base.run_js(tab, "seq(6, 'nav')")
        settled('six calls', lambda: len(tagged('nav')) == 6)
        order = shown_tagged('nav')
        rows = {row['id']: row for row in calls()['rows']}
        s.require('newest first', [rows[i]['url'].split('i=')[1][0] for i in order], list('543210'))
        calls(action='select', call=order[2])
        body_read('middle call read')
        s.require('neighbours of the middle call', calls()['neighbours'], [order[1], order[3]])
        arrow(True)
        settled('↓ opens the older call', lambda: calls()['selected'] == order[3], 5)
        arrow(False)
        arrow(False)
        settled('↑ ↑ opens the newer ones', lambda: calls()['selected'] == order[1], 5)
        arrow(False, option=True)
        settled('⌥↑ as well', lambda: calls()['selected'] == order[0], 5)
        s.require('no newer call at the top', calls()['neighbours'][0], '')
        arrow(False)
        time.sleep(0.4)
        s.require('↑ at the top does nothing', calls()['selected'], order[0])
        calls(action='select', call=order[-1])
        body_read('last call read')
        arrow(True)
        time.sleep(0.4)
        s.require('↓ at the bottom does nothing, without wrapping', calls()['selected'], order[-1])
        s.require('no older call at the bottom', calls()['neighbours'][1], '')
        print('ok: ↑ ↓ and ⌥↑ ⌥↓ step through the list newest first and stop at its ends', flush=True)

        # A filtered list: the steps follow what is shown, over hidden rows.
        calls(action='select')
        base.run_js(tab, "seq(1, 'mix')")
        base.run_js(tab, "seq(1, 'nav-late')")
        settled('mixed calls', lambda: len(tagged('mix')) == 1 and len(tagged('nav-late')) == 1)
        late = tagged('nav-late')[0]['id']
        calls(action='select', call=late)
        body_read('newest call read')
        s.require('unfiltered, the next one is the hidden kind', calls()['neighbours'][1], tagged('mix')[0]['id'])
        search('t=nav')
        search_done('t=nav')
        s.require('filtered neighbours skip what is hidden', calls()['neighbours'], ['', order[0]])
        arrow(True)
        settled('↓ in the filtered list', lambda: calls()['selected'] == order[0], 5)
        calls(action='select')
        search('')
        print('ok: the steps follow the filtered list', flush=True)

        # Stepping quickly reads fewer responses than calls passed.
        base.run_js(tab, "seq(40, 'fast')")
        settled('forty more', lambda: len(tagged('fast')) == 40)
        fast = shown_tagged('fast')
        calls(action='select', call=fast[0])
        body_read('first fast call')
        reads = calls()['reads']
        # Thirty steps in one turn of the main loop: the fastest presses.
        calls(action='step', by=1, times=30)
        body_read('reached call read')
        spent = calls()['reads'] - reads
        s.require('30 steps land on the 31st call', calls()['selected'], fast[30])
        s.require('the call reached has its response', calls()['body']['kind'], 'text')
        print(f'ok: 30 quick steps read {spent} responses', flush=True)
        s.require('fewer reads than steps', spent < 30, True)
        calls(action='select')

        # Recording paused: rows kept, a call under way finishes, calls made meanwhile never listed.
        bench('eval', tab, "slow('underway'); true")
        settled('slow call listed', lambda: len(tagged('underway')) == 1)
        count = calls()['count']
        calls(action='record', on=False)
        s.require('paused', calls()['recording'], False)
        bench('eval', tab, "slow('during'); true")
        base.run_js(tab, "seq(3, 'paused')")
        settled('the call under way finished while paused', lambda: tagged('underway')[0]['state'] == 'done', 10)
        time.sleep(3.5)
        s.require('nothing made during the pause is listed', (tagged('paused'), tagged('during')), ([], []))
        s.require('rows kept while paused', calls()['count'], count)
        calls(action='select', call=order[0])
        s.require('a kept call opens while paused', body_read('read while paused')['body']['kind'], 'text')
        calls(action='select')
        calls(action='record', on=True)
        base.run_js(tab, "seq(2, 'resumed')")
        settled('listed again after resuming', lambda: len(tagged('resumed')) == 2)
        s.require('no catching up after resuming', (tagged('paused'), tagged('during')), ([], []))
        print('ok: pause keeps rows and lists nothing made meanwhile, resume adds new calls only', flush=True)

        # A call first seen while paused and finishing after resuming stays out.
        calls(action='record', on=False)
        bench('eval', tab, "slow('straddle'); true")
        time.sleep(0.5)
        calls(action='record', on=True)
        time.sleep(3.5)
        s.require('a call made while paused stays out after resuming', tagged('straddle'), [])
        print('ok: a call started while paused and ending after resuming is not listed', flush=True)

        # Clear, in both states, never changes recording, and nothing comes back.
        calls(action='record', on=False)
        calls(action='clear')
        state = calls()
        s.require('cleared while paused', (state['count'], state['recording']), (0, False))
        base.run_js(tab, "seq(2, 'cleared-paused')")
        time.sleep(0.5)
        s.require('still empty while paused', calls()['count'], 0)
        calls(action='record', on=True)
        base.run_js(tab, "seq(1, 'after-clear')")
        settled('new call after clear and resume', lambda: len(tagged('after-clear')) == 1)
        s.require('only the new call', calls()['count'], 1)
        bench('eval', tab, "slow('before-clear'); true")
        settled('slow call listed before clearing', lambda: len(tagged('before-clear')) == 1)
        calls(action='clear')
        s.require('cleared while recording', (calls()['count'], calls()['recording']), (0, True))
        base.run_js(tab, "seq(2, 'refill')")
        settled('the list fills again', lambda: len(tagged('refill')) == 2)
        time.sleep(3.2)
        s.require('a cleared call finishing later does not come back', tagged('before-clear'), [])
        print('ok: Clear empties the list in either state and leaves recording alone; cleared calls stay gone', flush=True)

        # Web Inspector's own close makes the panel reconnect: what was
        # cleared, the page's document included, stays gone.
        calls(action='clear')
        base.press('i', 34)
        s.until('inspector shown', lambda: calls()['inspector'] != '', 10)
        calls(tab, action='frontend', js='InspectorFrontendHost.closeWindow(); true')
        s.until('reconnected', lambda: calls()['inspector'] == '' and calls()['phase']['name'] == 'collecting'
                and calls()['inspection']['connected'] is True, 15)
        time.sleep(1)
        s.require('nothing cleared comes back after a reconnection', [r['url'] for r in calls()['rows']], [])
        base.run_js(tab, "seq(1, 'reconnected')")
        settled('listed after the reconnection', lambda: len(tagged('reconnected')) == 1)
        print('ok: a reconnection after Clear lists only new calls', flush=True)

        # Quick toggles, then another tab and back.
        for on in [False, True] * 5 + [False]:
            calls(action='record', on=on)
        s.require('quick toggles settle on the last', calls()['recording'], False)
        other = base.open_tab(page + '?other')
        bench('select', tab)
        s.until('back on the first tab', lambda: base.active()['id'] == tab, 10)
        s.require('paused after another tab', (calls()['recording'], calls()['phase']['name']), (False, 'collecting'))
        calls(action='record', on=True)
        bench('select', other)
        bench('press', 13, 'w', 'cmd')
        bench('select', tab)
        s.until('first tab again', lambda: base.active()['id'] == tab, 10)
        print('ok: quick toggles and a tab change keep the recording state', flush=True)

        # Search in responses, after a reload so that All has a document.
        calls(action='clear')
        bench('eval', tab, 'location.reload(); true')
        s.until('reloaded', lambda: any(r['type'] == 'document' for r in calls()['rows']), 15)
        s.until('page ready', lambda: base.js(tab, 'window.done === true && typeof words') == 'function', 15)
        base.run_js(tab, "words('w')")
        settled('word calls finished', lambda: len([r for r in tagged('w') if r['state'] == 'done']) == 8)
        rows = {row['id']: key_of(row['url']) for row in tagged('w')}
        search(WORD)
        state = search_done(WORD)
        found = state['search']
        shown = [rows[i] for i in state['shown'] if i in rows]
        s.require('matched in the response', sorted(rows[i] for i in found['matches']),
                  sorted(['profile', 'team', 'zephyrine', 'plain']))
        s.require('listed once each, address matches included', sorted(shown),
                  sorted(['profile', 'team', 'zephyrine-card', 'zephyrine', 'plain']))
        s.require('one row per call', len(shown), len(set(shown)))
        team = next(m for i, m in found['matches'].items() if rows[i] == 'team')
        s.require('the excerpt holds the first occurrence', team['hit'], WORD)
        plain = next(m for i, m in found['matches'].items() if rows[i] == 'plain')
        s.require('text response, other case', plain['hit'], WORD.lower())
        coverage = found['coverage']
        s.require('binary counted, not searched', coverage['binary'] >= 1, True)
        s.require('the large response said to be searched in part', coverage['cut'] >= 1 and coverage['missed'] >= 1, True)
        s.require('large response past the limit not claimed', 'large' in shown, False)
        s.require('an empty response is searched, not unavailable', coverage['unavailable'], 0)
        print('ok: a word only in unopened responses is found, once per call, with its excerpt:', coverage['words'].replace('\n', '; '), flush=True)
        search(WORD.upper())
        s.require('same results whatever the case', sorted(search_done(WORD.upper())['search']['matches']), sorted(found['matches']))

        # All widens the search to the page's own document.
        calls(action='filter', all=True)
        state = search_done(WORD.upper())
        documents = [row for row in state['rows'] if row['id'] in state['search']['matches'] and row['type'] == 'document']
        s.require('All finds the word in the document', len(documents) >= 1, True)
        calls(action='filter', all=False)
        search_done(WORD.upper())

        # Opening a match marks it; the arrows follow the results.
        profile = next(i for i in state['shown'] if rows.get(i) == 'profile')
        calls(action='select', call=profile)
        settled('profile tree searched', lambda: calls()['search']['treeQuery'] == WORD.upper(), 10)
        s.require('opened on its match', calls()['search']['mark'], WORD.upper())
        # A click in the sheet takes SwiftUI's focus away; the arrows stay.
        opened = calls()['selected']
        bench('drag', 1150, 600, 1150, 600, 0, 'live')
        arrow(False)
        settled('↑ still steps after a click in the sheet', lambda: calls()['selected'] not in ('', opened), 5)
        arrow(True, option=True)
        settled('⌥↓ back', lambda: calls()['selected'] == opened, 5)
        calls(action='select', call=opened)
        body_read('back on the match')
        shown = calls()['shown']
        s.require('arrows follow the results', calls()['neighbours'],
                  [shown[shown.index(profile) - 1] if shown.index(profile) > 0 else '',
                   shown[shown.index(profile) + 1] if shown.index(profile) + 1 < len(shown) else ''])
        calls(action='select')
        print('ok: an opened match searches its tree; the arrows follow the results', flush=True)

        # A response arriving during the search, quick typing, then Clear.
        bench('eval', tab, "slow('arrive'); true")
        settled('slow call listed', lambda: len(tagged('arrive')) == 1)
        settled('a response still loading is counted',
                lambda: (calls()['search'].get('coverage') or {}).get('loading', 0) >= 1, 10)
        settled('the late response joins the results',
                lambda: any(key_of(r['url']) == 'slow-word' for r in calls()['rows'] if r['id'] in calls()['search']['matches']), 15)
        for text in ('ze', 'zep', 'zeph', 'no-such-word-at-all'):
            search(text)
        state = search_done('no-such-word-at-all')
        s.require('no stale result after quick typing', (state['search']['matches'], [i for i in state['shown'] if i in rows]), ({}, []))
        search(WORD)
        search_done(WORD)
        calls(action='clear')
        state = calls()
        s.require('Clear drops the results', (state['count'], state['search']['matches']), (0, {}))
        base.run_js(tab, "words('w2')")
        state = search_done(WORD)
        settled('new responses searched after Clear', lambda: len(calls()['search']['matches']) == 4, 10)
        s.require('no cleared result reappears', [i for i in calls()['shown'] if i in rows], [])
        print('ok: late responses join, quick typing leaves no stale result, Clear drops results', flush=True)

        # Paused, the search keeps working on the kept rows.
        calls(action='record', on=False)
        base.run_js(tab, "words('w3')")
        search('')
        search(WORD)
        state = search_done(WORD)
        s.require('paused search on kept rows', len(state['search']['matches']), 4)
        calls(action='record', on=True)
        base.run_js(tab, "words('w4')")
        settled('resumed rows join the search', lambda: len(calls()['search']['matches']) == 8, 15)
        print('ok: pause keeps the search; resume adds new responses to it', flush=True)

        calls(action='select', call=next(i for i in calls()['shown'] if i in calls()['search']['matches']))
        body_read('reopened match')
        calls(action='select')
        search('')
        calls(action='record', on=False)
        base.press('n', 45)
        s.until('closed', lambda: calls()['phase']['name'] == 'closed', 10)
        state = calls()
        s.require('closing resets recording and search', (state['recording'], state['search']['needle']), (True, ''))
        base.left_clean(tab, 'closed after browsing')


if __name__ == '__main__':
    main()
