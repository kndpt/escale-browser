#!/usr/bin/env python3
"""Held real downloads: count, known/unknown progress and terminal cleanup.

Transfers survive tab closure and Space parking; completion reaches the original
history. Space deletion cancels outstanding downloads without leaving observers.
After a restart, the Downloads panel by real key presses: ↑ and ↓ within the
list, Return opens a file and ⌘Return shows it in the Finder (a scripted world
notes both rather than hand the file to another app), ⌫ forgets the line and
leaves the file, Escape closes.
INSPECT=1 pauses with two transfers, then after completion, for native button
and popover/cancel/history checks;
write /tmp/escale-download-resume to continue, context is in /tmp/escale-download-world.json.
"""
import json
import os
from pathlib import Path
from http.server import ThreadingHTTPServer
from threading import Event, Thread
import suite as s

releases = {name: Event() for name in ('one', 'two', 'unknown', 'fail', 'cancel')}
body = b'escale fixture\n' * 65536
DOWN, UP, RETURN, DELETE, ESCAPE = ('125', '\uf701'), ('126', '\uf700'), ('36', '\r'), ('51', '\x7f'), ('53', '\x1b')


class Page(s.Page):
    def do_GET(self):
        name = self.path.strip('/')
        if name not in releases:
            return super().do_GET()
        self.send_response(200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Disposition', f'attachment; filename="{name}.bin"')
        if name != 'unknown':
            self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        portion = len(body) // (4 if name != 'two' else 2)
        try:
            self.wfile.write(body[:portion]); self.wfile.flush()
            releases[name].wait(900)
            if name != 'fail':
                self.wfile.write(body[portion:]); self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True


def bench(*args):
    return json.loads(s.command(str(s.ROOT / 'bench'), '--world', s.WORLD, '--json', *args))


def state():
    return bench('probe')


def count(n):
    s.until(f'{n} active transfers', lambda: state()['activeDownloads'] == n, 15)
    p = state()
    s.require('one subscription per transfer', p['downloadObservers'], n)
    s.require('one visible row per transfer', len(p['transfers']), n)


def start(base, name):
    bench('bookmark', base + '/home-' + name, 'new')
    tab = next(t for t in s.tabs() if t['active'])
    bench('wait', tab['id'], '10')
    bench('eval', tab['id'], f"document.body.innerHTML='<a id=download href=/{name} download>Download</a>'; 'ready'")
    bench('tap', tab['id'], '#download')
    s.until(name + ' transfer', lambda: any(t['name'] == name + '.bin' for t in state()['transfers']), 15)
    return tab['id']


def keyboard():
    kept = state()['keptDownloads']
    s.require('at least three kept files', len(kept) >= 3, True)
    bench('ui', 'downloads', 'on')
    s.until('Downloads open', lambda: state()['downloads'], 10)
    # Nothing chosen, then the top, held there, then the second.
    for key in (UP, UP, DOWN):
        bench('press', *key)
    bench('press', *RETURN)
    bench('press', *RETURN, 'cmd')
    s.require('Return opens, ⌘Return shows', state()['handedDownloads'], [f'open {kept[1]}', f'show {kept[1]}'])
    file = s.SOCKET.parent / 'Downloads' / kept[1]
    s.require('file on disk', file.exists(), True)
    bench('press', *DELETE)
    s.require('⌫ forgets the line', state()['keptDownloads'], kept[:1] + kept[2:])
    s.require('⌫ leaves the file', file.exists(), True)
    bench('press', *RETURN)
    s.require('the next line is chosen', state()['handedDownloads'][-1], f'open {kept[2]}')
    bench('press', *ESCAPE)
    s.until('Escape closes Downloads', lambda: not state()['downloads'], 10)


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Page)
    Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    try:
        s.command(str(s.ROOT / 'fresh.sh'), 'wipe')
        s.command('defaults', 'write', s.SUITE, 'bench', '-bool', 'YES')
        s.launch(); bench('ui', 'welcome', 'off'); bench('ui', 'spaces', 'on')
        bench('resize', '1100', '760')
        bench('field', base + '/home', 'go')
        count(0)
        s.require('no session download yet', state()['downloadDoorVisible'], False)
        first = start(base, 'one'); count(1)
        s.require('first transfer reveals door', state()['downloadDoorVisible'], True)
        s.until('quarter progress', lambda: abs((state()['downloadFraction'] or 0) - .25) < .03, 15)
        second = start(base, 'two'); count(2)
        # Socket buffering can hold some sent bytes; compare the actual
        # observed fractions rather than assuming WebKit has received them.
        s.until('both known transfers progress', lambda: all((t['fraction'] or 0) > 0 for t in state()['transfers']), 15)
        progress = state()
        expected = sum(t['fraction'] for t in progress['transfers']) / 2
        assert abs(progress['downloadFraction'] - expected) < .0001, progress
        origin = state()['transfers'][0]['space']
        bench('press', '13', 'w', 'cmd')
        count(2)
        bench('space', 'new', 'Downloads elsewhere')
        count(2)
        assert all(t['space'] == origin for t in state()['transfers'])
        releases['one'].set(); count(1)
        s.require('other Space has no completed file', state()['keptDownloads'], [])
        releases['two'].set(); count(0)
        s.require('completion retains session door across Spaces', state()['downloadDoorVisible'], True)
        s.require('completion removes progress', state()['downloadFraction'], None)
        bench('space', 'go', '1')
        s.require('files kept in originating Space', sorted(state()['keptDownloads']), ['one.bin', 'two.bin'])
        start(base, 'fail'); count(1)
        releases['fail'].set(); count(0)
        assert 'fail.bin' not in state()['keptDownloads']
        s.require('failure retains door', state()['downloadDoorVisible'], True)
        start(base, 'unknown'); count(1)
        s.require('unknown total', state()['downloadFraction'], None)
        start(base, 'cancel'); count(2)
        s.require('mixed total remains unknown', state()['downloadFraction'], None)
        if os.environ.get('INSPECT'):
            Path('/tmp/escale-download-world.json').write_text(json.dumps({'world': s.WORLD, 'binary': s.BINARY, 'base': base}))
            Path('/tmp/escale-download-resume').unlink(missing_ok=True)
            print('ready for UI review: /tmp/escale-download-world.json', flush=True)
            s.until('manual review complete', lambda: Path('/tmp/escale-download-resume').exists(), 900)
        releases['unknown'].set()
        s.until('unknown finishes', lambda: not any(t['name'] == 'unknown.bin' for t in state()['transfers']), 15)
        bench('space', 'go', '2')
        # A second held transfer in a disposable Space exercises explicit cancel.
        start(base, 'cancel')
        bench('space', 'delete')
        s.until('deleted Space transfer removed', lambda: all(t['space'] == origin for t in state()['transfers']), 15)
        releases['cancel'].set(); count(0)
        assert 'unknown.bin' in state()['keptDownloads']
        s.require('cancellation retains door', state()['downloadDoorVisible'], True)
        if os.environ.get('INSPECT'):
            Path('/tmp/escale-download-resume').unlink(missing_ok=True)
            print('completed downloads ready for UI review', flush=True)
            s.until('completed review complete', lambda: Path('/tmp/escale-download-resume').exists(), 900)
        bench('press', '12', 'q', 'cmd')
        s.until('quit before restart', lambda: not s.running(), 10)
        s.launch()
        s.require('restart hides session door', state()['downloadDoorVisible'], False)
        assert 'unknown.bin' in state()['keptDownloads']
        keyboard()
        print('ok: keyboard in the Downloads panel')
        print('ok: active count, equal mean, unknown/mixed total, parked/closed source, completion, failure, cancellation, observer teardown')
    except Exception:
        print(state(), flush=True)
        raise
    finally:
        for event in releases.values(): event.set()
        s.command(str(s.ROOT / 'fresh.sh'), 'wipe')
        server.shutdown(); server.server_close()


if __name__ == '__main__':
    main()
