#!/usr/bin/env python3
"""Keep the live page beside DevTools through chrome and tab transitions.

An owned probe world serves two ordinary local pages. Actual Cmd-S/Cmd-Opt-I
keys fold chrome and toggle the inspector; geometry, document identity, drafts
and scroll must survive. DOM/frame assertions do not prove compositor output
or every blank-page failure. No extension, Internet page or installed browser
participates.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
import json
import time
import suite as s


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        body = ("<title>Inspector layout</title><style>"
                "body{margin:0;background:#547f91;color:white;height:4000px}"
                "header{position:fixed;top:0;left:0;right:0;padding:24px;background:#264653}"
                "</style><header><h1>" + self.path + " — live page</h1>"
                "<input id='draft' aria-label='Draft'></header>"
                "<script>window.marker=crypto.randomUUID()</script>").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def bench(*args):
    return json.loads(s.command(str(s.ROOT / 'bench'), '--world', s.WORLD, '--json', *args))


def js(tab, script):
    return bench('eval', tab, script)['value']


def frame():
    return bench('probe').get('pageFrame', [])


def close_enough(actual, expected):
    return len(actual) == len(expected) and all(abs(a - b) <= 1 for a, b in zip(actual, expected))


def expect_frame(name, expected):
    try:
        s.until(name, lambda: close_enough(frame(), expected), 5)
    except s.WaitExpired as error:
        raise AssertionError(f'{name}: expected {expected}, observed {frame()}') from error
    actual = frame()
    print(f'ok: {name}: {actual}', flush=True)
    return actual


def state(tab):
    return js(tab, "[window.marker,location.href,document.querySelector('#draft').value,scrollY]")


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Page)
    Thread(target=server.serve_forever, daemon=True).start()
    with s.world(server):
        s.launch()
        bench('resize', '1400', '850')
        bench('ui', 'sidebar', 'on')
        bench('ui', 'bar', 'on')
        bench('ui', 'folded', 'off')
        tabs = []
        states = {}
        for name in ('first', 'second'):
            bench('bookmark', f'http://127.0.0.1:{server.server_port}/{name}', 'new')
            tab = next(t for t in s.tabs() if t['active'])['id']
            loaded = bench('wait', tab, '10')
            assert not loaded.get('timeout') and not loaded.get('failure') and not loaded['loading'], loaded
            s.until('fixture ready', lambda: js(tab, '!!window.marker'), 5)
            js(tab, "document.querySelector('#draft').focus();true")
            bench('key', tab, 'kept draft ' + name)
            js(tab, "document.querySelector('#draft').blur();scrollTo(0,600);true")
            s.until('scrolled', lambda: abs(js(tab, 'scrollY') - 600) <= 1, 5)
            tabs.append(tab)
            states[tab] = state(tab)
        first, second = tabs
        bench('select', first)
        time.sleep(.4)
        full = frame()
        assert len(full) == 4 and full[2] > 900, full

        for opened in (False, True):
            bench('ui', 'look', 'light')
            if opened:
                bench('press', '34', 'i', 'cmd', 'opt')
                s.until('right dock', lambda: len(frame()) == 4 and frame()[2] < full[2] - 100, 5)
            time.sleep(.4)
            home = frame()
            inspector_width = full[2] - home[2]
            assert close_enough(home[1::2], full[1::2]), (home, full)
            for cycle in range(3):
                if cycle == 2:
                    bench('ui', 'look', 'dark')
                bench('press', '1', 's', 'cmd')
                s.until('sidebar folded', lambda: bench('probe')['folded'], 5)
                s.until('stage moved', lambda: frame()[0] < home[0] - 100, 5)
                time.sleep(.4)
                x = frame()[0]
                expect_frame('folded, inspector=' + str(opened),
                                      [x, home[1], home[2] + home[0] - x, home[3]])
                bench('press', '1', 's', 'cmd')
                expect_frame('expanded, inspector=' + str(opened), home)
                for tab in (second, first):
                    bench('select', tab)
                    expect_frame('tab return, inspector=' + str(opened), home)
                    s.require('document, draft and scroll preserved', state(tab), states[tab])
                    viewport = js(tab, '[innerWidth,innerHeight]')
                    zoom = next(t for t in s.tabs() if t['id'] == tab)['pageZoom']
                    assert close_enough([v * zoom for v in viewport], home[2:]), (viewport, zoom, home)
            bench('resize', '1500', '900')
            expect_frame('window grows', [home[0], home[1], home[2] + 100, home[3] + 50])
            bench('resize', '1400', '850')
            expect_frame('window restores', home)
            if opened:
                assert inspector_width > 100, inspector_width
                bench('press', '34', 'i', 'cmd', 'opt')
                expect_frame('inspector closes', full)
        print('ok: repeated folds, tab returns, native resize, unchanged live documents/drafts/scroll', flush=True)


if __name__ == '__main__':
    main()
