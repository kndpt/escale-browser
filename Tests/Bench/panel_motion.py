#!/usr/bin/env python3
"""Record split interactions under the actual macOS motion preference.

Functional assertions reuse the established pointer journeys; window videos
retain the rendered transitions for visual review, which model state cannot
prove. The runner owns one disposable world and synthetic loopback pages.
No system setting is written. Recording is bounded per clip and is not a
latency measurement: screen capture adds work to the interaction.
"""
from argparse import ArgumentParser
from http.server import ThreadingHTTPServer
from pathlib import Path
from threading import Thread
import json
import subprocess
import time
import panel_tools as tools
import panels
import suite as s


def run(folder, reduced):
    folder.mkdir(parents=True, exist_ok=False)
    evidence = dict(expectedReducedMotion=reduced, observedReducedMotion=None, clips=[], completed=False)
    server = ThreadingHTTPServer(('127.0.0.1', 0), s.Page)
    Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'

    def check_motion():
        # Keep the observation even when a mismatch aborts before any clip.
        evidence['observedReducedMotion'] = tools.bench('probe')['reduceMotion']
        s.require('actual macOS Reduce Motion setting', evidence['observedReducedMotion'], reduced)

    def clip(name, action, seconds=6):
        check_motion()
        probe = tools.bench('probe')
        window = next(w['number'] for w in probe['windows'] if w['title'] == 'Escale' and w['visible'])
        movie = folder / (name + '.mov')
        entry = dict(name=name, before=tools.state(), probe=probe, movie=str(movie))
        evidence['clips'].append(entry)
        process = subprocess.Popen(['screencapture', '-x', '-v', '-V', str(seconds), '-l', str(window), str(movie)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            # Retain a still lead-in before posting input, as in shortcut_motion.
            time.sleep(1.3)
            result = action()
            output, error = process.communicate(timeout=seconds + 10)
            s.require('window recording: ' + error.decode(), process.returncode, 0)
            assert movie.is_file() and movie.stat().st_size > 0, movie
            check_motion()
            entry['after'] = tools.state()
            return result
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill(); process.communicate(timeout=5)

    try:
        with s.world(server):
            s.launch()
            check_motion()
            tools.bench('ui', 'welcome', 'off'); tools.bench('ui', 'spaces', 'on')
            tools.bench('resize', 1180, 780)
            for layout in ('sidebar', 'strip'):
                tools.bench('ui', 'sidebar', 'on' if layout == 'sidebar' else 'off')
                for look in ('light', 'dark'):
                    name = f'{layout}-{look}'
                    print('motion:', name, flush=True)
                    tools.bench('ui', 'look', look)
                    tools.settled()
                    a, b, c = tools.assemble(base, name)
                    identities = {p['id']: p['page'] for p in tools.state()['pages'] if p['id'] in (a, b, c)}
                    clip(name + '-reveal', lambda: tools.reveal(b))
                    clip(name + '-swap', lambda: tools.press(b, 0))
                    s.require('native swap', tools.state()['groups'][0]['members'], [a, c, b])
                    tools.settled()
                    clip(name + '-turn', lambda: tools.press(a, 1))
                    s.require('native orientation', tools.state()['groups'][0]['horizontal'], False)
                    tools.settled()
                    tools.press(a, 1); tools.settled()
                    s.require('page identity after native commands',
                              {p['id']: p['page'] for p in tools.state()['pages'] if p['id'] in identities}, identities)
                    first = tools.page(a)['frame']
                    x = first[0] + first[2] + 3; y = first[1] + first[3] / 2
                    weights = tools.state()['groups'][0]['weights']
                    tools.bench('pointer', 'move', x, y)
                    clip(name + '-divider', lambda: tools.bench('drag', x, y, x + 60, y, 'live'))
                    assert tools.state()['groups'][0]['weights'] != weights, tools.state()
                    tools.settled()
                    clip(name + '-window', lambda: tools.bench('resize', 950, 650))
                    tools.bench('resize', 1180, 780); tools.settled()
                    clip(name + '-move-out', lambda: tools.press(b, 2))
                    s.require('native move out', tools.state()['groups'][0]['members'], [a, c])
                    tools.settled()
                    clip(name + '-close', lambda: tools.press(c, 3))
                    assert not tools.state()['groups'], tools.state()
                    assert not any(t['id'].startswith(c) for t in tools.bench('tabs')['tabs'])
                    for edge in ('left', 'right', 'top', 'bottom'):
                        tools.bench('select', a); tools.settled()
                        result = clip(name + '-' + edge, lambda: panels.drag(b, edge, name + '-' + edge))
                        s.require('held landing', result['heldPanels']['preview'], edge)
                        assert result['heldPanels']['lifted'], result
                        members = [b, a] if edge in ('left', 'top') else [a, b]
                        s.require('drop composition', tools.state()['groups'][0]['members'], members)
                        tools.bench('panels', 'separate', b)
                        s.until('focus observation ends after separation', lambda: not tools.state()['focusWatching'])
                    for id in (a, b):
                        tools.bench('panels', 'close', id)
            check_motion()
        evidence['completed'] = True
        print('ok: native capsule, four landing previews/drops, divider and window resize; inspect the window videos for motion')
    finally:
        (folder / 'evidence.json').write_text(json.dumps(evidence, indent=2))


if __name__ == '__main__':
    parser = ArgumentParser(description=__doc__)
    parser.add_argument('--record', type=Path, required=True, help='new directory for window videos and states')
    parser.add_argument('--expect-reduced-motion', choices=('on', 'off'), default='on',
                        help='require the actual macOS setting; off records a normal-motion reference')
    args = parser.parse_args()
    run(args.record.resolve(), args.expect_reduced_motion == 'on')
