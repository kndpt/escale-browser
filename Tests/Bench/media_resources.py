#!/usr/bin/env python3
"""Optimized before/after media workload, attributed footprint and quiet idle.

Run under the shared machine gate, with no other compiler or benchmark. --root
can select the clean reference build. Samples are repeated observations of one
world, not independent launches. Bench traffic stops during the 120 s idle.
"""
from argparse import ArgumentParser
from pathlib import Path
import hashlib
import json
import os
import socket
import time
import uuid
import media_player as m
import resource_baseline as r

def main():
    parser=ArgumentParser();parser.add_argument('--root',type=Path,default=m.s.ROOT);parser.add_argument('--output',type=Path,required=True);parser.add_argument('--baseline',action='store_true')
    args=parser.parse_args();root=args.root.resolve();world='media-'+uuid.uuid4().hex[:12];r.ROOT=root;r.WORLD=world
    env=dict(os.environ,ESCALE_PROBE=world,ESCALE_MEASURE='1');path=Path.home()/'Library/Application Support'/f'Escale ({world})'/'bench.sock'
    server=m.ThreadingHTTPServer(('127.0.0.1',0),m.Page);m.Thread(target=server.serve_forever,daemon=True).start();base=f'http://127.0.0.1:{server.server_port}'
    def run(*cmd):return m.s.subprocess.run(cmd,cwd=root,env=env,capture_output=True,text=True,check=True,timeout=90).stdout
    def ask(verb,**fields):
        with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as c:
            c.settimeout(30);c.connect(str(path));c.sendall((json.dumps({'do':verb,**fields})+'\n').encode());data=b''
            while True:
                part=c.recv(65536)
                if not part:break
                data+=part
        result=json.loads(data.split(b'\n')[0]);assert 'error' not in result,result;return result
    before=set(r.webkit_processes());samples=[]
    record={'root':str(root),'baseline':args.baseline,'build':'release','binary_sha256':hashlib.sha256((root/'build/Escale.app/Contents/MacOS/Escale').read_bytes()).hexdigest(),
        'swift':r.run('swift','--version'),'os':r.run('sw_vers'),'hardware':r.run('sysctl','-n','hw.model','hw.memsize','machdep.cpu.brand_string'),'power':r.run('pmset','-g','batt'),
        'display':r.run('system_profiler','SPDisplaysDataType'),'window':[1100,760],'workload':'fresh visible world, no extensions, default blocker, looped 10s 8kHz mono synthetic WAV; one source + quiet tab; three readings at each stage; no compilation or other test app',
        'samples':samples,'limits':'physical footprint summed per process; launch-cohort attribution may include shared helpers; no energy or main-thread/scanout profile; bench installed but no traffic during idle'}
    def sample(stage):
        created=set(r.webkit_processes())-before
        samples.append({'stage':stage,**r.sample_memory(created)})
    try:
        run('./fresh.sh','wipe');run('defaults','write',f'com.kndpt.escale.test.{world}','bench','-bool','YES');run('./fresh.sh','again');m.s.until('socket',path.exists,30)
        ask('ui',welcome=False,sidebar=True,spaces=True,bar=True,look='light');ask('resize',width=1100,height=760)
        ask('field',text=base+'/audio',go=True);tab=next(t['id'] for t in ask('tabs')['tabs'] if t['active']);ask('wait',id=tab,seconds=10)
        for _ in range(3):sample('before-playback')
        ask('tap',id=tab,selector='#play');m.s.until('playing',lambda:ask('eval',id=tab,js='!document.querySelector("audio").paused')['value'],10)
        ask('bookmark',url=base+'/blank',new=True);quiet=next(t['id'] for t in ask('tabs')['tabs'] if t['active']);ask('wait',id=quiet,seconds=10)
        if not args.baseline:m.s.until('reader attached',lambda:ask('media')['listeners']==1,10)
        for _ in range(3):sample('background-playback')
        ask('eval',id=tab,js='document.querySelector("audio").pause();true')
        if not args.baseline:m.s.until('paused',lambda:not ask('media')['sources'][0]['playing'],10)
        for _ in range(3):sample('paused')
        if not args.baseline:ask('media',id=tab,action='dismiss')
        for _ in range(3):sample('dismissed')
        ask('select',id=tab);ask('press',code=13,chars='w',mods=['cmd'])
        if not args.baseline:record['cleanup']=ask('media');assert record['cleanup']['listeners']==0
        for _ in range(3):sample('closed')
        ids=[r.app_pid(),*(set(r.webkit_processes())-before)];start={pid:dict(cpu=r.cpu_seconds(pid), **r.wakeups(pid)) for pid in ids}
        started=time.monotonic();print('idle 120 seconds, no bench traffic',flush=True)
        time.sleep(120)
        elapsed=time.monotonic()-started;record['idle_seconds']=elapsed;record['idle']={}
        for pid,old in start.items():
            if pid not in r.all_processes():continue
            new=dict(cpu=r.cpu_seconds(pid), **r.wakeups(pid))
            record['idle'][str(pid)]={'cpu_percent':(new['cpu']-old['cpu'])*100/elapsed,
                'interrupt_wakeups':new['interrupt']-old['interrupt'],'package_idle_wakeups':new['package_idle']-old['package_idle']}
        sample('after-idle')
    finally:
        args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(record,indent=2));run('./fresh.sh','wipe');server.shutdown();server.server_close()
    print(args.output,flush=True)

if __name__=='__main__':main()
