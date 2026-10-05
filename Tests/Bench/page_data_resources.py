#!/usr/bin/env python3
"""On-demand page tools: physical footprint, bounded parse latency and teardown.

Run on an optimized build, without another compiler/benchmark. --baseline ROOT
uses a pre-feature checkout's packaged app with the identical local fixtures.
The full request/read/parse/UI publication socket latency is a proxy, not paint.
"""
from argparse import ArgumentParser
from pathlib import Path
import hashlib
import json
import os
import statistics
import time
import page_data_tools as p
import resource_baseline as r


def main():
    parser = ArgumentParser()
    parser.add_argument('--baseline', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = args.baseline.resolve() if args.baseline else p.ROOT
    p.ROOT = root
    r.ROOT = root
    r.WORLD = p.WORLD = 'data-before' if args.baseline else 'data-after'
    env = dict(os.environ, ESCALE_PROBE=p.WORLD, ESCALE_MEASURE='1')
    server = p.ThreadingHTTPServer(('127.0.0.1',0),p.Page)
    p.Thread(target=server.serve_forever,daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    before = set(r.webkit_processes())
    samples = []
    record = {'build':'baseline 5a162c3' if args.baseline else 'candidate', 'baseline':bool(args.baseline),
              'os':r.run('sw_vers'), 'hardware':r.run('sysctl','-n','hw.model','hw.memsize','machdep.cpu.brand_string'),
              'power':r.run('pmset','-g','batt'), 'swift':r.run('swift','--version'),
              'binary_sha256':hashlib.sha256((root/'build/Escale.app/Contents/MacOS/Escale').read_bytes()).hexdigest(),
              'samples':samples}
    try:
        p.run('./fresh.sh','wipe',env=env)
        p.run('defaults','write',f'com.kndpt.escale.test.{p.WORLD}','bench','-bool','YES')
        p.run('./fresh.sh','again',env=env)
        p.ask('ui',welcome=False,sidebar=True,bar=True)
        p.ask('bookmark',url=base+'/sample.json',new=True)
        tab = next(t['id'] for t in p.ask('tabs')['tabs'] if t['url'] == base+'/sample.json')
        p.ask('wait',id=tab,seconds=15)
        created = set(r.webkit_processes()) - before
        def sample(stage):
            samples.append({'stage':stage,**r.sample_memory(created)})
        sample('simple-raw')
        if not args.baseline:
            p.ask('json-reader',id=tab,action='open')
            p.until('parsed', lambda: p.ask('json-reader',id=tab)['count'])
            sample('simple-structured')
            p.ask('json-reader',id=tab,action='raw')
        # bookmark navigates the ordinary tab; go is reserved for bench tabs.
        p.ask('bookmark',url=base+'/large.json')
        p.ask('wait',id=tab,seconds=15)
        sample('19990-values-raw')
        if not args.baseline:
            times=[]
            for index in range(101):
                start=time.monotonic()
                p.ask('json-reader',id=tab,action='open')
                while not p.ask('json-reader',id=tab)['count']:
                    if time.monotonic()-start > 20: raise AssertionError('parse timeout')
                if index: times.append((time.monotonic()-start)*1000)
                if index == 1: sample('19990-values-structured')
                p.ask('json-reader',id=tab,action='raw')
            record['read_parse_publish_ms']={'raw':times,'median':statistics.median(times),'p95':sorted(times)[94],'min':min(times),'max':max(times)}
            sample('after-101-open-close')
        p.ask('bookmark',url=base+'/')
        p.ask('wait',id=tab,seconds=15)
        p.ask('eval',id=tab,js="for(let i=0;i<1000;i++) localStorage.setItem('key'+i,'value '+i); 'seeded'")
        sample('storage-closed')
        if not args.baseline:
            p.ask('site-storage',id=tab,action='open');p.settled(tab)
            sample('storage-1000-open')
            p.ask('site-storage',id=tab,action='close')
            sample('storage-closed-again')
        # One no-traffic 120-second interval after closing all feature work.
        ids=[r.app_pid(),*created]
        cpu={pid:r.cpu_seconds(pid) for pid in ids if pid in r.all_processes()}
        started=time.monotonic()
        time.sleep(120)
        elapsed=time.monotonic()-started
        record['idle_120s_cpu_percent']={str(pid):(r.cpu_seconds(pid)-value)*100/elapsed for pid,value in cpu.items() if pid in r.all_processes()}
        sample('after-idle-120s')
        record['window']=p.ask('probe')
    finally:
        args.output.parent.mkdir(parents=True,exist_ok=True)
        args.output.write_text(json.dumps(record,ensure_ascii=False,indent=2))
        p.run('./fresh.sh','wipe',env=env)
        server.shutdown()
    print(args.output)

if __name__=='__main__': main()
