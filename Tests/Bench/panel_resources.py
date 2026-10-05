#!/usr/bin/env python3
"""Physical footprint and event-to-run-loop-rest samples for three local pages.

Use an optimized app and hold the desktop lock throughout. --baseline records
the same loaded-page/idle workload on a pre-feature checkout. Candidate-only
interaction samples compare an invalid drop, a valid preview/drop, and divider
drags; they are responsiveness proxies, never physical frame latency or energy.

`cost` adds the CPU time and wakeups the app and its WebKit helpers spend over
one series, read from the kernel's own counters (ps rounds to 10 ms). The
per-page hover band and the carried tab are isolated by pairing series that
differ in one thing: the same pointer sweep with and without a displayed group,
and the same held drag with and without the pages under it. A cost is work done
during the series, bench traffic included; it is not energy.
"""
from argparse import ArgumentParser
from datetime import datetime, timedelta, timezone
from pathlib import Path
from http.server import ThreadingHTTPServer
from threading import Thread
import ctypes
import hashlib
import json
import os
import socket
import subprocess
import time
import uuid
import resource_baseline as r
import suite as s


class Timebase(ctypes.Structure):
    _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]


def nanoseconds_per_tick():
    base = Timebase()
    ctypes.CDLL('/usr/lib/libSystem.dylib').mach_timebase_info(ctypes.byref(base))
    return base.numer / base.denom


def spent(app, helpers):
    """Per process, its part ('app' or 'webkit') with CPU milliseconds and wakeups."""
    tick = nanoseconds_per_tick() / 1e6
    out = {}
    for part, pids in (('app', [app]), ('webkit', helpers)):
        for pid in pids:
            usage = r.Usage()
            if r.LIBPROC.proc_pid_rusage(pid, 0, ctypes.byref(usage)) != 0: continue
            out[pid] = dict(part=part, cpu_ms=(usage.user + usage.system) * tick,
                            interrupt=usage.interrupt_wakeups, package_idle=usage.package_idle_wakeups)
    return out


def difference(begin, end):
    """What the processes alive at both readings spent between them.

    A helper that retires mid-series would otherwise leave its counters in the
    first reading only and make the series negative."""
    total = {part: dict(cpu_ms=0.0, interrupt=0, package_idle=0) for part in ('app', 'webkit')}
    for pid in begin.keys() & end.keys():
        for key in total[end[pid]['part']]:
            total[end[pid]['part']][key] += end[pid][key] - begin[pid][key]
    return dict(total, retired=len(begin.keys() - end.keys()))


