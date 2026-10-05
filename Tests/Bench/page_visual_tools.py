#!/usr/bin/env python3
"""Explicit targeting and bounded captures against local synthetic documents.

Real WebKit mouse events select without activating links. Hovering shows the
card's summary without selecting; a click pins it, gives the page its input
back and keeps the outline following scroll. Assertions cover styles,
teardown, shadow/frame boundaries, pixels, drafts and navigation.
Exports belong to a temporary directory, never the user's browser data.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
from pathlib import Path
import json
import os
import struct
import tempfile
import time
import page_data_tools as p

REQUESTS = []
class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        REQUESTS.append(self.path)
        count = 20000 if self.path == '/complex' else 0
        height = 100000 if self.path == '/long' else 2200
        body = f'''<!doctype html><meta charset="utf-8"><title>Visual tools fixture</title>
        <style>body{{margin:0;background:white;color:#222;font:16px Arial}} #target{{display:block;margin:40px;padding:12px;width:260px;height:100px;background:rgb(20,120,210);color:white;font:600 20px/24px Arial;box-sizing:border-box}} #tail{{height:{height}px;background:linear-gradient(#eee,#bbb)}} #fixed{{position:fixed;right:10px;top:10px;background:#ee6}} #shadow{{display:block;width:300px;height:60px}} iframe{{width:250px;height:60px}}</style>
        <div id="fixed">Fixed note</div><a id="target" href="#changed" onclick="window.clicks++;return false">Capture this element</a>
        <input id="draft" value="Original"><div id="shadow"></div><iframe id="frame" srcdoc="<button>Inside frame</button>"></iframe><div id="tail">Document below viewport</div>
        <script>window.clicks=0;document.querySelector('#shadow').attachShadow({{mode:'open'}}).innerHTML='<button style="width:240px;height:50px">Shadow button</button>';
        const fragment=document.createDocumentFragment();for(let i=0;i<{count};i++){{let span=document.createElement('span');span.textContent='row '+i;fragment.append(span)}}document.body.append(fragment);</script>'''
        data=body.encode();self.send_response(200);self.send_header('Content-Type','text/html; charset=utf-8');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
    def log_message(self,*_): pass

def js(tab,code): return p.ask('eval',id=tab,js=code)['value']
def selected(tab): return p.until('selection',lambda:(s if s['selected'] else None) if (s:=p.ask('visual-pick',id=tab)) else None)
def captured(tab):
    state=p.until('capture',lambda:(s if not s['busy'] else None) if (s:=p.ask('page-capture',id=tab)) else None)
    assert not state['failure'] and state['bytes'] > 0,state
    return state

def capture(tab,mode,path=None):
    p.ask('page-capture',id=tab,action='take',mode=mode);state=captured(tab)
    if path:
        p.ask('page-capture',id=tab,path=str(path));data=path.read_bytes()
        assert data[:8] == b'\x89PNG\r\n\x1a\n'
        width,height=struct.unpack('>II',data[16:24]);assert 0<width<=2048 and 0<height<=2048,(width,height)
        state['pixels']=[width,height]
    return state

def main():
    p.WORLD='page-visual-91-92'
    env=dict(os.environ,ESCALE_PROBE=p.WORLD)
    server=ThreadingHTTPServer(('127.0.0.1',0),Page);Thread(target=server.serve_forever,daemon=True).start()
    base=f'http://127.0.0.1:{server.server_port}'
    try:
        p.run('./fresh.sh','wipe',env=env);p.run('defaults','write',f'com.kndpt.escale.test.{p.WORLD}','bench','-bool','YES');p.run('./fresh.sh','again',env=env)
        p.ask('ui',welcome=False)
        tab=p.ask('open',url=base)['id'];p.ask('select',id=tab);p.ask('wait',id=tab,seconds=15)
        assert not p.ask('visual-pick',id=tab)['active']
        assert js(tab,"document.querySelectorAll('[data-escale-visual-pick]').length") == 0
        p.ask('visual-pick',id=tab,action='start');p.ask('tap',id=tab,selector='#target');state=selected(tab)
        assert state['label']=='a#target' and state['width']==260,state
        styles={s['name']:s['value'] for s in state['styles']};assert styles['font-size']=='20px' and styles['padding']=='12px',styles
        assert js(tab,'window.clicks') == 0
        # Pinned: the outline stays on the element until the result goes.
        assert js(tab,"document.querySelectorAll('[data-escale-visual-pick]').length") == 1
        with tempfile.TemporaryDirectory(prefix='escale-captures-',dir='/tmp') as folder:
            folder=Path(folder)
            result=capture(tab,'element',folder/'element.png');assert result['pixels']==[260,100],result
            p.ask('page-capture',id=tab,action='close')
            js(tab,"document.querySelector('#draft').value='Unsent é🌍';window.scrollTo(0,200);true")
            before=js(tab,'JSON.stringify([scrollX,scrollY,document.querySelector("#draft").value,location.href])');requests=len(REQUESTS)
            visible=capture(tab,'visible',folder/'visible.png');p.ask('page-capture',id=tab,action='close')
            full=capture(tab,'full',folder/'full.png');assert full['pixels'][1]==2048,full
            assert js(tab,'JSON.stringify([scrollX,scrollY,document.querySelector("#draft").value,location.href])')==before
            assert len(REQUESTS)==requests
            state=p.ask('page-capture',id=tab,url=False,version=True);assert 'URL:' not in state['context'] and 'Escale ' in state['context']
            p.ask('page-capture',id=tab,action='close');assert p.ask('page-capture',id=tab)['bytes']==0
            js(tab,'window.scrollTo(0,0);true');time.sleep(.2);p.ask('tap',id=tab,selector='#target');p.until('ordinary link restored',lambda:js(tab,'window.clicks')==1)
            for selector,flag in [('#shadow','shadow'),('#frame','frame')]:
                p.ask('visual-pick',id=tab,action='start');p.ask('tap',id=tab,selector=selector);state=selected(tab);assert state[flag],state
                p.ask('visual-pick',id=tab,action='stop')
            p.ask('visual-pick',id=tab,action='start');p.ask('press',code=53,chars='\x1b');p.until('escape',lambda:not p.ask('visual-pick',id=tab)['active'])
            assert js(tab,"document.querySelectorAll('[data-escale-visual-pick]').length")==0
            # A pointer move shows the summary beside the element, without selecting.
            # WebKit ignores a synthesized AppKit mouseMoved in a probe's window
            # (checked on macOS 27: no pointermove reached the page, directly or
            # through its tracking area), so the move is a page PointerEvent.
            p.ask('visual-pick',id=tab,action='start')
            js(tab,"(()=>{const r=document.querySelector('#target').getBoundingClientRect();window.dispatchEvent(new PointerEvent('pointermove',{clientX:r.x+r.width/2,clientY:r.y+r.height/2,bubbles:true}));return true})()")
            state=p.until('hover summary',lambda:(s if s.get('glance') else None) if (s:=p.ask('visual-pick',id=tab)) else None)
            assert state['active'] and not state['selected'],state
            assert state['glance']=={'label':'a#target','family':'Arial','size':'20px','line':'24px','weight':'600',
                                     'colour':'#FFFFFF','background':'#1478D2','padding':'12px'},state['glance']
            assert abs(state['anchor']['width']-260)<1 and abs(state['anchor']['height']-100)<1,state
            assert js(tab,'window.clicks')==1
            p.ask('tap',id=tab,selector='#target');state=selected(tab);top=state['anchor']['y']
            assert state['glance']['label']=='a#target' and not state['detailed'],state
            js(tab,'window.scrollBy(0,30);true')
            p.until('pinned follows scroll',lambda:abs(p.ask('visual-pick',id=tab)['anchor']['y']-(top-30))<1)
            # The page has its input back while the card is pinned.
            p.ask('tap',id=tab,selector='#target');p.until('pinned page clickable',lambda:js(tab,'window.clicks')==2)
            assert p.ask('visual-pick',id=tab)['selected']
            p.ask('visual-pick',id=tab,action='more');assert p.ask('visual-pick',id=tab)['detailed']
            p.ask('press',code=53,chars='\x1b');p.until('escape pinned',lambda:not p.ask('visual-pick',id=tab)['selected'])
            assert js(tab,"document.querySelectorAll('[data-escale-visual-pick]').length")==0
            js(tab,'window.scrollTo(0,0);true')
            # A focus event followed by a real Return exercises keyboard selection.
            p.ask('visual-pick',id=tab,action='start');js(tab,"document.querySelector('#target').focus();true");p.ask('key',id=tab,text='\r');assert selected(tab)['label']=='a#target'
            p.ask('visual-pick',id=tab,action='stop')
            for code,chars in [(24,'+'),(27,'-')]:
                p.ask('press',code=code,chars=chars,mods=['cmd']);time.sleep(.2)
                zoom=next(t['pageZoom'] for t in p.ask('tabs')['tabs'] if t['id']==tab)
                p.ask('visual-pick',id=tab,action='start');p.ask('tap',id=tab,selector='#target');selected(tab)
                result=capture(tab,'element',folder/'zoom.png')
                assert abs(result['pixels'][0]-260*zoom)<2 and abs(result['pixels'][1]-100*zoom)<2,result
                p.ask('page-capture',id=tab,action='close')
            # Switching to another tab clears frozen results and the retained PNG.
            other=p.ask('open',url=base)['id'];p.ask('wait',id=other,seconds=15)
            p.ask('select',id=tab);capture(tab,'visible');p.ask('select',id=other)
            assert not p.ask('page-capture',id=tab)['shown'] and p.ask('page-capture',id=tab)['bytes']==0
            p.ask('select',id=tab);p.ask('visual-pick',id=tab,action='start');p.ask('ui',settings=True)
            assert not p.ask('visual-pick',id=tab)['active'];p.ask('ui',settings=False)
            p.load(tab,base+'/long');result=capture(tab,'full',folder/'long.png');assert 'Limited capture' in result['notice']
            p.ask('page-capture',id=tab,action='close')
            p.ask('page-capture',id=tab,action='take',mode='full');p.ask('page-capture',id=tab,action='close');time.sleep(.3)
            assert not p.ask('page-capture',id=tab)['shown'] and p.ask('page-capture',id=tab)['bytes']==0
            p.ask('visual-pick',id=tab,action='start');p.load(tab,base+'/complex');assert not p.ask('visual-pick',id=tab)['active']
            p.ask('visual-pick',id=tab,action='start');p.ask('tap',id=tab,selector='#target');assert selected(tab)['label']=='a#target'
            p.ask('visual-pick',id=tab,action='stop')
            p.ask('visual-pick',id=tab,action='start');p.ask('tap',id=tab,selector='#target');selected(tab)
            js(tab,"document.querySelector('#target').remove();true")
            p.ask('page-capture',id=tab,action='take',mode='element')
            failed=p.until('removed element',lambda:(s if not s['busy'] else None) if (s:=p.ask('page-capture',id=tab)) else None)
            assert 'gone' in failed['failure'] and failed['bytes']==0,failed
            p.ask('page-capture',id=tab,action='close')
            capture(tab,'visible');p.ask('idle',level='critical');assert p.ask('page-capture',id=tab)['bytes']==0
            print(json.dumps({'result':'PASS','visible':visible,'full':full},ensure_ascii=False))
    finally:
        p.run('./fresh.sh','wipe',env=env);server.shutdown()

if __name__=='__main__':main()
