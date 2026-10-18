#!/usr/bin/env python3
"""A tab's speaker mutes its page and a second press gives the sound back.

Real WebKit audio from the synthetic WAV in media_player.py. Muting must cut
the output without pausing the media, take the Space's sound mark away, and
outlive a sleep and wake; unmuting must restore both. One probe world owns all
input and data.
"""
from http.server import ThreadingHTTPServer
from threading import Thread
import media_player as m


def run():
    server = ThreadingHTTPServer(('127.0.0.1', 0), m.Page)
    Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    s, b = m.s, m.b

    def tab(id):
        return next(t for t in s.tabs() if t['id'] == id)

    try:
        s.command(str(s.ROOT / 'fresh.sh'), 'wipe')
        s.command('defaults', 'write', s.SUITE, 'bench', '-bool', 'YES')
        s.launch()
        b('ui', 'welcome', 'off')
        b('ui', 'sidebar', 'on')
        b('ui', 'spaces', 'on')
        b('resize', '1100', '760')
        song = m.open_page(base)
        m.start(song)
        m.open_page(base, '/blank')
        s.until('sound mark on the Space', lambda: m.state()['marks'][0] == 'speaker.wave.2.fill')
        s.require('page starts unmuted', tab(song)['pageMuted'], False)

        m.action(song, 'speaker')
        s.until('page muted', lambda: tab(song)['pageMuted'] is True)
        s.require('tab says muted', tab(song)['muted'], True)
        s.require('media keeps playing', m.js(song, 'a.paused'), False)
        s.until('muted tab wears no mark', lambda: m.state()['marks'][0] == '')

        # Quiet, the tab may sleep; the rebuilt page is muted again.
        m.js(song, 'a.pause();true')
        s.until('audio quiet before sleep', lambda: not tab(song)['noisy'])
        s.require('quiet tab sleeps', b('sleep', song)['asleep'], True)
        b('select', song)
        b('wait', song, '10')
        s.until('woken page muted', lambda: tab(song)['pageMuted'] is True)
        s.require('still muted after wake', tab(song)['muted'], True)

        m.js(song, 'a.play();true')
        s.until('audible again', lambda: tab(song)['noisy'])
        m.open_page(base, '/blank')
        m.action(song, 'speaker')
        s.until('page unmuted', lambda: tab(song)['pageMuted'] is False)
        s.require('tab says unmuted', tab(song)['muted'], False)
        s.until('sound mark returns', lambda: m.state()['marks'][0] == 'speaker.wave.2.fill')

        # A real click on the speaker, first row of the column after the
        # welcome-less fresh layout at 1100 x 760, mutes without selecting it.
        b('pointer', 'move', '81', '188')
        b('hit', '81', '188', 'click', 'live')
        s.until('clicked speaker mutes', lambda: tab(song)['pageMuted'] is True)
        s.require('the click leaves the tab behind', tab(song)['active'], False)
        b('hit', '81', '188', 'click', 'live')
        s.until('second click unmutes', lambda: tab(song)['pageMuted'] is False)
        print('ok: speaker mutes without pausing, drops the Space mark, survives sleep and wake, unmutes, answers a real click', flush=True)
    finally:
        s.command(str(s.ROOT / 'fresh.sh'), 'wipe')
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    run()
