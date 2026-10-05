#!/usr/bin/env python3
"""URL rules select the destination store before the first request.

Only synthetic loopback pages/cookies are used. Real page taps and the macOS
open event exercise entry points; redirects, popup openers, private tabs,
rule edits, Space deletion and restart assert retained context and cleanup.
"""
import json
from pathlib import Path
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
import suite as s

requests = []


def external(url):
    """A link handed to this world's copy by another app, as `open` does. By
    path: LaunchServices may not have registered the copy's id yet. A link
    brings Escale to the front (Links.hand), so this check runs in front."""
    s.command('open', '-a', str(Path(s.BINARY).parents[2]), url)


def bench(*args):
    return json.loads(s.command(str(s.ROOT / 'bench'), '--world', s.WORLD, '--json', *args))


def active():
    return next(row for row in s.tabs() if row['active'])


def load(url):
    bench('bookmark', url, 'new')
    row = active()
    s.loaded_page(row['id'], 'Fixture', 15, url)
    return row


def rule(destination, path):
    return dict(id=str(uuid.uuid4()).upper(), scope='path', host='127.0.0.1', subdomains=False,
                port='', path=path, exact='', destination=destination)


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        requests.append((self.path, self.headers.get('Cookie', '')))
        if self.path.startswith('/meeting/redirect'):
            self.send_response(302)
            self.send_header('Location', '/final')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        body = b'''<title>Fixture</title><h1>Fixture</h1>
        <a id="same" href="/meeting/same">Meeting</a><br>
        <a id="blank" href="/meeting/blank" target="_blank">New tab</a><br>
        <a id="redirect" href="/meeting/redirect">Redirect</a><br>
        <a id="plain" href="/plain">Unmatched</a><br>
        <a id="plainblank" href="/plainblank" target="_blank">Unmatched tab</a><br>
        <button id="popup" onclick="window.open('/popup')">Script popup</button>
        <form method="POST" action="/meeting/form"><button id="submit">Post</button></form>
        <textarea id="draft"></textarea>'''
        self.send_response(200)
        self.send_header('Content-Type', 'text/html')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', 0)))
        self.do_GET()

    def log_message(self, *_):
        pass


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Page)
    Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    with s.world(server):
        s.launch()
        bench('ui', 'welcome', 'off')
        bench('ui', 'spaces', 'on')
        bench('space', 'new', 'Private')
        source = load(base + '/source')
        private = source['space']
        bench('eval', source['id'], "document.cookie='context=Private; Path=/; Max-Age=3600'; localStorage.context='Private'")
        bench('space', 'new', 'ADO')
        seed = load(base + '/seed')
        ado = seed['space']
        bench('eval', seed['id'], "document.cookie='context=ADO; Path=/; Max-Age=3600'; localStorage.context='ADO'")
        routes = [rule(ado, '/meeting'), rule(private, '/final')]
        bench('routes', 'set', json.dumps(routes))
        before = len(requests)
        result = bench('routes', 'test', base + '/meeting/test')
        s.require('test chooses ADO', result['destination'], ado)
        s.require('testing performs no request', len(requests), before)
        bench('space', 'go', '2')
        s.require('parked target can sleep', bench('sleep', seed['id'])['asleep'], True)
        for selector, ending in [('same', '/meeting/same'), ('blank', '/meeting/blank'), ('redirect', '/final')]:
            bench('select', source['id'])
            bench('tap', source['id'], '#' + selector)
            s.wait_for('routed Space', lambda: bench('space'), {'current': 'ADO'})
            arrived = active()
            s.loaded_page(arrived['id'], 'Fixture', 15, selector)
            s.require('routed URL', active()['url'], base + ending)
            s.require('unrelated target stays asleep', next(row for row in s.tabs() if row['id'] == seed['id'])['asleep'], True)
            s.require('target store', arrived['store'], ado)
            s.require('target storage', bench('eval', arrived['id'], 'localStorage.context'), {'value': 'ADO'})
            s.require('first request uses destination cookie', next(cookie for path, cookie in requests if path == ending), 'context=ADO')
            bench('space', 'go', '2')
            s.require('source page is unchanged', next(row for row in s.tabs() if row['id'] == source['id'])['url'], base + '/source')
        s.require('redirect starts only once in ADO', [cookie for path, cookie in requests if path == '/meeting/redirect'], ['context=ADO'])
        for mods in [('cmd',), ('cmd', 'shift'), ('middle',)]:
            bench('select', source['id'])
            bench('tap', source['id'], '#same', *mods)
            s.wait_for('modified click route', lambda: bench('space'), {'current': 'ADO'})
            s.loaded_page(active()['id'], 'Fixture', 15, 'modified click')
            s.require('modified click target store', active()['store'], ado)
            bench('space', 'go', '2')
        print('ok: real same-tab / target blank / modified clicks select ADO before first load; redirects and source page preserved')

        # A real macOS external opening, addressed only to this world's bundle.
        external(base + '/meeting/external')
        s.wait_for('external route', lambda: bench('space'), {'current': 'ADO'})
        s.loaded_page(active()['id'], 'Fixture', 15, 'external')
        s.require('external cookie', next(cookie for path, cookie in requests if path == '/meeting/external'), 'context=ADO')
        bench('space', 'go', '2')
        bench('select', source['id'])
        bench('tap', source['id'], '#plain')
        s.loaded_page(source['id'], 'Fixture', 15, 'unmatched')
        s.require('unmatched same tab', active()['id'], source['id'])
        s.require('unmatched Space', bench('space')['current'], 'Private')
        bench('tap', source['id'], '#plainblank')
        s.until('unmatched blank tab', lambda: active()['id'] != source['id'])
        plain = active()
        s.loaded_page(plain['id'], 'Fixture', 15, 'unmatched blank')
        s.require('unmatched blank store', plain['store'], private)
        bench('tap', plain['id'], '#popup')
        s.until('script popup', lambda: active()['url'] == base + '/popup')
        s.loaded_page(active()['id'], 'Fixture', 15, 'popup')
        s.require('script popup opener', bench('eval', active()['id'], '!!window.opener'), {'value': True})
        bench('tap', active()['id'], '#submit')
        s.until('form navigation', lambda: active()['url'] == base + '/meeting/form')
        s.require('form retains Space', bench('space')['current'], 'Private')
        print('ok: macOS external route; unmatched links and script popup opener; forms keep original context')

        bench('press', '45', 'n', 'cmd', 'shift')
        bench('field', base + '/private', 'go')
        shy = active()
        s.require('private setup', shy['shy'], True)
        s.loaded_page(shy['id'], 'Fixture', 15, 'private')
        bench('eval', shy['id'], "document.cookie='context=Ephemeral; Path=/'; localStorage.context='Ephemeral'")
        bench('tap', shy['id'], '#same')
        s.until('private navigation', lambda: active()['url'] == base + '/meeting/same')
        s.require('private tab retained', active()['id'], shy['id'])
        s.require('private still private', active()['shy'], True)
        s.require('private stays in Space', bench('space')['current'], 'Private')
        bench('tap', shy['id'], '#blank')
        s.until('private new tab', lambda: active()['id'] != shy['id'])
        s.loaded_page(active()['id'], 'Fixture', 15, 'private blank')
        s.require('private new tab remains private', active()['shy'], True)
        s.require('private new tab session', bench('eval', active()['id'], 'localStorage.context'), {'value': 'Ephemeral'})
        print('ok: private same-tab and target blank keep ephemeral session')

        bench('select', source['id'])
        bench('ui', 'spaces', 'off')
        first = load(base + '/spaces-off')
        bench('tap', first['id'], '#same')
        s.until('spaces off navigation', lambda: active()['url'] == base + '/meeting/same')
        s.require('disabled routing keeps tab', active()['id'], first['id'])
        bench('ui', 'spaces', 'on')
        bench('space', 'go', '2')
        # Turning Spaces off closes parked pages; restoration gives them new IDs.
        bench('press', '12', 'q', 'cmd')
        s.until('orderly quit', lambda: not s.running())
        s.launch()
        s.require('rules survive restart', bench('routes')['rules'], routes)
        s.require('private pages not restored', any(row['shy'] for row in s.tabs()), False)
        external(base + '/meeting/restarted')
        s.wait_for('route after restart', lambda: bench('space'), {'current': 'ADO'})
        s.loaded_page(active()['id'], 'Fixture', 15, 'restarted')
        s.require('session survives restart', next(cookie for path, cookie in requests if path == '/meeting/restarted'), 'context=ADO')
        bench('space', 'delete')
        s.require('deleted Space routes removed', [row['destination'] for row in bench('routes')['rules']], [private])
        bench('routes', 'set', '[]')
        bench('press', '12', 'q', 'cmd')
        s.until('quit after removal', lambda: not s.running())
        s.launch()
        s.require('removed rules stay removed', bench('routes')['rules'], [])
        print('ok: Spaces off, restart with cookies, private exclusion, destination deletion and rule removal')


if __name__ == '__main__':
    main()
