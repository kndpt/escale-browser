"""Shared pieces for the scenarios about meetings.

The synthetic meeting is `fixtures/call/index.html`: a far side and a near side
in one page over local ICE, WebKit's mock camera and microphone, no account and
no network. A test run gives its pages WebKit's mock capture devices, and the
app starts with production scheduling (`ESCALE_MEASURE`), so a page nobody looks
at is slowed and suspended the way people's are.
"""
import json
import struct
import zlib
from pathlib import Path
from http.server import ThreadingHTTPServer
from threading import Thread
import media_player as m
import suite as s

FIXTURE = Path(__file__).parent / 'fixtures' / 'call' / 'index.html'
# A meeting's real address, for logic keyed on the host. The page is loaded
# under it from a string, so nothing leaves the machine.
MEET = 'https://meet.google.com/abc-defg-hij'
b, js = m.b, m.js


def square(size=64, rgb=(0x5e, 0x35, 0xb1)):
    """A plain PNG, for a participant's photo."""
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    rows = b''.join(b'\0' + bytes(rgb) * size for _ in range(size))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


class Page(m.Page):
    # How often the photo was asked for: it is never to be cached, so each
    # load is a request.
    photos = 0

    def do_GET(self):
        if self.path.startswith('/photo.png'):
            Page.photos += 1
            data = square()
            self.send_response(200)
            self.send_header('Content-Type', 'image/png')
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(data)
            return
        if not self.path.startswith('/call'):
            return super().do_GET()
        data = FIXTURE.read_bytes()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(data)


def serve():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Page)
    Thread(target=server.serve_forever, daemon=True).start()
    return server, f'http://127.0.0.1:{server.server_port}'


def launch():
    """The world with production scheduling, chrome ready for Spaces."""
    s.command('env', 'ESCALE_MEASURE=1', str(s.ROOT / 'fresh.sh'), 'again')
    s.until('probe socket', s.probe_ready, 30)
    b('ui', 'welcome', 'off'); b('ui', 'sidebar', 'on'); b('ui', 'spaces', 'on'); b('resize', '1100', '760')


def allow_capture(host):
    """Camera and microphone for a host in the Space on screen (type 2: both)."""
    s.require('capture allowed', b('space', 'capture', host, '2', 'allow')['choice'], True)


def active():
    return next(t for t in s.tabs() if t['active'])['id']


def open_meeting(base, path='/call', as_meet=False):
    """A tab on the meeting page, and its id. `as_meet` gives it Meet's address."""
    tab = m.open_page(base, path if not as_meet else '/blank')
    if as_meet:
        b('media', tab, json.dumps({'action': 'fixture', 'html': FIXTURE.read_text(), 'base': MEET}))
        s.until('meeting page loaded', lambda: js(tab, "typeof call === 'object'") is True)
    return tab


def join(tab, camera=True):
    """A real click on Join, then on the camera button, and wait for both."""
    b('tap', tab, '#join')
    try:
        s.until('in call', lambda: js(tab, 'call.phase') == 'in-call', 20)
    except s.WaitExpired as error:
        raise s.WaitExpired(f"{error}; page said {js(tab, 'JSON.stringify({phase: call.phase, error: call.error, audio: call.audio, ice: call.ice})')}") from error
    if camera:
        b('tap', tab, '#camera')
        try:
            s.until('mock devices', lambda: js(tab, 'call.devices && call.devices.length') == 2, 20)
        except s.WaitExpired as error:
            raise s.WaitExpired(f"{error}; page said {js(tab, 'JSON.stringify({error: call.error, phase: call.phase})')}") from error


def stats(tab):
    """Media counters received so far. The promise is read on the next call."""
    js(tab, 'call.stats().then(one => { window.__stats = one; }); true')
    return s.until('counters', lambda: js(tab, 'window.__stats'), 5)


def flowing(tab, seconds=25):
    """Packets are still arriving: the connection is live, not merely open."""
    first = stats(tab)['audioPackets']
    s.until('audio packets keep arriving', lambda: stats(tab)['audioPackets'] > first + 50, seconds)


def row(tab):
    """The tab as `idle` lists it, parked or not. Nothing is put to sleep: an
    hour is longer than any tab has gone unlooked at."""
    return next(t for t in b('idle', '3600')['tabs'] if t['id'].lower().startswith(tab.lower()))


def live_devices(tab):
    """Capture tracks still live and not muted by WebKit. `enabled` is the page's
    own switch (a microphone button) and is checked where the page flips it."""
    return js(tab, "[...document.querySelector('#self').srcObject.getTracks()]"
                   ".every(t => t.readyState === 'live' && !t.muted)")


def press(tab, button):
    """One of the floating window's buttons, by the callback it presses. The
    media player's own `action` waits on a source that a hang-up removes."""
    b('media', tab, json.dumps({'action': button}))


def watching(tab):
    """Other people's pictures are decoding and playing again. After a page has
    been hidden they resume a beat after its audio, and a meeting is floated only
    once there is a picture of someone to show. A page that is not on screen
    decodes nothing, by design, so it is not waited for."""
    if js(tab, 'document.visibilityState') != 'visible':
        return
    s.until('remote video playing', lambda: js(tab, """[...document.querySelectorAll('video')].filter(v =>
        !v.paused && v.readyState >= 2 && v.srcObject &&
        v.srcObject.getVideoTracks().some(t => t.label === 'remote video')).length >= 2"""), 20)
