#!/usr/bin/env python3
"""Before/after footprint for held downloads and search, then 120 s quiet idle.

Both checkouts need optimized packaged apps. Reuses the existing footprint
collector and launch isolation; records attribution and raw samples, not energy.
"""
from argparse import ArgumentParser
from pathlib import Path
import json
import hashlib
import os
import time
import uuid
import socket
import download_activity as d
import resource_baseline as r


def main():
    parser=ArgumentParser();parser.add_argument('--root',type=Path,default=d.s.ROOT);parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();args.output=args.output.resolve();root=args.root.resolve();world='activity-'+uuid.uuid4().hex[:12]
    r.ROOT=root;r.WORLD=world
    env=dict(os.environ,ESCALE_PROBE=world,ESCALE_MEASURE='1')
    server=d.ThreadingHTTPServer(('127.0.0.1',0),d.Page);d.Thread(target=server.serve_forever,daemon=True).start()
    base=f'http://127.0.0.1:{server.server_port}'
    path=Path.home()/'Library/Application Support'/f'Escale ({world})'/'bench.sock'
    def run(*cmd):return d.s.subprocess.run(cmd,cwd=root,env=env,capture_output=True,text=True,check=True,timeout=60).stdout
    def ask(verb,**fields):
        with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as connection:
            connection.settimeout(30);connection.connect(str(path));connection.sendall((json.dumps({'do':verb,**fields})+'\n').encode());data=b''
            while True:
                part=connection.recv(65536)
                if not part:break
                data+=part
        result=json.loads(data.split(b'\n')[0]);assert 'error' not in result,result;return result
    before=set(r.webkit_processes());samples=[]
    record={'root':str(root),'revision':run('git','rev-parse','HEAD').strip(),'build':'release','binary_sha256':hashlib.sha256((root/'build/Escale.app/Contents/MacOS/Escale').read_bytes()).hexdigest(),'swift':r.run('swift','--version'),'workload':f'foreground fresh world; one loopback page; two held {len(d.body)}-byte files at 25% and 50%; no installed extensions','os':r.run('sw_vers'),'hardware':r.run('sysctl','-n','hw.model','hw.memsize','machdep.cpu.brand_string'),'power':r.run('pmset','-g','batt'),'window':[1100,760],'samples':samples}
    try:
        run('./fresh.sh','wipe');run('defaults','write',f'com.kndpt.escale.test.{world}','bench','-bool','YES');run('./fresh.sh','again')
        d.s.until('ready',lambda:path.exists(),30)
        ask('ui',welcome=False,sidebar=True,bar=True,look='light');ask('resize',width=1100,height=760)
        ask('field',text=base+'/home',go=True)
        tab=next(t['id'] for t in ask('tabs')['tabs'] if t['active']);ask('wait',id=tab,seconds=10)
        created=set(r.webkit_processes())-before
        def sample(stage):samples.append({'stage':stage,**r.sample_memory(created)})
        def capture(stage):
            args.output.parent.mkdir(parents=True,exist_ok=True)
            window=next(w for w in ask('probe')['windows'] if w['visible'] and w['frame'][2:]==[1100,760])
            run('screencapture','-x','-o','-l',str(window['number']),str(args.output.with_name(args.output.stem+'-'+stage+'.png')))
        capture('page')
        for _ in range(3):sample('idle-before')
        for name in ('one','two'):
            ask('eval',id=tab,js=f"var a=document.createElement('a');a.href='/{name}';a.download='';document.body.append(a);a.click();'sent'")
        d.s.until('two active',lambda:ask('probe')['activeDownloads']==2,15)
        for _ in range(3):sample('two-active')
        capture('downloads')
        for event in d.releases.values():event.set()
        d.s.until('finished',lambda:ask('probe')['activeDownloads']==0,15)
        ask('press',code=17,chars='t',mods=['cmd'])
        for _ in range(3):sample('search-open')
        capture('search-light')
        ask('ui',look='dark');time.sleep(.5);capture('search-dark');ask('ui',look='light')
        ask('press',code=53,chars='\x1b',mods=[])
        for _ in range(3):sample('closed-again')
        ids=[r.app_pid(),*created];cpu={pid:r.cpu_seconds(pid) for pid in ids if pid in r.all_processes()};started=time.monotonic()
        print('120-second idle started',flush=True);time.sleep(120)
        record['idle_seconds']=time.monotonic()-started
        record['idle_cpu_percent']={str(pid):(r.cpu_seconds(pid)-value)*100/record['idle_seconds'] for pid,value in cpu.items() if pid in r.all_processes()}
        record['after']=ask('probe');sample('after-idle')
    finally:
        args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(record,indent=2))
        for event in d.releases.values():event.set()
        run('./fresh.sh','wipe');server.shutdown();server.server_close()
    print(args.output)


if __name__=='__main__':main()
