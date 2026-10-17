#!/usr/bin/env python3
"""A page that never arrives names its address and WebKit's code, and Back
returns to the page the view still holds.

A closed loopback port fails without leaving this Mac; `.invalid` is reserved
never to resolve (RFC 6761).
Covers the tab's failure state and ⌘[, which the error page's Back button
calls too; not the button's drawing (visual review).
"""
import json
import socket
from http.server import ThreadingHTTPServer
from threading import Thread
import suite as s


def bench(*args):
    return json.loads(s.command(str(s.ROOT / 'bench'), '--world', s.WORLD, '--json', *args))


def active():
    return next(t for t in s.tabs() if t['active'])


def closed_port():
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        return probe.getsockname()[1]


def fails(url):
    bench('field', url, 'go')
    return s.until(f'failure for {url}', lambda: (t if (t := active()).get('failure') else None), 15)


def run():
    server = ThreadingHTTPServer(('127.0.0.1', 0), s.Page)
    Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    with s.world(server):
        s.launch()
        bench('ui', 'welcome', 'off')
        s.open_ordinary(base + '/before')
        refused = f'http://127.0.0.1:{closed_port()}/gone'
        tab = fails(refused)
        s.require('refused message', tab['failure'], 'The site refused the connection.')
        s.require('refused code', tab['failedCode'], 'NSURLErrorDomain -1004')
        s.require('the tab names the failed address', tab['url'], refused)
        s.require('back offered over the page before', tab['backFromFailure'], True)
        bench('press', '33', '[', 'cmd')
        s.until('back to the page before', lambda: active()['url'] == base + '/before' and 'failure' not in active(), 10)
        s.require('the page before keeps its title', active()['title'], 'Suite before')
        tab = fails('http://nowhere.invalid/')
        s.require('missing host message', tab['failure'], 'No site at that address.')
        s.require('missing host code', tab['failedCode'], 'NSURLErrorDomain -1003')
        # A tab whose first page fails has nothing behind it.
        bench('bookmark', refused, 'new')
        s.until('a new tab fails', lambda: (t := active())['url'] == refused and t.get('failure'), 15)
        s.require('no back without a page behind', active()['backFromFailure'], False)
        print('ok: refused port and missing host show their address and code; ⌘[ returns to the page behind; none without one')


if __name__ == '__main__':
    run()
