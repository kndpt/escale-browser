#!/usr/bin/env python3
"""Search in the page frame across layouts, sizes and themes, with real keys.

Focus, Escape, outside click, no page reload and unchanged frame are asserted.
"""
import json
import os
import time
from http.server import ThreadingHTTPServer
from threading import Thread
import suite as s


def bench(*args):
    return json.loads(s.command(str(s.ROOT / 'bench'), '--world', s.WORLD, '--json', *args))


def main():
    server = ThreadingHTTPServer(('127.0.0.1',0),s.Page)
    Thread(target=server.serve_forever,daemon=True).start()
    try:
        s.command(str(s.ROOT/'fresh.sh'),'wipe')
        s.command('defaults','write',s.SUITE,'bench','-bool','YES')
        s.launch();bench('ui','welcome','off');bench('resize','1100','760')
        bench('field',f'http://127.0.0.1:{server.server_port}/frame','go')
        tab=next(t for t in s.tabs() if t['active'])['id'];bench('wait',tab,'10')
        bench('eval',tab,"window.marker='unchanged'; document.body.style.background='#547f91'; 'ok'")
        checked = 0
        for theme in ('light','dark'):
            bench('ui','look',theme)
            for size in ('compact','standard','large'):
                bench('ui','size',size)
                for layout,sidebar,bar,folded in [('top','off','off','off'),('side','on','on','off'),('no-bar','on','off','off'),('folded','on','on','on'),('folded-no-bar','on','off','on')]:
                    if os.environ.get('LAYOUTS') and layout not in os.environ['LAYOUTS'].split(','): continue
                    for key,value in [('sidebar',sidebar),('bar',bar),('folded',folded)]:bench('ui',key,value)
                    time.sleep(.6) # let the documented chrome transition settle for geometry
                    before=bench('probe')['pageFrame']
                    assert before[1] >= 30, (layout,size,before)
                    checked += 1
                    name=f'{theme}-{size}-{layout}'
                    for code,char in [(17,'t'),(37,'l'),(40,'k')]:
                        bench('press',str(code),char,'cmd')
                        s.require(name+' focus',bench('probe')['fieldFocused'],True)
                        s.require(name+' page stays put',bench('probe')['pageFrame'],before)
                        bench('press','53','\x1b')
                        s.require(name+' Escape',bench('probe')['fieldShowing'],False)
                    bench('press','17','t','cmd')
                    bench('hit',str(before[0]+before[2]/2),str(before[1]+before[3]-30),'click')
                    s.until(name+' outside click',lambda:not bench('probe')['fieldShowing'],5)
                    for y in (before[1]/2, 757):
                        bench('press','17','t','cmd')
                        bench('hit',str(before[0]+before[2]/2),str(y),'click','live')
                        s.until(name+' chrome/margin click',lambda:not bench('probe')['fieldShowing'],5)
                    s.require(name+' same document',bench('eval',tab,'window.marker')['value'],'unchanged')
        print(f'ok: {checked} layout/size/theme combinations, Cmd T/L/K focus, Escape, outside click, same page frame and document')
    finally:
        s.command(str(s.ROOT/'fresh.sh'),'wipe');server.shutdown();server.server_close()


if __name__=='__main__':main()
