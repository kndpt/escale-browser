#!/usr/bin/env python3
"""Comparable New Tab typing samples, with synthetic history and bookmarks.

Run after an optimised build. Pass --root for an archived baseline checkout
with its own build/Escale.app. Outputs raw per-character dispatch/run-loop
milliseconds and browser RSS; it does not claim WebKit footprint or energy.
Each invocation uses suite.py's unique isolated world and launch procedure.
"""
import argparse
import json
from pathlib import Path
import platform
import time
import uuid
import suite as s


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, default=s.ROOT)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--runs', type=int, default=6)
    args = parser.parse_args()
    args.root = args.root.resolve()
    launcher = args.root / 'fresh.sh'
    binary = str(args.root / 'build/probe' / s.WORLD / 'Escale.app/Contents/MacOS/Escale')

    def bench(*parts):
        return json.loads(s.command(str(s.ROOT / 'bench'), '--world', s.WORLD, '--json', *parts))

    try:
        s.command(str(launcher), 'wipe')
        s.command('defaults', 'write', s.SUITE, 'bench', '-bool', 'YES')
        folder = s.SOCKET.parent
        folder.mkdir(parents=True, exist_ok=True)
        now = time.time() - 978307200
        (folder / 'history.json').write_text(json.dumps([
            {'url': f'https://project{i}.example.test/', 'key': f'project{i}.example.test',
             'title': f'Project {i}', 'last': now - i, 'count': 1} for i in range(2000)]))
        (folder / 'bookmarks.json').write_text(json.dumps([
            {'id': str(uuid.uuid4()), 'title': f'Project {i}', 'url': f'https://project{i}.example.test/'} for i in range(2000)]))
        s.command(str(launcher), 'again')
        s.until('cost world ready', s.probe_ready, 30)
        bench('ui', 'welcome', 'off')
        bench('resize', '1100', '760')
        # One declared warm-up for each query, followed by alternating common
        # and absent matches. Bench returns per-character run-loop samples.
        queries = ['project299', 'unmatchedx']
        for query in queries:
            bench('field', query, 'type')
        samples = []
        for _ in range(args.runs):
            for query in queries:
                result = bench('field', query, 'type')
                samples.append({'query': query, 'ms': result['ms']})
        processes = s.command('ps', '-axo', 'pid=,rss=,comm=')
        browser = [line.strip() for line in processes.splitlines() if line.strip().endswith(binary)]
        result = {'os': platform.platform(), 'root': str(args.root), 'history': 2000, 'bookmarks': 2000,
                  'window': [1100, 760], 'build': 'release', 'warmupQueries': queries,
                  'samples': samples, 'browserProcessPidRSSKiBCommand': browser,
                  'pageViews': bench('space')['pages'], 'power': s.command('pmset', '-g', 'batt')}
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2))
        print(args.output)
    finally:
        s.command(str(launcher), 'wipe')


if __name__ == '__main__':
    main()
