#!/usr/bin/env python3
"""Changing Space must not touch what a page is playing.

A meeting, a song and a film are left in a Space and come back to; none of them
may be paused, cut, reloaded or put to sleep by the change alone. Pauses that
the person asked for stay pauses, and a page that plays nothing can still sleep.

The meeting is the synthetic call in fixtures/call: two peers over local ICE, the
far audio in an <audio>, WebKit's mock camera and microphone. The app runs with
production scheduling, so a hidden page is slowed as it is for people. Checked at
each stop: packets still arriving, the audio element not paused, the same
document (a reload would give another marker), camera and microphone active and
their tracks live, and the reason a tab may or may not sleep. What this cannot
show: a real Meet page, a real speaker, or a real camera.

Runs in its own world; ./build.sh debug first. Only 127.0.0.1 is fetched.
"""
import calls as c
import media_player as m
import suite as s

b, js = c.b, c.js


def go(space):
    b('space', 'go', str(space))


def main():
    server, base = c.serve()
    with s.world(server):
        c.launch()
        c.allow_capture('127.0.0.1')

        # A meeting with camera and microphone, left and returned to.
        call = c.open_meeting(base)
        c.join(call)
        marker = js(call, 'call.marker')
        s.require('camera on', c.row(call)['camera'], 'active')
        s.require('microphone on', c.row(call)['microphone'], 'active')
        s.require('audible', c.row(call)['audioValue'], True)
        b('space', 'new', 'Away')

        def marks():
            return b('media')['marks']

        # The Space that holds the meeting wears the microphone, in the Space it is in
        # and from the other one; the empty Space wears nothing.
        s.require('the meeting Space wears the microphone', marks(), ['mic.fill', ''])
        for turn in range(3):
            if turn:
                go(2)
            first = c.stats(call)['audioPackets']
            s.until(f'turn {turn}: packets arrive while parked',
                    lambda: c.stats(call)['audioPackets'] > first + 100, 25)
            parked = c.row(call)
            s.require(f'turn {turn}: audio element playing', js(call, 'call.hear().paused'), False)
            s.require(f'turn {turn}: camera stays on', parked['camera'], 'active')
            s.require(f'turn {turn}: microphone stays on', parked['microphone'], 'active')
            s.require(f'turn {turn}: still counted as sound', parked['noisy'], True)
            s.require(f'turn {turn}: devices live', c.live_devices(call), True)
            s.require(f'turn {turn}: call open', js(call, 'call.phase'), 'in-call')
            s.require(f'turn {turn}: the mark stays on the meeting Space', marks(), ['mic.fill', ''])
            # The pass a memory warning runs: nothing playing sound may sleep.
            b('idle', '0')
            s.require(f'turn {turn}: not put to sleep', c.row(call)['asleep'], False)
            go(1)
            s.until(f'turn {turn}: back on the meeting tab', lambda: c.active() == call)
            s.require(f'turn {turn}: same document, no reload', js(call, 'call.marker'), marker)
            s.require(f'turn {turn}: audio element playing at return', js(call, 'call.hear().paused'), False)
            c.flowing(call)
            s.require(f'turn {turn}: devices live at return', c.live_devices(call), True)
            s.require(f'turn {turn}: camera on at return', c.row(call)['camera'], 'active')

        # A meeting nobody speaks in is the same connection with less sound.
        js(call, 'call.quiet(true)')
        go(2)
        s.until('quiet: connection stays open while parked',
                lambda: js(call, 'call.phase') == 'in-call' and c.stats(call)['audioPackets'] > 0)
        b('idle', '0')
        s.require('quiet call not put to sleep', c.row(call)['asleep'], False)
        go(1)
        s.require('quiet: same document', js(call, 'call.marker'), marker)
        js(call, 'call.quiet(false)')
        b('tap', call, '#leave')
        s.until('call ended', lambda: js(call, 'call.phase') == 'left')
        s.until('the microphone mark goes with the call', lambda: marks() == ['', ''], 20)

        # A song and a film: playing they carry on, paused they stay paused.
        song = m.open_page(base)
        m.start(song)
        film = m.open_page(base)
        m.start(film, '#video')
        idle = m.open_page(base, '/blank')
        for name, tab, element in (('song', song, 'audio'), ('film', film, '#film')):
            b('select', tab)
            go(2)
            s.until(f'{name}: still playing while parked', lambda: js(tab, f'!document.querySelector("{element}").paused'))
            s.require(f'{name}: counted as sound', c.row(tab)['noisy'], True)
            # Both play in this Space, and a picture outweighs a sound.
            s.require(f'{name}: its Space wears the film\'s mark', marks(), ['play.rectangle.fill', ''])
            s.require(f'{name}: kept awake', b('sleep', tab)['asleep'], False)
            go(1)
            s.require(f'{name}: playing after return', js(tab, f'document.querySelector("{element}").paused'), False)
            m.action(tab, 'pause')
            s.until(f'{name}: paused by the person', lambda: js(tab, f'document.querySelector("{element}").paused'))
            left = 'play.rectangle.fill' if name == 'song' else 'speaker.wave.2.fill'
            s.until(f'{name}: paused, the mark follows what still plays', lambda: marks() == [left, ''], 20)
            go(2)
            go(1)
            s.require(f'{name}: a Space change does not resume it', js(tab, f'document.querySelector("{element}").paused'), True)
            m.action(tab, 'play')
            s.until(f'{name}: resumed', lambda: not js(tab, f'document.querySelector("{element}").paused'))

        # Nothing playing: still eligible for sleep, and it is the only one.
        b('select', idle)
        go(2)
        b('idle', '0')
        s.until('silent parked tab sleeps', lambda: c.row(idle)['asleep'])
        for tab in (song, film):
            s.require('sound keeps a tab awake', c.row(tab)['asleep'], False)
        go(1)
        print('ok: meeting with mock camera and microphone, song and film across Space changes; '
              'explicit pauses kept; silent tab sleeps', flush=True)


if __name__ == '__main__':
    main()
