#!/usr/bin/env python3
"""Stop a still-loading document through its native control while audio plays.

A held image keeps WebKit loading without delaying the playable local WAV.
The same document must retain its reader, controls and dismissed state; a real
navigation must still remove them. All input and data belong to one probe world.
"""
from http.server import ThreadingHTTPServer
from threading import Event, Thread
import media_player as m

finish = Event()
requested = Event()


class Page(m.Page):
    def do_GET(self):
        if self.path.startswith('/held.svg'):
            requested.set()
            finish.wait(45)
            data = b'<svg xmlns="http://www.w3.org/2000/svg"/>'
            self.send_response(200)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            try:
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass
        elif self.path.startswith('/loading'):
            data = (m.HTML + '<img src="/held.svg">').encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        else:
            super().do_GET()


def run():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Page)
    Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    s, b = m.s, m.b
    try:
        s.command(str(s.ROOT / 'fresh.sh'), 'wipe')
        s.command('defaults', 'write', s.SUITE, 'bench', '-bool', 'YES')
        s.launch()
        b('ui', 'welcome', 'off')
        b('ui', 'sidebar', 'off')
        b('ui', 'size', 'compact')
        b('resize', '1100', '760')
        for dismissed in (False, True):
            finish.clear()
            requested.clear()
            b('bookmark', base + '/loading', 'new')
            tab = next(t for t in s.tabs() if t['active'])['id']
            s.until('held image requested', requested.is_set)
            s.until('audio ready during load', lambda: m.js(tab, 'a.readyState >= 2'))
            m.start(tab)
            if dismissed:
                m.action(tab, 'dismiss')
            assert next(t for t in s.tabs() if t['id'] == tab)['loading']
            # Compact horizontal toolbar after ChromeMetrics rounding: lights
            # 90, two 23.5 pt doors with 2 pt gaps, then Stop's centre.
            b('hit', '153', '16', 'click', 'live')
            s.until('native Stop ends loading', lambda: not next(t for t in s.tabs() if t['id'] == tab)['loading'])
            assert m.js(tab, 'a.paused') is False
            if dismissed:
                s.require('Stop preserves dismissal', m.find(tab), None)
                s.require('no dismissed reader', m.state()['listeners'], 0)
            else:
                assert m.find(tab), 'Stop lost the still-playing source'
                assert m.find(tab)['playing']
                assert 'pause' in m.find(tab)['actions']
                s.require('one retained reader', m.state()['listeners'], 1)
            finish.set()
            b('ui', 'sidebar', 'on')
            m.open_page(base, '/blank')
            s.until('stopped source visible after leaving', lambda: m.visible(tab))
            m.action(tab, 'pause')
            s.until('pause reaches retained element', lambda: m.js(tab, 'a.paused'))
            m.action(tab, 'play')
            s.until('resume reaches retained element', lambda: not m.js(tab, 'a.paused'))
            b('select', tab)
            b('field', base + '/blank-navigated', 'go')
            s.until('navigation clears source', lambda: m.find(tab) is None)
            s.require('navigation removes reader', m.state()['listeners'], 0)
            b('ui', 'sidebar', 'off')
        print('ok: native Stop preserves playing/dismissed media, leave, pause/resume and navigation cleanup', flush=True)
    finally:
        finish.set()
        s.command(str(s.ROOT / 'fresh.sh'), 'wipe')
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    run()
