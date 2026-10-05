#!/usr/bin/env python3
"""Duration, memory and return to rest of saving and importing a representative Escale.

Use an optimized build (`ESCALE_SIGN_IDENTITY=- ./build.sh release`) and hold
the desktop throughout; never run a compiler or another benchmark meanwhile.
The source world is seeded with files the app reads at launch: four Spaces, each
with nested bookmarks (folders of 50), hundreds of tabs kept as addresses, a
full history, what Bearings learned and hidden elements, plus saved passwords
added through the app. It is saved three times, then the file is imported into a
fresh world. Reported: save and open and import durations; the app's physical
footprint before, right after and settled, with its own peak; WebKit processes
before and after (importing tabs must not start pages); CPU and wakeups over an
idle interval before and after. Footprints and CPU are proxies, not energy.
"""
from argparse import ArgumentParser
from datetime import datetime, timezone
from pathlib import Path
import json
import os
import statistics
import subprocess
import tempfile
import time
import uuid
import resource_baseline as r
import suite as s
import transfer as t

PHRASE = 'a synthetic passphrase'
SPACES = 4
BOOKMARKS = 1_500
TABS = 300
HISTORY = 2_000
HABITS = 150
PASSWORDS = 50
NOW = time.time() - 978_307_200 - 3600


def heavy(world, base):
    """A source with the state of a long-used Escale, written before launch."""
    ids = [t.FIRST] + [str(uuid.uuid4()).upper() for _ in range(SPACES - 1)]
    world.file('spaces.json').write_text(json.dumps([dict(id=i, name=f'Space {k}', colour=k % 6) for k, i in enumerate(ids)]))
    for k, space in enumerate(ids):
        suffix = '' if space == t.FIRST else f'-{space}'
        def leaf(n): return dict(id=str(uuid.uuid4()).upper(), title=f'Page {k}-{n}', url=f'{base}/s{k}/p{n}')
        folders = [dict(id=str(uuid.uuid4()).upper(), title=f'Folder {f}', children=[leaf(f * 50 + n) for n in range(50)])
                   for f in range(BOOKMARKS // 50)]
        world.file(f'bookmarks{suffix}.json').write_text(json.dumps(folders))
        tabs = [dict(url=f'{base}/s{k}/t{n}', title=f'Tab {n}') for n in range(TABS)]
        world.file(f'session{suffix}.json').write_text(json.dumps(dict(tabs=tabs, active=0)))
        visits = [dict(url=f'{base}/s{k}/h{n}', key=f'127.0.0.1/s{k}/h{n}', title=f'History {n}', count=n % 9 + 1, last=NOW) for n in range(HISTORY)]
        world.file(f'history{suffix}.json').write_text(json.dumps(visits))
        first = folders[0]['children'][0]['id']
        world.file(f'habits-{space}.json').write_text(json.dumps(
            [dict(query=f'query{n}', picks=[dict(to=f'page:127.0.0.1/s{k}/h{n}', count=1.5, last=NOW)]) for n in range(HABITS - 1)]
            + [dict(query='bookmark', picks=[dict(to='bookmark:' + first, count=2.0, last=NOW)])]))
        world.file(f'hidden{suffix}.json').write_text(json.dumps({f'site{n}.invalid': [dict(selector=f'.ad{n}', label='Ad', date=NOW)] for n in range(100)}))
    world.default('look', '-string', 'dark')
    return ids


def pids(world):
    binary = world.binary
    return [pid for pid, name in r.all_processes().items() if name == binary]


def footprint(world):
    r.WORLD = world.name
    return r.footprint(r.app_pid())


def idle(world, seconds):
    r.WORLD = world.name
    pid = r.app_pid()
    cpu, wake, started = r.cpu_seconds(pid), r.wakeups(pid), time.monotonic()
    time.sleep(seconds)
    elapsed = time.monotonic() - started
    after = r.wakeups(pid)
    return dict(seconds=round(elapsed, 1), cpu_percent=round((r.cpu_seconds(pid) - cpu) * 100 / elapsed, 3),
                wakeups={k: after[k] - wake[k] for k in after})


def main():
    parser = ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--idle', type=int, default=60)
    args = parser.parse_args()
    r.ROOT = s.ROOT
    os.environ['ESCALE_MEASURE'] = '1'
    from http.server import ThreadingHTTPServer
    from threading import Thread
    server = ThreadingHTTPServer(('127.0.0.1', 0), s.Page)
    Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    worlds = []
    scratch = Path(tempfile.mkdtemp(prefix='escale-transfer-'))
    record = dict(recorded=datetime.now(timezone.utc).isoformat(), completed=False,
                  revision=subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=s.ROOT, capture_output=True, text=True).stdout.strip(),
                  binary_sha256=__import__('hashlib').sha256((s.ROOT / 'build/Escale.app/Contents/MacOS/Escale').read_bytes()).hexdigest(),
                  os=r.run('sw_vers'), hardware=r.run('sysctl', '-n', 'hw.model', 'hw.memsize', 'machdep.cpu.brand_string'),
                  power=r.run('pmset', '-g', 'batt'),
                  workload=f'{SPACES} Spaces x ({BOOKMARKS} bookmarks in folders of 50, {TABS} tabs, {HISTORY} history places, '
                           f'{HABITS} learned queries, 100 hidden hosts), {PASSWORDS} passwords per Space; loopback; fresh destination',
                  save=[], open_seconds=None, import_seconds=None)
    try:
        source = t.World(); worlds.append(source); source.prepare()
        heavy(source, base)
        source.launch()
        for index in range(SPACES):
            source.bench('space', 'go', index + 1)
            for n in range(PASSWORDS):
                source.bench('space', 'credentials', f'user{n}')
        source.bench('space', 'go', 1)
        time.sleep(20)
        record['source_settled'] = footprint(source)
        record['source_idle'] = idle(source, args.idle)
        file = scratch / 'representative.escale'
        for _ in range(3):
            started = time.monotonic()
            source.transfer('save', file, PHRASE, 'passwords')
            s.until('saved', lambda: source.transfer('state')['saving'] == 'saved', 120)
            elapsed = time.monotonic() - started
            record['save'].append(dict(seconds=round(elapsed, 2), bytes=file.stat().st_size, footprint=footprint(source)))
            source.transfer('forget')
            time.sleep(1)
        record['source_after_saves_settled'] = footprint(source)
        time.sleep(10)
        record['source_after_saves_rest'] = footprint(source)

        destination = t.World(); worlds.append(destination); destination.prepare(); destination.launch()
        time.sleep(10)
        record['destination_before'] = dict(footprint=footprint(destination), webkit=len(r.webkit_processes()))
        record['destination_idle_before'] = idle(destination, args.idle)
        webkit_before = set(r.webkit_processes())
        started = time.monotonic()
        destination.transfer('choose', file); destination.until_state('locked', bringing='locked')
        destination.transfer('unlock', PHRASE); destination.until_state('summary', bringing='summary')
        record['open_seconds'] = round(time.monotonic() - started, 2)
        started = time.monotonic()
        destination.transfer('apply')
        report = destination.until_state('finished', bringing='finished')['report']
        record['import_seconds'] = round(time.monotonic() - started, 2)
        assert len(report['imported']) == SPACES and not report['failed'] and report['passwordsAdded'] == SPACES * PASSWORDS, report
        record['destination_after'] = footprint(destination)
        started_now = {pid: name for pid, name in r.webkit_processes().items() if pid not in webkit_before}
        record['webkit_started_by_import'] = sorted(name.rsplit('/', 1)[-1] for name in started_now.values())
        listed = [tab for index in range(1, SPACES + 2) for tab in (destination.bench('space', 'go', index), destination.bench('tabs'))[1]['tabs']
                  if not tab['bench']]
        record['tabs_seen'] = len(listed)
        record['tabs_with_a_page'] = sum(1 for tab in listed if tab['view'])
        time.sleep(20)
        record['destination_settled'] = footprint(destination)
        record['destination_idle_after'] = idle(destination, args.idle)
        record['completed'] = True
    finally:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(record, indent=2))
        for world in worlds:
            try: world.wipe()
            except Exception as error: print(f'cleanup of {world.name} failed: {error}')
        server.shutdown(); server.server_close()
        subprocess.run(['rm', '-rf', str(scratch)], check=False)
    print(args.output)


if __name__ == '__main__':
    main()
