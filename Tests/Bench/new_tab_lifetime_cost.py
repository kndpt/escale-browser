#!/usr/bin/env python3
"""Measure New Tab off/on/cancelled over one ordinary local static page.

Run sequentially against optimised baseline/candidate builds, without a compiler
or another benchmark. Each invocation owns a fresh world. Physical footprints
come from the shared collector; helpers attributed only by launch time remain
explicitly inferred, and their sum is not a deduplicated physical total.
"""
import argparse
import hashlib
import json
from pathlib import Path
import platform
from http.server import ThreadingHTTPServer
from threading import Thread
import time
import uuid
import resource_baseline as r


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, default=r.ROOT)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    r.ROOT = args.root.resolve()
    server = ThreadingHTTPServer(('127.0.0.1', 0), r.Page)
    Thread(target=server.serve_forever, daemon=True).start()
    url = f'http://127.0.0.1:{server.server_port}/static'
    world = 'nt-cost-' + uuid.uuid4().hex[:8]
    before = set(r.webkit_processes())
    try:
        r.setup(world)
        r.run(r.ROOT / 'fresh.sh', 'again')
        r.until('ready', lambda: bool(r.ask('tabs')['tabs']), 30)
        r.ask('ui', welcome=False)
        r.ask('resize', width=1100, height=760)
        r.ask('field', text=url, go=True)
        r.until('loaded', lambda: any(t['url'] == url and not t['loading']
                                     for t in r.ask('tabs')['tabs']), 15)
        page = next(t['id'] for t in r.ask('tabs')['tabs'] if t['active'])
        samples = []

        def sample(phase):
            # Identical declared settle interval for each phase/revision.
            time.sleep(2)
            created = set(r.webkit_processes()) - before
            samples.append({'phase': phase, 'tabs': r.ask('tabs')['tabs'],
                            'pages': r.ask('space')['pages'],
                            'memory': r.sample_memory(created)})

        sample('page')
        r.ask('press', code=17, chars='t', mods=['cmd'])
        sample('search')
        r.ask('press', code=53, chars='\x1b')
        r.ask('select', id=page)
        sample('cancelled')
        for _ in range(12):
            r.ask('press', code=17, chars='t', mods=['cmd'])
            r.ask('press', code=53, chars='\x1b')
            r.ask('select', id=page)
        sample('after-12-cycles')
        binary = r.ROOT / 'build/Escale.app/Contents/MacOS/Escale'
        args.output.write_text(json.dumps({
            'root': str(r.ROOT), 'os': platform.platform(), 'world': world,
            'binarySHA256': hashlib.sha256(binary.read_bytes()).hexdigest(),
            'build': 'release', 'window': [1100, 760], 'fixture': 'resource_baseline.Page /static',
            'history': 'fresh world, one local page', 'extensions': 0,
            'blocking': 'default', 'power': r.run('pmset', '-g', 'batt'),
            'samples': samples}, indent=2))
        print(args.output, flush=True)
    finally:
        r.run(r.ROOT / 'fresh.sh', 'wipe')
        server.shutdown()


if __name__ == '__main__':
    main()
