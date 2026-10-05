#!/usr/bin/env python3
"""Before/during/after explicit visual tools on simple and 20,000-node pages.

Optimized app, no concurrent compiler. Includes attributed WebKit processes,
physical-footprint peaks, controlled 60 Hz targeting input and 120 s quiet
teardown. Socket selection latency is not rendering latency or a profiler.
"""
from pathlib import Path
import hashlib
import json
import os
import statistics
import time
import page_visual_tools as v
import resource_baseline as r
p=v.p

def main():
    p.WORLD=r.WORLD='visual-resources';r.ROOT=p.ROOT
    env=dict(os.environ,ESCALE_PROBE=p.WORLD,ESCALE_MEASURE='1')
    server=v.ThreadingHTTPServer(('127.0.0.1',0),v.Page);v.Thread(target=server.serve_forever,daemon=True).start()
    base=f'http://127.0.0.1:{server.server_port}'
    before=set(r.webkit_processes())
    record={'os':r.run('sw_vers'),'hardware':r.run('sysctl','-n','hw.model','hw.memsize','machdep.cpu.brand_string'),
            'power':r.run('pmset','-g','batt'),'swift':r.run('swift','--version'),
            'binary_sha256':hashlib.sha256((p.ROOT/'build/Escale.app/Contents/MacOS/Escale').read_bytes()).hexdigest(),'pages':[]}
    output=p.ROOT/'build/visual-resources.json'
    try:
        p.run('./fresh.sh','wipe',env=env);p.run('defaults','write',f'com.kndpt.escale.test.{p.WORLD}','bench','-bool','YES');p.run('./fresh.sh','again',env=env)
        p.ask('ui',welcome=False,sidebar=True,bar=True)
        p.ask('bookmark',url=base+'/',new=True)
        tab=next(t['id'] for t in p.ask('tabs')['tabs'] if t['url']==base+'/');p.ask('wait',id=tab,seconds=15)
        created=set(r.webkit_processes())-before
        def cpu(seconds):
            ids=[r.app_pid(),*created];live=r.all_processes();start={pid:r.cpu_seconds(pid) for pid in ids if pid in live};began=time.monotonic()
            time.sleep(seconds);elapsed=time.monotonic()-began;live=r.all_processes()
            return {'seconds':elapsed,'percent_one_core':{str(pid):100*(r.cpu_seconds(pid)-n)/elapsed for pid,n in start.items() if pid in live}}
        for path in ['/','/complex']:
            p.ask('bookmark',url=base+path);p.ask('wait',id=tab,seconds=15)
            item={'path':path,'samples':[]};record['pages'].append(item)
            def sample(stage): item['samples'].append({'stage':stage,**r.sample_memory(created)})
            sample('before');item['idle_before']=cpu(30)
            p.ask('visual-pick',id=tab,action='start')
            v.js(tab,"window.measureMoves=0;window.measureTimer=setInterval(()=>{window.measureMoves++;window.dispatchEvent(new PointerEvent('pointermove',{clientX:80+Math.sin(window.measureMoves)*30,clientY:100,bubbles:true}));},1000/60);true")
            item['targeting_60hz']=cpu(30);item['moves']=v.js(tab,'clearInterval(window.measureTimer);window.measureMoves');sample('targeting-active')
            p.ask('visual-pick',id=tab,action='stop')
            times=[]
            for index in range(26):
                start=time.monotonic();p.ask('visual-pick',id=tab,action='start');p.ask('tap',id=tab,selector='#target');v.selected(tab)
                if index:times.append(1000*(time.monotonic()-start))
                p.ask('visual-pick',id=tab,action='stop')
            item['select_publish_ms']={'raw':times,'median':statistics.median(times),'p95':sorted(times)[23]}
            sample('after-targeting')
            for mode in ['visible','full']:
                start=time.monotonic();state=v.capture(tab,mode);item[mode]={'ms':1000*(time.monotonic()-start),'bytes':state['bytes'],'context':state['context']};sample(mode+'-preview');p.ask('page-capture',id=tab,action='close')
            sample('previews-closed');item['idle_after']=cpu(120);sample('after-idle-120s')
            print(path,'done',flush=True)
        record['window']=p.ask('probe')
    finally:
        output.write_text(json.dumps(record,ensure_ascii=False,indent=2));p.run('./fresh.sh','wipe',env=env);server.shutdown()
    print(output,flush=True)

if __name__=='__main__':main()
