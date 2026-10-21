#!/usr/bin/env python3
"""A download cut mid-transfer stays as a row, and Resume or Retry finishes it.

A loopback server sends half a file, then drops the connection. With an ETag
and byte ranges, WebKit leaves resume data: the row offers Resume, which asks
only for the rest. Without them, it offers Retry, which asks for the whole
file again. Both are pressed through the popover's own buttons, from another
Space, and must give a file identical to the one served, in the folder the
cut transfer was writing to, kept in the history of the Space it came from.
Retry trashes the half file it left, but not a file put at its path since.
A transfer cancelled by hand leaves no row. Rows stop at eight, the oldest
let go; Remove takes one away; none survives a relaunch.
Not covered: a Space deleted while a resumed transfer starts, the save panel,
a private tab's download (its store is matched by DownloadsTests).
"""
import hashlib
import json
import re
from pathlib import Path
from http.server import ThreadingHTTPServer
from threading import Event, Thread
import suite as s

body = bytes(range(256)) * 4096  # 1 MiB
served = {}  # name → Range headers asked, in order
held = Event()


class Page(s.Page):
    def do_GET(self):
        name = self.path.strip('/')
        kind = name.split('-')[0]
        if kind not in ('resume', 'retry', 'cut', 'cancel'):
            return super().do_GET()
        asked = self.headers.get('Range')
        served.setdefault(name, []).append(asked)
        start = int(re.fullmatch(r'bytes=(\d+)-', asked).group(1)) if asked and kind == 'resume' else 0
        self.send_response(206 if start else 200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Disposition', f'attachment; filename="{name}.bin"')
        self.send_header('Content-Length', str(len(body) - start))
        if kind == 'resume':
            self.send_header('Accept-Ranges', 'bytes')
            self.send_header('ETag', '"escale-fixture"')
            self.send_header('Last-Modified', 'Mon, 05 Oct 2026 10:00:00 GMT')
            if start:
                self.send_header('Content-Range', f'bytes {start}-{len(body) - 1}/{len(body)}')
        self.end_headers()
        first = len(served[name]) == 1
        try:
            if kind == 'cancel':
                self.wfile.write(body[:len(body) // 4]); self.wfile.flush()
                held.wait(60)
            elif first:
                # Half the file, then the connection drops as a network would.
                self.wfile.write(body[:len(body) // 2]); self.wfile.flush()
            else:
                self.wfile.write(body[start:]); self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True


def bench(*args):
    return json.loads(s.command(str(s.ROOT / 'bench'), '--world', s.WORLD, '--json', *args))


def state():
    return bench('probe')


def failed():
    return {f['name']: f for f in state()['failedDownloads']}


def start(base, name):
    bench('bookmark', base + '/home-' + name, 'new')
    tab = next(t for t in s.tabs() if t['active'])
    bench('wait', tab['id'], '10')
    bench('eval', tab['id'], f"document.body.innerHTML='<a id=download href=/{name} download>Download</a>'; 'ready'")
    bench('tap', tab['id'], '#download')


def press(label):
    s.until(label + ' button', lambda: bench('button', label)['pressed'], 10)


def cut(base, name, action):
    start(base, name)
    s.until(name + ' failed', lambda: name + '.bin' in failed(), 20)
    p = state()
    s.require(name + ': no active transfer', p['activeDownloads'], 0)
    s.require(name + ': no observer left', p['downloadObservers'], 0)
    s.require(name + ': the announcement names the file', p['announcement'], f'Couldn’t download {name}.bin')
    s.require(name + ': offered', failed()[name + '.bin']['action'], action)
    return failed()[name + '.bin']


def finished(name, row, saved=None):
    folder = Path(row['folder'])
    s.until(name + ' finished', lambda: state()['announcement'].startswith('Saved ' + name)
            and not state()['transfers'] and name + '.bin' not in failed(), 20)
    files = sorted(f.name for f in folder.iterdir() if f.name.startswith(name))
    print(name, 'leaves', files, flush=True)
    saved = saved or name + '.bin'
    s.require(name + ': where the cut one was going', saved in files, True)
    digest = hashlib.sha256((folder / saved).read_bytes()).hexdigest()
    return files
    s.require(name + ': identical file', digest, hashlib.sha256(body).hexdigest())


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Page)
    Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    with s.world(server):
        s.launch()
        bench('ui', 'spaces', 'on')
        bench('resize', '1100', '760')
        bench('field', base + '/home', 'go')

        resume = cut(base, 'resume', 'Resume')
        retry = cut(base, 'retry', 'Retry')
        s.require('both rows from the first Space', retry['space'], resume['space'])
        bench('space', 'new', 'Elsewhere')
        s.require('the rows follow to another Space', sorted(failed()), ['resume.bin', 'retry.bin'])

        press('Downloads')
        press('Resume resume.bin')
        s.require('resume: one file', finished('resume', resume), ['resume.bin'])
        s.require('Resume asks only for the rest', served['resume'], [None, f'bytes={len(body) // 2}-'])
        press('Retry retry.bin')
        s.require('retry: one file, the half one taken away', finished('retry', retry), ['retry.bin'])
        s.require('Retry asks for the whole file', served['retry'], [None, None])
        s.require('nothing kept in the Space on screen', state()['keptDownloads'], [])
        bench('space', 'go', '1')
        s.require('both kept in the Space they came from', sorted(state()['keptDownloads']), ['resume.bin', 'retry.bin'])

        # A file put where the half one was is someone else's: Retry leaves it.
        swap = cut(base, 'retry-swap', 'Retry')
        theirs = Path(swap['folder']) / 'retry-swap.bin'
        mine = theirs.with_name('.swap')
        mine.write_bytes(b'not the download')
        mine.replace(theirs)
        press('Downloads')
        press('Retry retry-swap.bin')
        files = finished('retry-swap', swap, 'retry-swap 2.bin')
        s.require('a replaced file stays', files, ['retry-swap 2.bin', 'retry-swap.bin'])
        s.require('a replaced file is untouched', theirs.read_bytes(), b'not the download')

        start(base, 'cancel')
        s.until('cancel transfer', lambda: state()['activeDownloads'] == 1, 15)
        press('Active Downloads')
        press('Cancel cancel.bin')
        s.until('cancelled', lambda: state()['activeDownloads'] == 0, 15)
        held.set()
        s.require('a cancel leaves no row', failed(), {})

        for n in range(9):
            cut(base, f'cut-{n}', 'Retry')
        rows = [f['name'] for f in state()['failedDownloads']]
        s.require('eight rows, the oldest let go', rows, [f'cut-{n}.bin' for n in range(1, 9)])
        press('Downloads')
        press('Remove cut-8.bin')
        s.require('Remove takes the row away', 'cut-8.bin' in failed(), False)
        s.require('Remove leaves no transfer', state()['activeDownloads'], 0)

        bench('press', '12', 'q', 'cmd')
        s.until('quit before restart', lambda: not s.running(), 10)
        s.launch()
        s.require('no row after a relaunch', state()['failedDownloads'], [])
        print('ok: cut transfer kept as a row; Resume asks the rest, Retry the whole; identical files, same folder and Space')
        print('ok: a file put where the half one was is left; cancel leaves no row; eight rows at most; Remove; nothing after relaunch')


if __name__ == '__main__':
    main()
