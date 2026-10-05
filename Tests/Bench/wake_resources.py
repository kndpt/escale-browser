#!/usr/bin/env python3
"""Measure bounded sleep/wake costs on the same local fixture as the regression.

Run against each optimized bundle with RESULTS=/tmp/name.json. The shared
runner owns the test world. Memory uses the existing physical-footprint and
responsible-WebKit collector; timings include bench IPC and draft checking.
The final 120-second foreground idle interval has no bench traffic. These
small samples describe this workload, not p95, energy or physical scanout.
"""
from pathlib import Path
from threading import Thread
from http.server import ThreadingHTTPServer
import ctypes
import json
import os
import subprocess
import time
import suite as h
import sleep_pictures as resources
from wake_transition import Fixture, bench, row


class Timebase(ctypes.Structure):
    _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]


# proc_pid_rusage CPU counters use Mach time, including on Apple silicon.
timebase = Timebase()
if resources.LIBC.mach_timebase_info(ctypes.byref(timebase)) != 0 or timebase.denom == 0:
    raise RuntimeError('Mach timebase unavailable')
seconds_per_tick = timebase.numer / timebase.denom / 1e9


def cpu(pid):
    value = resources.usage(pid)
    return (value.user + value.system) * seconds_per_tick if value else None


def run():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    Thread(target=server.serve_forever, daemon=True).start()
    origin = f'http://127.0.0.1:{server.server_port}'
    report = {'samples': [], 'setup': {'window': '1100x800', 'foreground': True,
              'optimized': True, 'mach_timebase': [timebase.numer, timebase.denom], 'preview': '1 pixel/point, JPEG 0.55, 8 MB',
              'os': subprocess.check_output(['sw_vers'], text=True),
              'machine': subprocess.check_output(['sysctl', '-n', 'hw.model', 'hw.memsize'], text=True),
              'power': subprocess.check_output(['pmset', '-g', 'batt'], text=True)}}
    with h.world(server):
        h.command('defaults', 'write', h.SUITE, 'sleep.after', '-float', '36000')
        h.command(str(h.ROOT / 'fresh.sh'), 'again')
        h.until('bench ready', lambda: h.SOCKET.exists(), 20)
        bench('resize', '1100', '800')
        lines = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True).splitlines()
        pid = next(int(line.strip().split(None, 1)[0]) for line in lines
                   if line.strip().split(None, 1)[-1] == h.BINARY)
        page = h.open_ordinary(origin + '/page-static')
        other = h.open_ordinary(origin + '/other-static')
        for index in range(5):
            bench('select', other)
            before = resources.memory(pid)
            processes = [pid] + [p for group in resources.webkit(pid).values() for p in group]
            cpu_before = {p: cpu(p) for p in processes}
            start = time.monotonic()
            h.require('discarded', bench('sleep', page)['asleep'], True)
            captured = time.monotonic() - start
            asleep = resources.memory(pid)
            preview_bytes = row(page)['picture']
            start = time.monotonic()
            bench('select', page)
            h.until('wake paints', lambda: not row(page)['unpainted'], 15)
            wake = time.monotonic() - start
            h.loaded_page(page, 'Section', 15, 'resource wake')
            after = resources.memory(pid)
            deltas = {str(p): cpu(p)-value for p, value in cpu_before.items()
                      if value is not None and cpu(p) is not None}
            report['samples'].append(dict(capture_seconds=captured, wake_seconds=wake,
                preview_bytes=preview_bytes, before=before, asleep=asleep, after=after,
                cpu_seconds_existing_processes=deltas))
            print(f'sample {index+1}: capture={captured:.3f}s wake={wake:.3f}s bytes={preview_bytes}', flush=True)
        processes = [pid] + [p for group in resources.webkit(pid).values() for p in group]
        cpu_before = {p: cpu(p) for p in processes}
        print('120s foreground idle without bench traffic', flush=True)
        start = time.monotonic()
        time.sleep(120)
        elapsed = time.monotonic() - start
        report['idle'] = dict(seconds=elapsed, cpu_percent={str(p): 100*(cpu(p)-value)/elapsed
            for p, value in cpu_before.items() if value is not None and cpu(p) is not None},
            browser_pid=pid, memory=resources.memory(pid))
        Path(os.environ.get('RESULTS', '/tmp/issue137-resources.json')).write_text(json.dumps(report, indent=2))
        print(json.dumps(report['idle']), flush=True)


if __name__ == '__main__':
    run()