def main():
    parser = ArgumentParser()
    parser.add_argument('--root', type=Path, default=s.ROOT)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--baseline', action='store_true')
    parser.add_argument('--without-gestures', action='store_true', help='measure memory, typing and idle only; gesture latency remains unqualified')
    parser.add_argument('--revision', help='source revision for an exported baseline tree')
    parser.add_argument('--skip-idle', action='store_true', help='leave out the 120-second idle interval, for a short drag-latency run')
    args = parser.parse_args(); root = args.root.resolve()
    world = 'panels-' + uuid.uuid4().hex[:16]
    r.ROOT = root; r.WORLD = world
    env = dict(os.environ, ESCALE_PROBE=world, ESCALE_MEASURE='1')
    socket_path = Path.home() / 'Library/Application Support' / f'Escale ({world})' / 'bench.sock'
    def run(*cmd):
        return subprocess.run(cmd, cwd=root, env=env, text=True, capture_output=True, check=True, timeout=60).stdout
    def ask(verb, **fields):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(35); connection.connect(str(socket_path))
            connection.sendall((json.dumps(dict(do=verb, **fields)) + '\n').encode())
            data = b''
            while b'\n' not in data:
                chunk = connection.recv(65536)
                if not chunk: break
                data += chunk
        assert data, f'the app closed the bench socket without answering {verb} {fields} (app alive: {r.app_pid()})'
        result = json.loads(data.split(b'\n')[0]); assert 'error' not in result, result
        return result
    server = ThreadingHTTPServer(('127.0.0.1', 0), s.Page)
    Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    before = set(r.webkit_processes()); samples = []
    record = dict(revision=args.revision or run('git', 'rev-parse', 'HEAD').strip(), baseline=args.baseline,
                  completed=False, gestures=not args.without_gestures and not args.baseline, recorded=datetime.now(timezone.utc).isoformat(),
                  binary_sha256=hashlib.sha256((root / 'build/Escale.app/Contents/MacOS/Escale').read_bytes()).hexdigest(),
                  build='release', os=r.run('sw_vers'), swift=r.run('swift', '--version'),
                  hardware=r.run('sysctl', '-n', 'hw.model', 'hw.memsize', 'machdep.cpu.brand_string'),
                  power=r.run('pmset', '-g', 'batt'), window=[1180, 780],
                  display=r.run('system_profiler', 'SPDisplaysDataType'),
                  workload='three ordinary loopback static pages; foreground; no extensions; fresh world; 3 footprint samples per state; 120-second idle without bench traffic',
                  samples=samples, latency={}, cost={})
    try:
        run('./fresh.sh', 'wipe')
        run('defaults', 'write', f'com.kndpt.escale.test.{world}', 'bench', '-bool', 'YES')
        run('defaults', 'write', f'com.kndpt.escale.test.{world}', 'welcomed', '-bool', 'YES')
        checked = (datetime.now(timezone.utc) + timedelta(days=1)).strftime('%Y-%m-%d %H:%M:%S +0000')
        run('defaults', 'write', f'com.kndpt.escale.test.{world}', 'update.checked', '-date', checked)
        run('./fresh.sh', 'again')
        s.until('socket', socket_path.exists, 30)
        ask('ui', welcome=False, sidebar=True, bar=True, look='light', size='standard')
        ask('resize', width=1180, height=780)
        ids = []
        for name in ('alpha', 'bravo', 'charlie'):
            ask('bookmark', url=base + '/' + name, new=True)
            id = next(t['id'] for t in ask('tabs')['tabs'] if t['active']); ids.append(id)
            loaded = ask('wait', id=id, seconds=10)
            assert not loaded['loading'] and not loaded.get('failure') and not loaded.get('timeout'), loaded
        a, b, c = ids
        ask('select', id=a)
        cohort = set(r.webkit_processes()) - before
        def sample(stage):
            # A helper WebKit retires between the listing and its footprint now and
            # then; list again rather than lose a long run to the race.
            for attempt in range(3):
                cohort.update(set(r.webkit_processes()) - before)
                cohort.intersection_update(r.all_processes())
                try:
                    samples.append(dict(stage=stage, **r.sample_memory(cohort))); return
                except RuntimeError:
                    if attempt == 2: raise
                    time.sleep(1)
        def settled():
            previous = None; identical = 0
            def stable():
                nonlocal previous, identical
                state = ask('panels')
                current = [(p['id'], p.get('frame')) for p in state['pages']] + [(e['id'], e['frame']) for e in state['entries']]
                identical = identical + 1 if current == previous else 0
                previous = current
                return identical >= 3
            s.until('native geometry before resource gesture', stable, 5)

        def cost(stage, work, repeats=3):
            """CPU and wakeups spent by `work`, `repeats` times, one entry each."""
            entries = []
            for _ in range(repeats):
                cohort.update(set(r.webkit_processes()) - before)
                begin = spent(r.app_pid(), sorted(cohort)); started = time.monotonic()
                work()
                seconds = time.monotonic() - started; end = spent(r.app_pid(), sorted(cohort))
                entries.append(dict(seconds=seconds, **difference(begin, end)))
            record['cost'][stage] = entries

        def sweep(line):
            """A hand moving over the pages: `line` gives each pointer position."""
            for x, y in line: ask('pointer', action='move', x=x, y=y)

        def across(frame, down, moves=120):
            # Out along the line and back, so the pointer keeps crossing the pages.
            x0, y0, w, h = frame; y = y0 + down
            return [(x0 + 20 + (w - 40) * (1 - abs(2 * i / moves - 1)), y) for i in range(moves)]

        def toggling(frame, moves=60):
            # Between the page's middle and its top band, at one column of the first page.
            x0, y0, w, h = frame; x = x0 + w / 6
            return [(x, y0 + (h / 2 if i % 2 == 0 else 20)) for i in range(moves)]

        def typing(stage):
            ask('select', id=a)
            timings = []
            for _ in range(8):
                result = ask('field', text='panel comparison', type=True)
                timings.extend(pair[1] for pair in result['ms'])
                ask('press', code=53, chars='\x1b')
            record['latency'][stage] = timings
        for _ in range(3): sample('ungrouped')
        # The existing collector is identical on both revisions. Each block
        # retains 128 keystrokes over eight address-field openings, including
        # the first, rather than inventing a baseline for a new split gesture.
        typing('typing-ungrouped')
        if not args.baseline and not args.without_gestures:
            ask('pointer', action='move', x=600, y=400)
            settled(); area = ask('panels')['frame']
            cost('still', lambda: time.sleep(8))
            cost('hover-interior-ungrouped', lambda: sweep(across(area, area[3] / 2)))
            cost('hover-band-ungrouped', lambda: sweep(across(area, 20)))
            cost('hover-toggle-ungrouped', lambda: sweep(toggling(area)))
        # A row dragged within the column exists on both revisions: the same
        # stage on each separates what any drag costs from what a composition
        # adds. Standard layout, 1180 x 780, three rows of 34 points; the first
        # drag takes the middle row one place down, the next brings it back.
        timings = []
        ask('select', id=a)
        # --without-gestures keeps its promise: no drag is sent at all.
        for index in range(0 if args.without_gestures else 16):
            start, end = (222, 256) if index % 2 == 0 else (256, 222)
            result = ask('drag', x=108, y=start, toX=108, toY=end, live=True)
            timings.extend(result.get('inputMS', []))
        # A base older than the timing (8ff3e0a) drags but does not time it.
        if timings: record['latency']['reorder'] = timings
        if not args.baseline:
            if not args.without_gestures:
                # Held for the same 500 ms in every kind, so a cost compares like with
                # like: a row moved within the column never reaches the pages (no carried
                # tab), the centre is refused (carried tab, no landing shape), the edge
                # shows both.
                for mode in ('reorder-held', 'invalid', 'preview'):
                    timings = []
                    def drags(count=8):
                        for index in range(count):
                            ask('select', id=a)
                            settled()
                            state = ask('panels')
                            source = next(e['frame'] for e in state['entries'] if e['id'].lower().startswith(b))
                            x, y, w, h = state['frame']
                            # A hand reaches the row before it presses (see panels.py).
                            ask('pointer', action='move', x=source[0] + 40, y=source[1] + source[3] / 2)
                            if mode == 'reorder-held':
                                result = ask('drag', x=source[0] + 40, y=source[1] + source[3] / 2,
                                             toX=source[0] + 40, toY=source[1] + source[3] * (1.5 if index % 2 == 0 else -0.5), live=True, holdMS=500)
                                continue
                            result = ask('drag', x=source[0] + 40, y=source[1] + source[3] / 2,
                                         toX=x + (w / 2 if mode == 'invalid' else w - 12), toY=y + h / 2, live=True, holdMS=500)
                            timings.extend(result['inputMS'])
                            if mode == 'preview':
                                assert result['heldPanels']['preview'] == 'right', result
                                ask('panels', action='separate', id=a)
                    if mode == 'reorder-held':
                        # Not a latency series; only the cost of holding a row in the column.
                        cost('drag-reorder-held', lambda: drags(8), repeats=1)
                        ask('select', id=a)
                    else:
                        cost('drag-' + mode, lambda: drags(8), repeats=1)
                        record['latency'][mode] = timings
            assert ask('panels', action='add', id=b, target=a, edge='right')['accepted']
            assert ask('panels', action='add', id=c, target=a, edge='right')['accepted']
            for _ in range(3): sample('three-panels')
            typing('typing-three-panels')
            if not args.without_gestures:
                settled()
                ask('pointer', action='move', x=600, y=400)
                area = ask('panels')['frame']
                cost('hover-interior-three-panels', lambda: sweep(across(area, area[3] / 2)))
                cost('hover-band-three-panels', lambda: sweep(across(area, 20)))
                cost('hover-toggle-three-panels', lambda: sweep(toggling(area)))
                settled()
                timings = []
                for index in range(8):
                    page = next(p for p in ask('panels')['pages'] if p['id'].lower().startswith(a))['frame']
                    x = page[0] + page[2] + 3; y = page[1] + page[3] / 2
                    ask('pointer', action='move', x=x, y=y)
                    result = ask('drag', x=x, y=y, toX=x + (30 if index % 2 == 0 else -30), toY=y, live=True)
                    timings.extend(result['inputMS'])
                record['latency']['divider'] = timings
            ask('panels', action='separate', id=a)
            for _ in range(3): sample('separated')
            typing('typing-separated')
            teardown = ask('panels')
            assert not teardown['groups'] and not teardown['focusWatching'], teardown
            record['teardown'] = dict(groups=len(teardown['groups']), focusWatching=teardown['focusWatching'])
        if args.skip_idle:
            # Said in the record itself: this run is a short one, not the full workload.
            record['idle_skipped'] = True
            record['workload'] = record['workload'].replace('; 120-second idle without bench traffic', '; idle interval skipped (--skip-idle)')
            record['completed'] = True
            return
        ids = [r.app_pid(), *cohort]
        cpu = {pid: r.cpu_seconds(pid) for pid in ids if pid in r.all_processes()}
        wakeups = {pid: r.wakeups(pid) for pid in cpu}
        started = time.monotonic(); print('120-second quiet idle', flush=True)
        time.sleep(120)
        elapsed = time.monotonic() - started
        record['idle_seconds'] = elapsed
        record['idle_cpu_percent'] = {str(pid): (r.cpu_seconds(pid) - value) * 100 / elapsed for pid, value in cpu.items() if pid in r.all_processes()}
        record['idle_wakeups'] = {str(pid): {key: r.wakeups(pid)[key] - value for key, value in values.items()} for pid, values in wakeups.items() if pid in r.all_processes()}
        sample('after-idle')
        record['completed'] = True
    finally:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(record, indent=2))
        run('./fresh.sh', 'wipe'); server.shutdown(); server.server_close()
    print(args.output)


if __name__ == '__main__':
    main()
