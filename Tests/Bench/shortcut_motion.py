#!/usr/bin/env python3
"""Shortcut pace, through real queued keys and real tab clicks.

A unique shared-runner world contains five loopback pages. Sample row frames
between keys 65 ms apart, check final selection/slots, new-tab cancellation,
close, both layouts, pointer selection, default and persisted opt-out. Optional
--record DIR retains window videos for pixel-level inspection of the
selection plate, comparing enabled and disabled on the same build. Frame
geometry alone does not prove the plate's rendered position or physical scanout.

The press request's settle=0 returns after posting the event, rather than the
usual 400 ms: a burst must not wait for each animation to finish.
"""
import argparse
import json
from pathlib import Path
import socket
import subprocess
import time
from http.server import ThreadingHTTPServer
from threading import Thread
import suite as h


def ask(verb, **fields):
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(15)
        client.connect(str(h.SOCKET))
        client.sendall((json.dumps(dict(fields, do=verb)) + '\n').encode())
        chunks = []
        while True:
            data = client.recv(65536)
            if not data:
                break
            chunks.append(data)
        result = json.loads(b''.join(chunks))
        if 'error' in result:
            raise AssertionError(result)
        return result


def active():
    return next(tab['id'] for tab in h.tabs() if tab['active'])


def press(code, chars, mods):
    return ask('press', code=code, chars=chars, mods=mods, settle=0)


def frames():
    return ask('panels')['entries']


