#!/usr/bin/env python3
"""The JSON reader's tools, in a tab and in the API Calls panel.

Loopback only: one JSON document of 2,008 values, served as a page and
fetched by a page. Asserted, in both places: Expand All and Collapse All,
pressed as VoiceOver does, open every object and array, then only the top
level; the footer names the 1,000-row cap only while rows are hidden. In the
tab, the copies of a value: its JavaScript path and JSON Pointer, and the
document minified and indented with its big integer, exponent, duplicate
keys and key order as received.

Not covered: ⌥-click on a triangle (a rule test covers the subtree it opens)
and the context menu itself; both call the same reader and document.
Runs in its own world through the shared runner (suite.py) after ./build.sh.
"""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
import suite as s

ROWS = ", ".join('{"i": %d, "tags": ["a", "b"]}' % i for i in range(400))
DOC = ('{"meta": {"big": 9007199254740993123456789, "odd key": {"é": 1.50e+3}, "dup": 1, "dup": 2}, '
       '"rows": [' + ROWS + ']}')
PAGE = """<!doctype html><title>JSON fixture</title><h1>JSON fixture</h1><script>
window.done = true;
async function get() { window.done = false; await fetch('/doc.json?t=panel').then(r => r.text()); window.done = true; }
</script>"""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        page = self.path == '/'
        body = (PAGE if page else DOC).encode()
        self.send_response(200)
        self.send_header('content-type', ('text/html' if page else 'application/json') + '; charset=utf-8')
        self.send_header('content-length', str(len(body)))
        self.send_header('cache-control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def bench(*args):
    return json.loads(s.command(str(s.ROOT / 'bench'), '--world', s.WORLD, '--json', *map(str, args), seconds=40))


def reader(tab, **fields):
    return bench('json-reader', tab, json.dumps(fields))


def calls(**fields):
    return bench('calls', '-', json.dumps(fields))


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    with s.world(server):
        s.launch()

        # In a tab.
        tab = bench('open', base + '/doc.json')['id']
        bench('select', tab)
        bench('wait', tab, 15)
        reader(tab, action='open')
        state = s.until('tab parsed', lambda: (lambda r: r if r['count'] or r['failure'] else None)(reader(tab)))
        s.require('tab parse', (state['count'], state['failure']), (2008, ''))
        s.require('top level only', (state['visible'], state['hidden']), (3, ''))
        s.require('Expand All pressed', reader(tab, press='Expand All')['pressed'], True)
        state = s.wait_for('tab expanded', lambda: reader(tab), {'visible': 2008})
        s.require('tab footer names the cap', state['hidden'], '2008 lines; the first 1,000 are shown. Search narrows them.')
        s.require('Collapse All pressed', reader(tab, press='Collapse All')['pressed'], True)
        s.wait_for('tab collapsed', lambda: reader(tab), {'visible': 3, 'hidden': ''})
        copies = reader(tab, node=4)
        s.require('JavaScript path', copies['script'], '.meta["odd key"].é')
        s.require('JSON Pointer', copies['path'], '/meta/odd key/é')
        s.require('value as written', copies['value'], '1.50e+3')
        top = reader(tab, node=0)
        s.require('minified', top['minified'], DOC.replace(': ', ':').replace(', ', ','))
        s.require('indented head', top['indented'].splitlines()[:9], [
            '{', '  "meta": {', '    "big": 9007199254740993123456789,', '    "odd key": {', '      "é": 1.50e+3',
            '    },', '    "dup": 1,', '    "dup": 2', '  },'])
        s.require('indented lines', len(top['indented'].splitlines()), 10 + 400 * 7 + 2)
        reader(tab, action='raw')
        bench('close', tab)
        print('ok: tab: Expand All, Collapse All, the cap footer and the copies', flush=True)

        # In the API Calls panel.
        bench('bookmark', base + '/', 'new')
        page = s.until('ordinary tab', lambda: s.at(base + '/'))['id']
        s.loaded_page(page, 'JSON fixture', 15, 'fixture page')
        calls(action='open')
        s.until('collecting', lambda: calls()['phase']['name'] == 'collecting')
        bench('eval', page, 'get(); true')
        call = s.until('call listed', lambda: next((r['id'] for r in calls()['rows']
                                                    if 't=panel' in r['url'] and r['state'] == 'done'), None))
        calls(action='select', call=call)
        state = s.until('panel parsed', lambda: (lambda r: r if r['nodes'] else None)(calls()['reader']))
        s.require('panel top level', (state['nodes'], state['visible'], state['hidden']), (2008, 3, ''))
        s.require('panel Expand All pressed', reader(page, press='Expand All')['pressed'], True)
        state = s.wait_for('panel expanded', lambda: calls()['reader'], {'visible': 2008})
        s.require('panel footer names the cap', state['hidden'], '2008 lines; the first 1,000 are shown. Search narrows them.')
        s.require('panel Collapse All pressed', reader(page, press='Collapse All')['pressed'], True)
        s.wait_for('panel collapsed', lambda: calls()['reader'], {'visible': 3, 'hidden': ''})
        calls(action='close')
        print('ok: panel: Expand All, Collapse All and the cap footer', flush=True)


if __name__ == '__main__':
    main()
