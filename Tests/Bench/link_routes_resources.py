#!/usr/bin/env python3
"""Optimized-build samples of unused routing and 128 rules, including WebKit.

Run separately against a clean base and candidate with --root and --output.
Each run owns its world. Three snapshots per state are diagnostic samples,
not a physical-memory budget or stable p95. No compiler may run alongside it.
"""
from argparse import ArgumentParser
from pathlib import Path
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
import time
import uuid
import socket
import resource_baseline as r
import link_routes as f


def main():
    parser = ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--routing', action='store_true')
    args = parser.parse_args()
    root = args.root.resolve()
    r.ROOT = root
    output = args.output.resolve()
    server = f.ThreadingHTTPServer(('127.0.0.1', 0), f.Page)
    f.Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    record = {'root': str(root), 'build': 'release',
              'binary_sha256': hashlib.sha256((root / 'build/Escale.app/Contents/MacOS/Escale').read_bytes()).hexdigest(),
              'os': r.run('sw_vers'), 'swift': r.run('swift', '--version'),
              'hardware': r.run('sysctl', '-n', 'hw.model', 'hw.memsize', 'machdep.cpu.brand_string'),
              'power': r.run('pmset', '-g', 'batt'), 'window': [1100, 760], 'runs': []}
    try:
        for count in (0, 128):
            world = 'routes-' + uuid.uuid4().hex[:12]
            r.WORLD = world
            path = r.probe_socket(world)
            r.SOCKET = path
            env = dict(os.environ, ESCALE_PROBE=world, ESCALE_MEASURE='1')
            def run(*args):
                return f.s.subprocess.run(args, cwd=root, env=env, text=True, capture_output=True,
                                          check=True, timeout=60).stdout
            def ask(verb, **fields):
                return r.ask(verb, **fields)
            before = set(r.webkit_processes())
            samples = []
            item = {'rules': count, 'world': world, 'samples': samples}
            record['runs'].append(item)
            try:
                run('./fresh.sh', 'wipe')
                run('defaults', 'write', f'com.kndpt.escale.test.{world}', 'bench', '-bool', 'YES')
                run('defaults', 'write', f'com.kndpt.escale.test.{world}', 'welcomed', '-bool', 'YES')
                checked = (datetime.now(timezone.utc) + timedelta(days=1)).strftime('%Y-%m-%d %H:%M:%S +0000')
                run('defaults', 'write', f'com.kndpt.escale.test.{world}', 'update.checked', '-date', checked)
                rules = [f.rule('00000000-0000-0000-0000-000000000001', '/unused/' + str(i)) for i in range(count)]
                path.parent.mkdir(parents=True, exist_ok=True)
                (path.parent / 'link-rules.json').write_text(json.dumps(rules))
                run('./fresh.sh', 'again')
                f.s.until('socket', lambda: path.exists(), 30)
                ask('ui', welcome=False, sidebar=True, bar=True, look='light')
                ask('resize', width=1100, height=760)
                ask('field', text=base + '/source', go=True)
                tab = next(t['id'] for t in ask('tabs')['tabs'] if t['active'])
                ask('wait', id=tab, seconds=10)
                if args.routing:
                    source = ask('space')['spaces'][0]['id']
                    rules = [f.rule(source, '/unused/' + str(i)) for i in range(count)]
                    ask('routes', rules=json.dumps(rules))
                # Use the same physical zoom in both builds; the base's tap
                # command predates the CSS-to-AppKit zoom correction.
                ask('press', code=24, chars='=', mods=['cmd'])
                actual_zoom = next(t['pageZoom'] for t in ask('tabs')['tabs'] if t['active'])
                if abs(actual_zoom - 1) > 0.001:
                    raise AssertionError(f'expected physical zoom 1, got {actual_zoom}')
                created = set(r.webkit_processes()) - before
                def sample(stage):
                    samples.append({'stage': stage, **r.sample_memory(created)})
                for _ in range(3): sample('loaded')
                # User navigations all miss the rules; route evaluation must
                # not create pages. Round-trip time includes the bench transport.
                times = []
                for _ in range(30):
                    start = time.monotonic()
                    ask('tap', id=tab, selector='#plain')
                    ask('wait', id=tab, seconds=10)
                    times.append((time.monotonic() - start) * 1000)
                item['navigation_roundtrip_ms'] = times
                item['tabs_after'] = len(ask('tabs')['tabs'])
                item['pages_after'] = len(ask('space')['pages'])
                for _ in range(3): sample('after-30-links')
                ask('space', action='new', name='ADO')
                destination = ask('space')['spaces'][-1]['id']
                ask('bookmark', url=base + '/target-seed', new=True)
                seed = next(t['id'] for t in ask('tabs')['tabs'] if t['active'])
                ask('wait', id=seed, seconds=10)
                ask('space', action='go', index=1)
                if args.routing:
                    active_rules = rules[:127] + [f.rule(destination, '/meeting')]
                    ask('routes', rules=json.dumps(active_rules))
                for _ in range(10):
                    if args.routing:
                        ask('tap', id=tab, selector='#same')
                        f.s.until('routed destination', lambda: ask('space')['current'] == 'ADO', 15)
                    else:
                        ask('space', action='go', index=2)
                        ask('bookmark', url=base + '/meeting/same', new=True)
                    arrival = next(t['id'] for t in ask('tabs')['tabs'] if t['active'])
                    ask('wait', id=arrival, seconds=10)
                    ask('press', code=13, chars='w', mods=['cmd'])
                    ask('space', action='go', index=1)
                created |= set(r.webkit_processes()) - before
                item['source_tabs_after_churn'] = len(ask('tabs')['tabs'])
                item['pages_after_churn'] = len(ask('space')['pages'])
                for _ in range(3): sample('after-10-cross-space-open-close')
            finally:
                run('./fresh.sh', 'wipe')
    finally:
        server.shutdown(); server.server_close()
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(record, indent=2))
    print(output)


if __name__ == '__main__':
    main()
