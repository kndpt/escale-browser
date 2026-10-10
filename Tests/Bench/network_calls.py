#!/usr/bin/env python3
"""The API Calls panel on WebKit's own inspector collection.

Loopback only: a local fixture, two origins and a closed port. The page makes a POST of JSON with an Authorization header, an XHR, a
CORS and an opaque fetch, a redirect, a 500, a 404, a refused connection, an aborted
fetch, a 2.5 MB response, two cacheable fetches, a beacon, a dedicated
worker's fetch, a cross-site iframe's fetch and a service worker's generated
and passed-through responses.

Asserted: nothing is collected before the panel is opened with ⌥⌘N; each
row and outcome; the Errors and resource type filters, kept
while a call is open; response bodies identical to what the page read, and named
unavailable (never empty) for failure, cancellation, beacon and worker; the
sent body; the copied report's redaction; the Copy as cURL command, replayed
against the fixture, getting the page's own answer; Web Inspector opened on the same
session (docked right) and put away with ⌥⌘I (hidden, collection going on);
closing either one leaving the other; the 500-row bound; and complete
the panel kept, still collecting, on another tab or Space (and its tab kept
awake); Web Inspector's own close answered by a reconnection that keeps the
rows; at most three collecting tabs; and complete teardown (no script, no
message handler, no session) on closing and when the page's process ends,
with Resume afterwards.

Runs in its own world through the shared runner (suite.py) after ./build.sh.
"""
import json
import socket
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
import suite as s

PORTS = {}
TOKEN = "Bearer escale-fixture-token"
BIG = json.dumps({"rows": [{"i": i, "name": "row-%06d" % i, "pad": "x" * 80} for i in range(20000)]})

PAGE = """<!doctype html><title>Calls fixture</title><h1>Calls fixture</h1><script>
const B = 'http://localhost:%(b)d', DEAD = %(dead)d;
window.results = {};
async function capture(name, promise, lengthOnly) {
  try { const r = await promise;
    let body = null; if (r.type !== 'opaque') { const t = await r.text(); body = lengthOnly ? t.length : t; }
    results[name] = {status: r.status, type: r.type, body};
  } catch (e) { results[name] = {error: String(e)}; }
}
async function fire(tag) {
  results = {}; window.done = false; const q = (k) => 'k=' + k + '&t=' + tag;
  await capture('post', fetch('/api/echo?' + q('post'), {method: 'POST',
      headers: {'content-type': 'application/json', 'authorization': '%(token)s'},
      body: JSON.stringify({hello: 'escale', tag, list: [1, 2, 3], unicode: 'été ✓'})}));
  results.xhr = await new Promise(res => { const x = new XMLHttpRequest(); x.open('GET', '/api/items?' + q('xhr'));
      x.onload = () => res({status: x.status, body: x.responseText}); x.onerror = () => res({error: 'xhr'}); x.send(); });
  await capture('cors', fetch(B + '/api/cors?' + q('cors')));
  await capture('opaque', fetch(B + '/api/opaque?' + q('opaque'), {mode: 'no-cors'}));
  await capture('redirect', fetch('/api/redirect?' + q('redirect')));
  await capture('error', fetch('/api/error?' + q('error')));
  await capture('missing', fetch('/api/missing?' + q('missing')));
  await capture('refused', fetch('http://127.0.0.1:' + DEAD + '/api/x?' + q('refused')));
  const ac = new AbortController(); const slow = fetch('/api/slow?' + q('abort'), {signal: ac.signal});
  setTimeout(() => ac.abort(), 150); await capture('abort', slow);
  await capture('big', fetch('/api/big?' + q('big')), true);
  await capture('cached1', fetch('/api/cached?k=cached&t=' + tag));
  results.beacon = navigator.sendBeacon('/api/beacon?' + q('beacon'), JSON.stringify({beacon: tag}));
  results.worker = await new Promise(res => { const w = new Worker('/worker.js?' + q('worker-script'));
      w.onmessage = e => { res(e.data); w.terminate(); }; setTimeout(() => res({error: 'worker timeout'}), 5000); });
  results.frame = await new Promise(res => { const f = document.createElement('iframe'); f.src = B + '/frame?' + q('frame-doc');
      addEventListener('message', function once(e) { if (e.data && e.data.frame) { removeEventListener('message', once); res(e.data); } });
      document.body.appendChild(f); setTimeout(() => res({error: 'frame timeout'}), 5000); });
  try { await navigator.serviceWorker.register('/sw.js'); await navigator.serviceWorker.ready;
    if (!navigator.serviceWorker.controller) await new Promise(res => { navigator.serviceWorker.oncontrollerchange = res; setTimeout(res, 3000); });
    await capture('sw', fetch('/api/sw?' + q('sw')));
    await capture('swpass', fetch('/api/items?' + q('swpass')));
  } catch (e) { results.sw = {error: String(e)}; }
  window.done = true;
}
async function many(count, tag) {
  window.done = false;
  for (let i = 0; i < count; i += 50)
    await Promise.all(Array.from({length: Math.min(50, count - i)}, (_, j) => fetch('/api/items?k=many&n=' + (i + j) + '&t=' + tag)));
  window.done = true;
}
async function one(tag) { window.done = false; await fetch('/api/items?k=one&t=' + tag); window.done = true; }
</script>"""
WORKER = ("fetch('/api/items?k=worker&' + location.search.slice(1).replace(/k=[^&]*&?/, ''))"
          ".then(r => r.text()).then(t => postMessage({worker: true, body: t})).catch(e => postMessage({error: String(e)}));")
