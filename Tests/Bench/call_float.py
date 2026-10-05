#!/usr/bin/env python3
"""A meeting can be kept in its own floating window without leaving it.

The page is the synthetic call in fixtures/call, loaded under Meet's address so
the host rules apply, with WebKit's mock camera and microphone and production
scheduling. Its page has what a call page has to be told apart from: a large
decorative video behind everything, the sender's own mirrored tile, named tiles
that grow with the speaker, a participant with no camera, a screen that arrives
by renegotiation, and tiles transformed and cut to their own painting.

Checked: nothing floats before the meeting has begun, however the tab is left;
leaving a live meeting opens the meeting window, with the page kept at an
ordinary size behind it: everyone as a named card, a picture or their photo
and a muted microphone where the page shows one, the speaker large, then the
shared screen whole and at its shape with the people still along the top; the
same document, connection, audio, camera and microphone throughout; the
page's commands on offer (microphone, camera, presenting, the raised hand,
hanging up), each pressing the page's own button, the outgoing tracks really
changing, and the window saying what each will do next; every camera off
keeps the window and the meeting, across a Space change and a pass that puts
idle tabs to sleep; landing gives the page back its zoom; landing and going
back both leave the meeting running; the mini player card and the window hand
it to each other with the same button as a film's; a return before the page
has answered keeps it in its tab; a hang-up the page cannot take keeps the
window; it stays while another Space is used, comes home when its tab is
returned to, and closes on its own when the meeting ends; and a page that is
not a meeting floats nothing by itself. What this cannot show: a real Meet
page, a physical display, the buttons' native clicks (their callbacks are
pressed instead) or the system's screen picker.

Runs in its own world; ./build.sh debug first. Only 127.0.0.1 is fetched.
"""
import time
import calls as c
import media_player as m
import suite as s

b, js = c.b, c.js
CONTROLS = ['return', 'mini player', 'microphone', 'camera', 'present', 'options', 'hang up']


def floating():
    return b('media')['floating']


def out(tab):
    return (floating() or '').lower().startswith(tab)


def stage(tab):
    """Who the meeting window shows large, by name, or None."""
    return js(tab, "window.__escaleMeeting ? window.__escaleMeeting.stage : 'no window'")


def cards(tab):
    """The people the window shows, as the page drew them."""
    return {one['name']: one for one in js(tab, "window.__escaleMeeting ? window.__escaleMeeting.cards : []")}


def framing(tab):
    """Where the large picture stands: `framed` when it is inside the window and
    the page draws the whole of its frame (contain), reached at its four corners,
    so nothing moves or cuts it."""
    return js(tab, """(() => {
      const room = document.querySelector('escale-meeting')?.shadowRoot;
      const v = room?.querySelector('.stage video');
      if (!v) return 'no stage';
      const r = v.getBoundingClientRect(), w = innerWidth, h = innerHeight;
      if (r.left < -1 || r.top < -1 || r.right > w + 1 || r.bottom > h + 1 || r.width < 50)
        return 'box ' + [r.left, r.top, r.width, r.height].map(Math.round) + ' in ' + w + 'x' + h;
      if (getComputedStyle(v).objectFit !== 'contain') return 'fit ' + getComputedStyle(v).objectFit;
      const missed = [[r.left + 2, r.top + 2], [r.right - 3, r.top + 2], [r.left + 2, r.bottom - 3], [r.right - 3, r.bottom - 3]]
        .filter(([x, y]) => room.elementFromPoint(x, y) !== v);
      return missed.length ? 'cut at ' + JSON.stringify(missed) : 'framed';
    })()""")


def framed(what, tab):
    s.wait_for(what, lambda: {'framing': framing(tab)}, {'framing': 'framed'})


def mirrored(tab, name):
    """Whether the window mirrors the card of this name, as a camera's preview is."""
    return js(tab, f"""[...document.querySelector('escale-meeting').shadowRoot.querySelectorAll('.card')]
      .find(one => one.querySelector('.name')?.textContent === {name!r})?.classList.contains('mirrored')""")


def looks(name):
    return b('media')['floatLooks'].get(name)


def alive(tab, marker, pictures=True):
    """The meeting itself, untouched: same document, connected, sounding, sending."""
    s.require('same document', js(tab, 'call.marker'), marker)
    s.require('call open', js(tab, 'call.phase'), 'in-call')
    s.require('audio element playing', js(tab, 'call.hear().paused'), False)
    s.require('camera and microphone live', c.live_devices(tab), True)
    row = c.row(tab)
    s.require('camera on', row['camera'], 'active')
    s.require('microphone on', row['microphone'], 'active')
    s.require('page awake', row['asleep'], False)
    c.flowing(tab)
    if pictures:
        c.watching(tab)


