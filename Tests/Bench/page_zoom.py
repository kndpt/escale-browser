#!/usr/bin/env python3
"""Relative zoom, legacy site size, navigation, private/Space isolation, restart
a default zoom set before launch, and one changed while a page is open.

Uses real zoom shortcuts and real WebKit pages on a loopback server. Synthetic
legacy settings are written only into suite.py's unique test world before launch.
"""
import json
from http.server import ThreadingHTTPServer
from threading import Thread
import suite as s


def bench(*args):
    return json.loads(s.command(str(s.ROOT / 'bench'), '--world', s.WORLD, '--json', *args))


def press(code, chars, *mods):
    return bench('press', str(code), chars, *mods)


def active():
    return next(t for t in s.tabs() if t['active'])


def zoom(absolute, relative):
    tab = active()
    assert abs(tab['pageZoom'] - absolute) < 1e-6, tab
    assert abs(tab['zoom'] - relative) < 1e-6, tab


def go(url):
    bench('field', url, 'go')
    tab = active()
    bench('wait', tab['id'], '10')
    return tab['id']


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), s.Page)
    Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    old = f'http://localhost:{server.server_port}'
    try:
        s.command(str(s.ROOT / 'fresh.sh'), 'wipe')
        s.command('defaults', 'write', s.SUITE, 'bench', '-bool', 'YES')
        s.command('defaults', 'write', s.SUITE, 'zoom.localhost', '-float', '1.21')
        s.launch()
        bench('ui', 'welcome', 'off')
        go(base + '/default')
        zoom(1 / 1.1, 1)
        press(24, '+', 'cmd'); zoom(1, 1.1)
        press(27, '-', 'cmd'); zoom(1 / 1.1, 1)
        press(27, '-', 'cmd'); zoom(1 / 1.1**2, 1 / 1.1)
        press(29, '0', 'cmd'); zoom(1 / 1.1, 1)
        go(old + '/legacy'); zoom(1.21, 1.331)
        go(base + '/new-origin'); zoom(1 / 1.1, 1)
        go(old + '/legacy-again'); zoom(1.21, 1.331)
        press(24, '+', 'cmd'); zoom(1.331, 1.4641)
        origin = active()['id']
        press(17, 't', 'cmd')
        go(old + '/new-tab'); zoom(1.331, 1.4641)
        second = active()['id']
        bench('select', origin); zoom(1.331, 1.4641)
        bench('select', second); zoom(1.331, 1.4641)
        bench('ui', 'spaces', 'on')
        bench('space', 'new', 'Other zoom')
        go(old + '/other-space'); zoom(1 / 1.1, 1)
        press(27, '-', 'cmd'); zoom(1 / 1.1**2, 1 / 1.1)
        bench('space', 'go', '1'); zoom(1.331, 1.4641)
        press(45, 'n', 'cmd', 'shift')
        go(old + '/private')
        press(29, '0', 'cmd'); zoom(1 / 1.1, 1)
        press(13, 'w', 'cmd'); zoom(1.331, 1.4641)
        press(12, 'q', 'cmd')
        s.until('quit', lambda: not s.running(), 15)
        s.launch()
        bench('ui', 'welcome', 'off')
        bench('wait', active()['id'], '10'); zoom(1.331, 1.4641)
        bench('space', 'go', '2')
        bench('wait', active()['id'], '10'); zoom(1 / 1.1**2, 1 / 1.1)
        bench('space', 'go', '1')
        press(29, '0', 'cmd'); zoom(1 / 1.1, 1)
        go(old + '/reset-navigation'); zoom(1 / 1.1, 1)
        # A 110% default: sites without a value follow it, ⌘0 returns to it,
        # and a site taken to 100% keeps 100%.
        press(12, 'q', 'cmd')
        s.until('quit', lambda: not s.running(), 15)
        s.command('defaults', 'write', s.SUITE, 'pages.zoom', '-int', '110')
        s.launch()
        bench('ui', 'welcome', 'off')
        bench('wait', active()['id'], '10'); zoom(1, 1.1)
        go(base + '/default-110'); zoom(1, 1.1)
        press(27, '-', 'cmd'); zoom(1 / 1.1, 1)
        go(old + '/default-110'); zoom(1, 1.1)
        go(base + '/kept-100'); zoom(1 / 1.1, 1)
        press(29, '0', 'cmd'); zoom(1, 1.1)
        go(old + '/away'); go(base + '/cleared'); zoom(1, 1.1)
        # A new default moves the page on screen, not a site with its own size.
        press(24, '+', 'cmd'); zoom(1.1, 1.21)
        go(old + '/follows'); zoom(1, 1.1)
        bench('ui', 'zoom', '125'); zoom(1.25 / 1.1, 1.25)
        go(base + '/own'); zoom(1.1, 1.21)
        print('ok: default, shortcuts, legacy size, navigation, tabs, private writes, Spaces, restart and default zoom, set before launch and while open')
    finally:
        s.command(str(s.ROOT / 'fresh.sh'), 'wipe')
        server.shutdown(); server.server_close()


if __name__ == '__main__':
    main()