SW = ("self.addEventListener('install', e => self.skipWaiting());"
      "self.addEventListener('activate', e => e.waitUntil(clients.claim()));"
      "self.addEventListener('fetch', e => { if (new URL(e.request.url).pathname === '/api/sw')"
      " e.respondWith(new Response(JSON.stringify({from: 'service-worker'}), {headers: {'content-type': 'application/json'}})); });")
FRAME = """<!doctype html><script>const t = location.search.slice(1).replace(/k=[^&]*&?/, '');
fetch('/api/in-frame?k=frame&' + t).then(r => r.text()).then(b => parent.postMessage({frame: true, body: b}, '*'));</script>"""


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def send(self, code, body, kind='application/json', extra=()):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header('content-type', kind)
        self.send_header('content-length', str(len(data)))
        for key, value in extra:
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get('content-length') or 0))
        if self.path.startswith('/api/echo'):
            self.send(200, json.dumps({"echo": json.loads(raw.decode()), "bytes": len(raw), "path": self.path}))
        else:
            self.send(204, b'')

    def do_GET(self):
        path = self.path.split('?')[0]
        cross = self.server.server_port == PORTS['b']
        if path == '/' and not cross:
            self.send(200, PAGE % dict(PORTS, token=TOKEN), 'text/html; charset=utf-8', [('cache-control', 'no-store')])
        elif path == '/worker.js':
            self.send(200, WORKER, 'text/javascript')
        elif path == '/sw.js':
            self.send(200, SW, 'text/javascript')
        elif path == '/frame':
            self.send(200, FRAME, 'text/html')
        elif path == '/api/items':
            self.send(200, json.dumps({"items": ["a", "b"], "path": self.path}))
        elif path == '/api/in-frame':
            self.send(200, json.dumps({"inFrame": True, "path": self.path}))
        elif path == '/api/cors':
            self.send(200, json.dumps({"cors": True, "path": self.path}), extra=[('access-control-allow-origin', '*')])
        elif path == '/api/opaque':
            self.send(200, json.dumps({"opaque": True, "path": self.path}))
        elif path == '/api/redirect':
            self.send(302, '', 'text/plain', [('location', '/api/items?k=redirected&' + self.path.split('?')[1])])
        elif path == '/api/error':
            self.send(500, json.dumps({"error": "boom", "path": self.path}))
        elif path == '/api/slow':
            time.sleep(2)
            try:
                self.send(200, json.dumps({"slow": True}))
            except OSError:
                pass
        elif path == '/api/big':
            self.send(200, BIG)
        elif path == '/api/cached':
            self.send(200, json.dumps({"cached": True, "at": time.time()}), extra=[('cache-control', 'max-age=600')])
        else:
            self.send(404, json.dumps({"missing": self.path}))


def serve():
    a = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    b = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    dead = socket.socket()
    dead.bind(('127.0.0.1', 0))
    port = dead.getsockname()[1]
    dead.close()
    PORTS.update(a=a.server_port, b=b.server_port, dead=port)
    for server in (a, b):
        server.daemon_threads = True
        Thread(target=server.serve_forever, daemon=True).start()
    return a, b