def capture(folder, name):
    if folder is None:
        return None
    window = next(w['number'] for w in ask('probe')['windows'] if w['title'] == 'Escale' and w['visible'])
    destination = folder / (name + '.mov')
    destination.unlink(missing_ok=True)
    return subprocess.Popen(['screencapture', '-x', '-v', '-V', '5', '-l', str(window), str(destination)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def run(record=None):
    server = ThreadingHTTPServer(('127.0.0.1', 0), h.Page)
    Thread(target=server.serve_forever, daemon=True).start()
    evidence = []
    with h.world(server):
        h.command("defaults", "write", h.SUITE, "settings.page", "-string", "appearance")
        h.launch()
        h.require('default enabled', ask('probe')['fasterShortcuts'], True)
        ask('ui', look='light', depth='solid')
        ask('resize', width=1180, height=780)
        ids = [h.open_ordinary(f'http://127.0.0.1:{server.server_port}/motion-{i}') for i in range(5)]
        for sidebar in (False, True):
            ask('ui', sidebar=sidebar)
            for enabled in (False, True):
                ask('ui', fasterShortcuts=enabled)
                ask('select', id=ids[0])
                time.sleep(.7)
                before = frames()
                for ident in ids:
                    h.require('every tab has a sampled row',
                              any(e['id'].lower().startswith(ident.lower()) for e in before), True)
                video = capture(record, f'{"side" if sidebar else "strip"}-{enabled}')
                try:
                    time.sleep(1.3 if video else .1)
                    # One isolated step, then three steps faster than the old spring.
                    press(30, ']', ['cmd', 'shift'])
                    h.until('next tab selected', lambda: active() == ids[1])
                    h.require('keyboard origin captured at selection', ask('probe')['selectionFromKeyboard'], True)
                    time.sleep(1)
                    start = time.monotonic()
                    samples = []
                    for n in range(3):
                        press(30, ']', ['cmd', 'shift'])
                        deadline = start + (n + 1) * .065
                        while time.monotonic() < deadline:
                            samples.append({'time': time.monotonic() - start, 'frames': frames()})
                            time.sleep(.008)
                    h.until('burst landed on last tab', lambda: active() == ids[-1])
                    until = time.monotonic() + .6
                    while time.monotonic() < until:
                        samples.append({'time': time.monotonic() - start, 'frames': frames()})
                        time.sleep(.015)
                    after = frames()
                    expected = {e['id']: e['frame'] for e in before}
                    for sample in samples + [{'frames': after}]:
                        for entry in sample['frames']:
                            if entry['id'] in expected:
                                h.require('selection does not move tab slots',
                                          all(abs(a-b) < 1.5 for a,b in zip(entry['frame'], expected[entry['id']])), True)
                    evidence.append({'sidebar': sidebar, 'enabled': enabled, 'before': before, 'samples': samples, 'after': after})
                finally:
                    if video:
                        try:
                            _, error = video.communicate(timeout=10)
                            h.require('window recording: ' + error.decode(), video.returncode, 0)
                        except BaseException:
                            video.kill(); video.communicate()
                            raise
                # A real click after keyboard input must carry a new mouse origin.
                row = next(e['frame'] for e in after if e['id'].lower().startswith(ids[0].lower()))
                point = dict(x=row[0] + row[2]/2, y=row[1] + row[3]/2)
                ask('pointer', action='move', **point)
                ask('pointer', action='click', **point)
                h.until('pointer selected first tab', lambda: active() == ids[0])
                h.require('pointer does not retain keyboard origin', ask('probe')['selectionFromKeyboard'], False)
                press(17, 't', ['cmd'])
                h.until('new tab search opened', lambda: ask('probe')['openingTab'])
                press(53, '', [])
                h.until('new tab search cancelled', lambda: not ask('probe')['openingTab'])
                press(13, 'w', ['cmd'])
                h.until('ordinary tab closed', lambda: len(h.tabs()) == 4)
                press(17, 't', ['cmd', 'shift'])
                h.until('closed tab restored', lambda: len(h.tabs()) == 5)
                # Reopen creates a new identity. Keep the current actual order.
                ids = [tab['id'] for tab in h.tabs()]
        # The top strip must reveal a selection deferred to the next layout,
        # even when earlier selections in the burst are already obsolete.
        ask('ui', sidebar=False)
        ask('resize', width=640, height=650)
        for code, char, chosen in ((18, '1', ids[0]), (25, '9', ids[-1])):
            press(code, char, ['cmd'])
            h.until('number shortcut selected tab', lambda: active() == chosen)
            def revealed():
                row = next(e['frame'] for e in frames() if e['id'].lower().startswith(chosen.lower()))
                return row[0] >= 0 and row[0] + row[2] <= 640
            h.until('overflow selection revealed', revealed)
        press(1, 's', ['cmd', 'shift'])
        h.until('keyboard switched to sidebar', lambda: len({round(e['frame'][1]) for e in frames()}) == 5)
        press(1, 's', ['cmd', 'shift'])
        h.until('keyboard switched to strip', lambda: len({round(e['frame'][1]) for e in frames()}) == 1)
        if record:
            ask('ui', settings=True)
            ask('resize', width=900, height=650)
            for look in ('light', 'dark'):
                ask('ui', look=look)
                time.sleep(.6)
                window = next(w['number'] for w in ask('probe')['windows'] if w['title'] == 'Escale' and w['visible'])
                h.command('screencapture', '-x', '-o', '-l', str(window), str(record / ('settings-' + look + '.png')))
            ask('ui', settings=False)
        ask('ui', fasterShortcuts=False)
        h.command(str(h.ROOT / 'bench'), '--world', h.WORLD, 'press', '12', 'q', 'cmd')
        h.until('app quit', lambda: not h.running())
        h.launch()
        h.require('opt-out survives restart', ask('probe')['fasterShortcuts'], False)
        ask('ui', fasterShortcuts=True)
        h.command(str(h.ROOT / 'bench'), '--world', h.WORLD, 'press', '12', 'q', 'cmd')
        h.until('app quit again', lambda: not h.running())
        h.launch()
        h.require('opt-in survives restart', ask('probe')['fasterShortcuts'], True)
        output = record or h.ROOT / 'build' / 'shortcut-motion'
        output.mkdir(parents=True, exist_ok=True)
        (output / 'frames.json').write_text(json.dumps(evidence))
        print('PASS: shortcut burst, stable row frames, pointer origin, create/cancel/close/reopen, both layouts and stored preference')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--record', type=Path)
    args = parser.parse_args()
    if args.record:
        args.record.mkdir(parents=True, exist_ok=True)
    run(args.record)