def main():
    server, base = c.serve()
    with s.world(server):
        c.launch()
        c.allow_capture('meet.google.com')
        elsewhere = m.open_page(base, '/blank')
        meeting = c.open_meeting(base, as_meet=True)
        pages = b('space')['pages']

        # Before joining, the page shows only the sender's own picture and a
        # decoration: leaving it opens nothing, by tab or by shortcut.
        b('select', elsewhere)
        time.sleep(1.5)
        s.require('no window before the meeting', floating(), None)
        b('select', meeting)
        b('press', '35', 'p', 'cmd', 'shift')
        time.sleep(1)
        s.require('nothing to float by hand either', floating(), None)

        c.join(meeting)
        marker = js(meeting, 'call.marker')
        zoom = c.row(meeting)['pageZoom']
        s.until('decoration and preview are playing too',
                lambda: js(meeting, "[...document.querySelectorAll('video')].filter(v => !v.paused).length") >= 4)
        s.until('the speaker is shown large',
                lambda: js(meeting, "document.querySelector('.tile.speaking')?.dataset.who") == 'ada')

        # Cara's photo comes from a server that forbids keeping it: any load of it
        # is a request. The page has loaded it once; the window must not again.
        js(meeting, f"document.querySelector('.tile[data-who=cara] img').src = '{base}/photo.png'; true")
        s.until('the page loaded the photo', lambda: js(meeting,
                "(i => i.complete && i.naturalWidth === 64)(document.querySelector('.tile[data-who=cara] img'))"))
        photos = c.Page.photos

        # Leaving the tab of a live meeting opens its window.
        b('select', elsewhere)
        s.until('meeting floats on leaving', lambda: out(meeting))
        s.require('window is for a meeting', b('media')['floatCall'], True)
        s.until('what the meeting offers, found in its page',
                lambda: b('media')['floatControls'] == CONTROLS)
        s.require('one page', b('space')['pages'], pages)
        # The site is laid out as in an ordinary window, which is what keeps
        # everyone in it on its page (and their streams arriving).
        s.require('the page is zoomed out while it floats', c.row(meeting)['pageZoom'] < zoom, True)
        s.require('the site sees an ordinary window', js(meeting, 'innerWidth') >= 800, True)
        s.until('everyone is on a card', lambda: set(cards(meeting)) == {'Ada', 'Bob', 'Cara', 'You'})
        people = cards(meeting)
        s.require('a camera is a picture', people['Bob']['video'], True)
        s.require('no camera is their photo', (people['Cara']['video'], people['Cara']['picture']), (False, True))
        s.require('a muted microphone shows', (people['Cara']['muted'], people['Bob']['muted']), (True, False))
        time.sleep(1)
        s.require('the photo was not asked for again', c.Page.photos, photos)
        s.require('the photo is drawn', js(meeting, "!!document.querySelector('escale-meeting').shadowRoot.querySelector('.face canvas')"), True)
        s.until('the speaker large', lambda: stage(meeting) == 'Ada')
        framed('the speaker fills the stage', meeting)
        alive(meeting, marker)

        # A change of speaker, a shared screen, and the screen stopping.
        js(meeting, "document.querySelector('#speaker').click(); true")
        s.until('follows the new speaker', lambda: stage(meeting) == 'Bob')
        js(meeting, "document.querySelector('#share').click(); true")
        s.until('the shared screen goes large', lambda: stage(meeting) == 'Ada (Presentation)', 20)
        framed('the whole shared screen is in the window', meeting)
        s.require('the people stay in view while it is shared',
                  {'Ada', 'Bob', 'Cara', 'You'} <= set(cards(meeting)), True)
        alive(meeting, marker)
        js(meeting, "document.querySelector('#share').click(); true")
        s.until('back to the speaker when sharing stops', lambda: stage(meeting) == 'Bob', 20)
        s.require('still floating', out(meeting), True)

        # The microphone: the window presses the page's button, and the sound really stops.
        s.require('microphone open', js(meeting, 'call.micLive()'), [True])
        s.require('the window offers to mute', looks('microphone'), 'Mute the microphone')
        c.press(meeting, 'mute')
        s.until('muted by the window', lambda: js(meeting, 'call.muted') is True)
        s.require('outgoing microphone track stopped', js(meeting, 'call.micLive()'), [False])
        s.require('the page shows it muted', js(meeting, "document.querySelector('#mic').dataset.isMuted"), 'true')
        s.until('the window shows it muted', lambda: looks('microphone') == 'Unmute the microphone')
        alive(meeting, marker)
        c.press(meeting, 'mute')
        s.until('unmuted by the window', lambda: js(meeting, 'call.muted') is False)
        s.require('outgoing microphone track carries sound', js(meeting, 'call.micLive()'), [True])

        # The camera, the same way: the outgoing picture really stops.
        c.press(meeting, 'camera')
        s.until('camera off by the window', lambda: js(meeting, 'call.cameraOff') is True)
        s.require('outgoing picture stopped',
                  js(meeting, "document.querySelector('#self').srcObject.getVideoTracks().map(t => t.enabled)"), [False])
        s.until('the window shows it off', lambda: looks('camera') == 'Turn the camera on')
        c.press(meeting, 'camera')
        s.until('camera on again', lambda: js(meeting, 'call.cameraOff') is False)
        s.until('the window shows it on', lambda: looks('camera') == 'Turn the camera off')

        # A raised hand, from the options.
        c.press(meeting, 'hand')
        s.until('hand raised by the window', lambda: js(meeting, 'call.hand') is True)
        s.until('the window shows it raised', lambda: looks('options') == 'More options, hand raised')
        c.press(meeting, 'hand')
        s.until('hand lowered', lambda: js(meeting, 'call.hand') is False)

        # Presenting asks the page for a screen, which it may do only in answer to a press.
        # The page asking on its own, from a timer, is refused; the window's press is not.
        js(meeting, "setTimeout(() => document.querySelector('#present').click(), 1500); true")
        s.until('the page asked on its own', lambda: js(meeting, 'call.presentError'), 10)
        s.require('and was refused', js(meeting, 'call.presenting'), False)
        # The page keeps that refusal until a share succeeds: clear it, so the
        # wait below reads the press's own outcome, not the earlier one.
        js(meeting, 'call.presentError = null; true')
        c.press(meeting, 'present')
        s.until('the page answered the press to present',
                lambda: js(meeting, 'call.presenting') or js(meeting, 'call.presentError'), 20)
        s.require('the press counts as the person asking', js(meeting, 'call.presentError'), None)
        s.until('the window shows the presentation', lambda: looks('present') == 'Stop presenting')
        # One's own screen, named as Meet names it in French, goes large and whole, never
        # mirrored; one's own camera stays mirrored as the page shows it, others' are not.
        s.until('your own screen goes large', lambda: stage(meeting) == 'Vous êtes en train de présenter')
        framed('your whole screen is in the window', meeting)
        s.require('a screen is never mirrored, even where the page mirrors it',
                  mirrored(meeting, 'Vous êtes en train de présenter'), False)
        s.require('your camera is mirrored as the page shows it', mirrored(meeting, 'You'), True)
        s.require("someone else's camera is not", mirrored(meeting, 'Bob'), False)
        c.press(meeting, 'present')
        s.until('presenting stopped', lambda: js(meeting, 'call.presenting') is False)
        s.until('the window offers to present again', lambda: looks('present') == 'Present your screen')
        alive(meeting, marker)

        # Landing the window (the shortcut, without going to the tab) is not leaving the meeting.
        b('press', '35', 'p', 'cmd', 'shift')
        s.until('window closed', lambda: floating() is None)
        s.until('page restored to its tab',
                lambda: js(meeting, "!document.documentElement.classList.contains('escale-meeting')"))
        s.require('window taken off the page',
                  js(meeting, "!document.querySelector('escale-meeting') && window.__escaleMeetingWatch === null"), True)
        s.require('the page has its own zoom back', c.row(meeting)['pageZoom'], zoom)
        alive(meeting, marker)
        s.require('one page after closing', b('space')['pages'], pages)

        # Leaving again, then the way back: the tab is selected, the meeting runs on.
        b('select', meeting)
        b('select', elsewhere)
        s.until('floats again', lambda: out(meeting))
        c.press(meeting, 'back')
        s.until('window gone', lambda: floating() is None)
        s.until('back on the meeting tab', lambda: c.active() == meeting)
        alive(meeting, marker)

        # Coming back before the page has answered must not float the tab you are on. The page
        # is kept busy so its answer to leaving arrives after the return.
        js(meeting, "setTimeout(() => { const t = Date.now(); while (Date.now() - t < 800); }, 50); true")
        time.sleep(0.2)
        b('select', elsewhere)
        b('select', meeting)
        time.sleep(2)
        s.require('a quick return leaves the meeting in its tab', floating(), None)
        s.require('page in its tab', js(meeting, "!document.documentElement.classList.contains('escale-meeting')"), True)
        s.require('on the meeting tab', c.active(), meeting)
        alive(meeting, marker)

        # The mini player is the same way out as a film's: the window hands the meeting to the
        # sidebar card, whose Picture in Picture button opens it again, with no reload.
        def carded():
            return any(v.lower().startswith(meeting) for v in b('media')['visible'])

        b('select', elsewhere)
        s.until('floats before the mini player', lambda: out(meeting))
        c.press(meeting, 'minimize')
        s.until('window closed for the mini player', lambda: floating() is None)
        s.until('the meeting is in the sidebar card', carded)
        s.until('page restored to its tab',
                lambda: js(meeting, "!document.documentElement.classList.contains('escale-meeting')"))
        alive(meeting, marker)
        c.press(meeting, 'float')
        s.until('opened again from the card', lambda: out(meeting))
        s.require('as a meeting', b('media')['floatCall'], True)
        s.until('with everyone', lambda: set(cards(meeting)) == {'Ada', 'Bob', 'Cara', 'You'})
        alive(meeting, marker)
        c.press(meeting, 'back')
        s.until('window gone', lambda: floating() is None)
        s.until('back on the meeting tab', lambda: c.active() == meeting)
        alive(meeting, marker)

        # The keyboard shortcut opens and lands it the same way from the tab itself.
        b('press', '35', 'p', 'cmd', 'shift')
        s.until('shortcut opens the meeting', lambda: out(meeting))
        s.require('as a meeting', b('media')['floatCall'], True)
        # The page leaves the meeting's address without a new document, as a meeting
        # that ends may: it is still put back the way it was taken out.
        path = js(meeting, 'location.pathname')
        js(meeting, "history.pushState({}, '', '/landing'); true")
        s.until('the tab follows the address', lambda: '/landing' in next(t['url'] for t in s.tabs() if t['id'].lower().startswith(meeting.lower())))
        b('press', '35', 'p', 'cmd', 'shift')
        s.until('shortcut lands it', lambda: floating() is None)
        s.until('the meeting is taken off the page, whatever its address',
                lambda: js(meeting, "!document.documentElement.classList.contains('escale-meeting') && !document.querySelector('escale-meeting')"))
        js(meeting, f"history.pushState({{}}, '', '{path}'); true")
        s.until('back at the meeting address', lambda: path in next(t['url'] for t in s.tabs() if t['id'].lower().startswith(meeting.lower())))
        alive(meeting, marker)

        # Another Space: the window stays and the meeting goes on. Coming home lands it.
        b('space', 'new', 'Away')
        s.until('meeting still out in another Space', lambda: out(meeting))
        # The window in the other Space reads its commands from the page again.
        s.wait_for('window kept its commands', lambda: {'controls': b('media')['floatControls']},
                   {'controls': CONTROLS})
        alive(meeting, marker)
        b('space', 'go', '1')
        s.until('landed on returning to its tab', lambda: floating() is None)
        s.until('back on the meeting tab', lambda: c.active() == meeting)
        alive(meeting, marker)
        # And from that Space the window's own way back crosses Spaces.
        b('space', 'go', '2')
        s.until('meeting out again after leaving by Space', lambda: out(meeting))
        b('space', 'go', '1')
        s.until('landed', lambda: floating() is None)
        b('select', elsewhere)
        s.until('floats from the row', lambda: out(meeting))
        b('space', 'go', '2')
        s.until('still out', lambda: out(meeting))
        c.press(meeting, 'back')
        s.until('way back crosses Spaces', lambda: floating() is None and c.active() == meeting)
        alive(meeting, marker)

        # Everyone else turns their camera off. The people are still there, and so is the
        # window: it must not close with no picture left to show, sending the meeting
        # back to a tab in a Space nobody was looking at.
        b('select', elsewhere)
        s.until('floats before the cameras go off', lambda: out(meeting))
        js(meeting, "document.querySelector('#cameras').click(); true")
        s.until('no one else has a picture',
                lambda: not any(one['video'] for name, one in cards(meeting).items() if name != 'You'))
        s.until('each shown by their photo, once it has loaded',
                lambda: all(cards(meeting)[name]['picture'] for name in ('Ada', 'Bob', 'Cara')))
        b('space', 'go', '2')
        time.sleep(6)
        s.require('the window stays without cameras, in another Space', out(meeting), True)
        s.require('kept awake by its window', b('idle', '0') and c.row(meeting)['asleep'], False)
        alive(meeting, marker, pictures=False)

        # Hanging up from the window leaves the meeting, and the page goes home.
        # A page that no longer offers its leave button is still in the meeting: pressing the
        # window's hang-up neither ends it nor pretends to.
        js(meeting, "(() => { const l = document.querySelector('#leave'); l.removeAttribute('jsname'); l.setAttribute('aria-label', 'Options'); })(); true")
        s.until('no hang-up without the page\'s button', lambda: 'hang up' not in b('media')['floatControls'])
        c.press(meeting, 'hangup')
        time.sleep(1.5)
        s.require('a hang-up the page cannot take keeps the window', out(meeting), True)
        s.require('and the meeting', js(meeting, 'call.phase'), 'in-call')
        js(meeting, "(() => { const l = document.querySelector('#leave'); l.setAttribute('jsname', 'CQylAd'); l.setAttribute('aria-label', 'Leave call'); })(); true")
        s.until('the way to leave is offered again', lambda: 'hang up' in b('media')['floatControls'])

        # As the meeting's host, Meet asks what to do, in a dialog the window does not show.
        # A question the window cannot answer brings the meeting's tab forward rather than
        # closing the window on a call that goes on.
        js(meeting, "call.host = 'odd'; true")
        c.press(meeting, 'hangup')
        s.until('the meeting shown in its tab', lambda: floating() is None and c.active() == meeting, 15)
        s.require('still in the call', js(meeting, 'call.phase'), 'in-call')
        s.require('its question on show', js(meeting, "!!document.querySelector('[role=dialog]')"), True)
        js(meeting, "document.querySelector('[role=dialog]').remove(); call.host = true; true")
        b('select', elsewhere)
        s.until('floats again for the host', lambda: out(meeting))
        # The usual question is answered with leave, as the button says: never with
        # ending the call for everyone.
        c.press(meeting, 'hangup')
        s.until('the call ended', lambda: js(meeting, 'call.phase') == 'left')
        s.require('left, not ended for everyone', js(meeting, 'call.endedForAll'), False)
        s.until('window gone after hanging up', lambda: floating() is None)
        s.until('page restored', lambda: js(meeting, "!document.documentElement.classList.contains('escale-meeting')"))

        # The meeting ending in its page closes the window by itself.
        b('space', 'go', '1')
        b('select', meeting)
        c.join(meeting)
        marker = js(meeting, 'call.marker')
        b('select', elsewhere)
        s.until('floats after joining again', lambda: out(meeting))
        js(meeting, "call.host = false; document.querySelector('#leave').click(); true")
        s.until('window closes by itself when the meeting ends', lambda: floating() is None, 20)
        s.until('page restored', lambda: js(meeting, "!document.documentElement.classList.contains('escale-meeting')"))

        # Left while it is in the mini player's card, the meeting takes its card with it,
        # even when its page goes on playing a sound of its own, as Meet's does.
        b('select', meeting)
        c.join(meeting, camera=False)
        c.watching(meeting)
        b('select', elsewhere)
        s.until('floats before the card', lambda: out(meeting))
        c.press(meeting, 'minimize')
        s.until('in the card', carded)
        js(meeting, "call.lingering = true; call.leave(); true")
        s.until('the page still sounds once left', lambda: c.row(meeting)['noisy'])
        s.until('the card goes with the meeting', lambda: not carded(), 10)
        js(meeting, "call.lingering = false; true")

        # A meeting whose page goes to another site while it floats lands at the zoom
        # kept for that site, not at the one it had before floating.
        b('select', elsewhere)
        b('press', '24', '=', 'cmd')
        s.until('the other site zoomed in', lambda: c.row(elsewhere)['pageZoom'] > zoom)
        kept = c.row(elsewhere)['pageZoom']
        b('select', meeting)
        c.join(meeting, camera=False)
        c.watching(meeting)
        b('select', elsewhere)
        s.until('floats before going elsewhere', lambda: out(meeting))
        js(meeting, f"location.href = '{base}/blank'; true")
        s.until('the window closes with no meeting left', lambda: floating() is None, 20)
        s.until('the zoom kept for where the page went', lambda: c.row(meeting)['pageZoom'] == kept)

        # A page that is not a meeting floats nothing by itself.
        other = c.open_meeting(base)
        c.join(other, camera=False)
        b('select', elsewhere)
        time.sleep(2)
        s.require('a call on another site is left alone', floating(), None)
        print("ok: the meeting window shows everyone and the whole shared screen, presses the page's "
              'microphone, camera, presenting, hand and hang-up, stays with every camera off across Spaces '
              'and sleep, lands and returns without leaving the call, closes when the meeting ends; '
              'other pages unchanged', flush=True)


if __name__ == '__main__':
    main()