def bench(*args):
    return json.loads(s.command(str(s.ROOT / 'bench'), '--world', s.WORLD, '--json', *map(str, args), seconds=40))


def calls(tab='-', **fields):
    return bench('calls', tab, json.dumps(fields))


def js(tab, script):
    return bench('eval', tab, script)['value']


def open_tab(url):
    bench('bookmark', url, 'new')
    s.until('tab ' + url, lambda: s.at(url) is not None, 15)
    ident = s.at(url)['id']
    s.loaded_page(ident, 'Calls fixture', 15, url)
    return ident


def active():
    return next(row for row in s.tabs() if row['active'])


def key(url):
    return url.split('k=')[1].split('&')[0] if 'k=' in url else url


def rows(tag):
    return [row for row in calls()['rows'] if row['url'] and ('t=' + tag) in row['url']]


def fire(tab, tag):
    bench('eval', tab, f'fire({json.dumps(tag)}); true')
    s.until('fixture ' + tag, lambda: js(tab, 'window.done') is True, 40)
    return json.loads(js(tab, 'JSON.stringify(results)'))


def run_js(tab, call):
    bench('eval', tab, call + '; true')
    s.until(call, lambda: js(tab, 'window.done') is True, 60)


def press(chars, code):
    bench('press', code, chars, 'cmd', 'opt')


def collecting():
    try:
        s.until('collecting', lambda: calls()['phase']['name'] == 'collecting', 15)
    except s.WaitExpired as error:
        state = calls()
        raise AssertionError(f"not collecting: {state['phase']}, {state['inspection']}, active {active()}") from error


def left_clean(tab, label):
    """No script, no handler in the tab's inspector frontend, if one remains."""
    found = calls(tab, action='frontend',
                  js='[!!window.__escaleCalls, !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.escaleCalls)]')
    if found.get('frontend'):
        s.require(label + ': no script or handler left in the frontend', found.get('value'), [False, False])
    print(f"ok: {label}: nothing left ({'frontend kept by WebKit' if found.get('frontend') else 'no frontend'})", flush=True)


def main():
    a, b = serve()
    page = f"http://127.0.0.1:{PORTS['a']}/"
    with s.world(a):
        try:
            s.launch()
            bench('ui', 'look', 'light')
            bench('resize', 1360, 860)
            tab = open_tab(page)

            # Closed: nothing collects, no session exists.
            fire(tab, 'before')
            state = calls()
            s.require('closed before opening', state['phase']['name'], 'closed')
            s.require('no inspector session before opening', state['inspection']['session'], False)
            left_clean(tab, 'before opening')

            # ⌥⌘N opens the panel for this tab.
            wide = js(tab, 'innerWidth')
            press('n', 45)
            collecting()
            s.require('panel for this tab', calls()['tab'].lower().startswith(tab.lower()), True)
            s.require('panel beside the page, not over it', js(tab, 'innerWidth') < wide, True)
            s.require('earlier requests are not reconstructed', [r['url'] for r in rows('before') if r['state'] != 'earlier'], [])

            page_read = fire(tab, 'during')
            s.until('during rows settled', lambda: len([r for r in rows('during') if r['state'] != 'loading']) >= 18, 15)
            found = {}
            for row in rows('during'):
                found.setdefault(key(row['url']), []).append(row)
            expected = {'post': ('POST', 'fetch', 'done', 200), 'xhr': ('GET', 'xhr', 'done', 200),
                        'cors': ('GET', 'fetch', 'done', 200), 'opaque': ('GET', 'fetch', 'done', 200),
                        'redirected': ('GET', 'fetch', 'done', 200), 'error': ('GET', 'fetch', 'done', 500),
                        'missing': ('GET', 'fetch', 'done', 404),
                        'refused': ('GET', 'fetch', 'failed', None), 'abort': ('GET', 'fetch', 'canceled', None),
                        'big': ('GET', 'fetch', 'done', 200), 'cached': ('GET', 'fetch', 'done', 200),
                        'beacon': ('POST', 'beacon', 'done', 204), 'worker': ('GET', 'fetch', 'done', 200),
                        'frame': ('GET', 'fetch', 'done', 200), 'sw': ('GET', 'fetch', 'done', 200),
                        'swpass': ('GET', 'fetch', 'done', 200)}
            for name, (method, kind, outcome, status) in expected.items():
                s.require(f'row for {name}', name in found, True)
                row = found[name][-1]
                s.require(f'{name} row', (row['method'], row['type'], row['state'], row['status']), (method, kind, outcome, status))
            s.require('refused names its WebKit failure', found['refused'][-1]['failure'], 'Could not connect to the server.')
            s.require('worker row comes from the worker target', found['worker'][-1]['target'], 'worker')
            s.require('redirect counted', found['redirected'][-1]['redirects'], 1)
            s.require('service worker response source', found['sw'][-1]['source'], 'service-worker')
            s.require('Fetch/XHR filter hides the beacon and documents',
                      [c for c in calls()['shown'] if c in (found['beacon'][-1]['id'], found['frame-doc'][-1]['id'])], [])
            print('ok: 16 kinds of exchange listed with outcome, method, type and status', flush=True)

            ids = {name: found[name][-1]['id'] for name in found}
            calls(action='filter', filter='errors')
            state = calls()
            by_id = {row['id']: row for row in state['rows']}
            s.require('Errors keeps the 404, the 500, the refused and the aborted calls',
                      {ids[n] for n in ('missing', 'error', 'refused', 'abort')} <= set(state['shown']), True)
            s.require('Errors keeps nothing else', [c for c in state['shown'] if not (
                by_id[c]['state'] in ('failed', 'canceled') or (by_id[c]['state'] == 'done' and by_id[c]['status'] >= 400))], [])
            calls(action='filter', filter='all', kind='document')
            docs = calls()['shown']
            s.require('Document lists the frame', ids['frame-doc'] in docs, True)
            s.require('Document lists documents only', {by_id[c]['type'] for c in docs if c in by_id}, {'document'})
            calls(action='select', call=ids['frame-doc'])
            calls(action='select', call=None)
            s.require('the filter outlives opening a call', calls()['shown'], docs)
            calls(action='filter', filter='api', kind=None)
            print('ok: Errors and Document filters, kept across an open call', flush=True)

            page_names = {'post': 'post', 'xhr': 'xhr', 'cors': 'cors', 'redirected': 'redirect', 'error': 'error',
                          'cached': 'cached1', 'sw': 'sw', 'swpass': 'swpass'}
            for name, page_name in page_names.items():
                calls(action='select', call=found[name][-1]['id'])
                s.until(name + ' body', lambda: (calls().get('body') or {}).get('kind') not in (None, 'reading'), 15)
                body = calls(full=True)['body']
                s.require(f'{name} body identical to the page', (body['kind'], body['text']), ('text', page_read[page_name]['body']))
            calls(action='select', call=found['opaque'][-1]['id'])
            s.until('opaque body', lambda: (calls().get('body') or {}).get('kind') not in (None, 'reading'), 15)
            s.require('opaque body readable although the page cannot', calls()['body']['kind'], 'text')
            calls(action='select', call=found['frame'][-1]['id'])
            s.until('frame body', lambda: (calls().get('body') or {}).get('kind') not in (None, 'reading'), 15)
            s.require('cross-site iframe body identical', calls(full=True)['body']['text'], page_read['frame']['body'])
            calls(action='select', call=found['big'][-1]['id'])
            s.until('big body', lambda: (calls().get('body') or {}).get('kind') not in (None, 'reading'), 15)
            big = calls()['body']
            s.require('large body: WebKit length, cut at 2 MiB', (big['length'], big['cut'], big['count']),
                      (page_read['big']['body'], True, 2 * 1024 * 1024))
            s.require('cut body is not read structured', calls()['reader']['shown'], False)
            for name in ('refused', 'abort', 'beacon', 'worker'):
                calls(action='select', call=found[name][-1]['id'])
                s.until(name + ' answer', lambda: (calls().get('body') or {}).get('kind') not in (None, 'reading'), 15)
                body = calls()['body']
                s.require(f'{name}: unavailable with a reason, never empty', (body['kind'], bool(body.get('reason'))), ('unavailable', True))
            print('ok: bodies identical to the page; failure, cancel, beacon and worker named unavailable', flush=True)

            calls(action='select', call=found['post'][-1]['id'])
            s.until('post detail', lambda: calls().get('detail') is not None and calls()['body']['kind'] == 'text', 15)
            post = calls()
            sent = json.loads(post['detail']['requestBody'])
            s.require('sent body', sent, {'hello': 'escale', 'tag': 'during', 'list': [1, 2, 3], 'unicode': 'été ✓'})
            s.require('JSON response read structured', post['reader']['shown'] and post['reader']['nodes'] > 5, True)
            s.require('request headers include Authorization',
                      any(name.lower() == 'authorization' for name, _ in post['detail']['requestHeaders']), True)
            report = calls(action='report')['report']
            s.require('report redacts the token', TOKEN.split()[-1] in report, False)
            s.require('report says what was redacted', 'uthorization: [redacted]' in report, True)
            s.require('report carries the tab', page in report and 'Space:' in report and 'Escale' in report, True)
            s.require('report carries the response', '"echo"' in report, True)
            print('ok: sent body, structured response and redacted report', flush=True)

            # Copy as › cURL, replayed against the loopback fixture only.
            curl = calls(action='curl')['curl']
            s.require('cURL targets the loopback fixture', curl.startswith("curl '" + page + "api/echo"), True)
            s.require('cURL keeps the Authorization header', "-H 'Authorization: " + TOKEN + "'" in curl, True)
            replayed = subprocess.run(['/bin/sh', '-c', curl + ' --silent --max-time 5'], capture_output=True, text=True, timeout=10)
            s.require('the copied command sends the same request', replayed.stdout, page_read['post']['body'])
            print('ok: Copy as cURL replays the same POST', flush=True)
            calls(action='select')

            # Web Inspector on the same session: docked right, then hidden.
            beside = js(tab, 'innerWidth')
            press('i', 34)
            s.until('inspector docked on the collected session',
                    lambda: calls()['inspector'].lower().startswith(tab.lower()) and js(tab, 'innerWidth') < beside - 100, 10)
            s.require('same session collects on', calls()['inspection']['collecting'], True)
            fire(tab, 'shown')
            s.until('rows with the inspector shown', lambda: len(rows('shown')) >= 15, 10)
            press('i', 34)
            s.until('inspector put away', lambda: calls()['inspector'] == '' and js(tab, 'innerWidth') == beside, 10)
            flags = calls()['inspection']
            s.require('put away by hide, not close', (flags['visible'], flags['connected'], flags['collecting']), (False, True, True))
            fire(tab, 'hidden')
            s.until('rows after hiding the inspector', lambda: len(rows('hidden')) >= 15, 10)
            print('ok: ⌥⌘I docks on the loaded frontend and hides it without ending the collection', flush=True)

            # Web Inspector's own close button ends WebKit's session: the panel
            # connects again by itself and keeps what it had.
            press('i', 34)
            s.until('inspector shown again', lambda: calls()['inspector'] != '', 10)
            kept = calls()['count']
            calls(tab, action='frontend', js='InspectorFrontendHost.closeWindow(); true')
            s.until('reconnected after WebKit closed the session',
                    lambda: calls()['inspector'] == '' and calls()['phase']['name'] == 'collecting'
                    and calls()['inspection']['connected'] is True, 15)
            s.require('rows kept across the reconnection', calls()['count'] >= kept, True)
            fire(tab, 'reopened')
            s.until('rows after the reconnection', lambda: len(rows('reopened')) >= 15, 10)
            print('ok: closing Web Inspector from its own panel reconnects the collection, rows kept', flush=True)

            # Closing the panel leaves Web Inspector as it is.
            press('i', 34)
            s.until('inspector shown for the panel test', lambda: calls()['inspector'] != '', 10)
            press('n', 45)
            s.until('panel closed', lambda: calls()['phase']['name'] == 'closed', 10)
            s.require('closing the panel keeps Web Inspector', (calls()['inspector'] != '', calls()['inspection']['session']), (True, True))
            left_clean(tab, 'panel closed, inspector open')
            press('i', 34)
            s.until('everything closed', lambda: calls()['inspection']['session'] is False, 10)
            s.require('page width back', js(tab, 'innerWidth'), wide)
            press('n', 45)
            collecting()

            # Another tab keeps this one's panel, and it goes on collecting.
            other = open_tab(page + '?other')
            s.require('the other tab has no panel', calls()['phase']['name'], 'closed')
            s.require('the first tab still collects', calls(tab)['phase']['name'], 'collecting')
            s.require('the first tab keeps its session', calls(tab)['inspection']['collecting'], True)
            fire(tab, 'away')
            s.until('rows collected while away', lambda: len([r for r in calls(tab)['rows'] if 't=away' in r['url']]) >= 15, 10)
            reason = bench('sleep', tab)
            s.require('a collecting tab does not sleep', reason.get('asleep'), False)
            bench('select', tab)
            s.until('back on the first tab', lambda: active()['id'] == tab, 10)
            s.require('the panel is back with its rows', (calls()['phase']['name'], len(rows('away')) >= 15), ('collecting', True))
            print('ok: another tab keeps the panel and its collection; it does not sleep:', reason, flush=True)

            # Another Space keeps it too.
            bench('space', 'new', 'Other')
            s.require('the new Space has no panel', calls()['phase']['name'], 'closed')
            s.require('the first tab still collects from the other Space', calls(tab)['phase']['name'], 'collecting')
            bench('space', 'go', '1')
            s.until('back in the first Space', lambda: active()['id'] == tab, 10)
            s.require('the panel is back after the Space', calls()['phase']['name'], 'collecting')
            print('ok: another Space keeps the collection', flush=True)

            # At most three tabs collect: a fourth stops the one looked at least recently.
            opened = [tab]
            for name in ('two', 'three', 'four'):
                ident = open_tab(page + '?' + name)
                press('n', 45)
                collecting()
                opened.append(ident)
            s.require('three collections at most', sorted(calls()['open']), sorted(t[:8] for t in opened[1:]))
            s.require('the first one stopped', calls(tab)['phase']['name'], 'closed')
            for ident in opened[1:]:
                bench('select', ident)
                bench('press', 13, 'w', 'cmd')
                s.until('tab closed', lambda: s.at(page + '?' + ident) is None and all(t['id'] != ident for t in s.tabs()), 10)
            s.until('closing a tab ends its collection', lambda: calls(tab)['inspection']['collections'] == 0, 10)
            print('ok: three collections at most; closing a tab ends its own', flush=True)

            # The page's process ends: the collection stops and says so.
            bench('select', other)
            press('n', 45)
            collecting()
            bench('crash', other)
            s.until('process loss stops the collection', lambda: calls()['phase']['name'] == 'stopped', 10)
            s.require('the stop gives a reason', bool(calls()['phase'].get('reason')), True)
            s.require('session released after process loss', calls()['inspection']['collecting'], False)
            s.loaded_page(other, 'Calls fixture', 20, 'recovered page')
            calls(action='resume')
            collecting()
            run_js(other, "one('resumed')")
            s.until('rows after resume', lambda: len(rows('resumed')) == 1, 10)
            print('ok: process loss stops and names it; Resume collects again', flush=True)

            # The bound: 520 more calls keep 500 rows. The call left open is
            # let go with its body; the oldest row still listed stays readable.
            calls(action='select', call=rows('resumed')[0]['id'])
            s.until('open call read', lambda: (calls().get('body') or {}).get('kind') == 'text', 10)
            run_js(other, "many(520, 'bound')")
            s.until('bounded list', lambda: calls()['dropped'] > 0, 20)
            state = calls()
            s.require('500 rows kept', state['count'], 500)
            s.require('the evicted open call takes its body with it', (state['selected'], state['body']), ('', None))
            oldest = state['rows'][0]
            calls(action='select', call=oldest['id'])
            s.until('oldest listed call answered', lambda: (calls().get('body') or {}).get('kind') not in (None, 'reading'), 10)
            s.require('the oldest listed call is still readable', calls()['body']['kind'], 'text')
            print(f"ok: bound holds, {state['dropped']} oldest dropped; eviction and lookup stay in step", flush=True)

            press('n', 45)
            s.until('⌥⌘N closes the panel', lambda: calls()['phase']['name'] == 'closed', 10)
            s.require('no session after closing', calls()['inspection']['session'], False)
            left_clean(other, 'closed with ⌥⌘N')
        finally:
            b.shutdown()
            b.server_close()


if __name__ == '__main__':
    main()
