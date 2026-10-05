#!/usr/bin/env python3
"""Real WebKit audio/video, source targeting and event-reader teardown for the
mini player.

A generated WAV and a canvas/audio MediaStream contain only synthetic data.
Commands use production Media actions; playback starts with a real page click.
INSPECT keeps only this owned world up for manual access until the file named
in the printed context exists.
"""
import io
import json
import math
import os
import struct
import wave
from pathlib import Path
from http.server import ThreadingHTTPServer
from threading import Thread
import suite as s

wave_data=io.BytesIO()
with wave.open(wave_data,'wb') as out:
    out.setparams((1,2,8000,0,'NONE','not compressed'))
    out.writeframes(b''.join(struct.pack('<h',int(1000*math.sin(2*math.pi*220*i/8000))) for i in range(80000)))
HTML="""<!doctype html><title>Independent media fixture</title>
<style>body{font:20px system-ui;padding:40px;background:#fff;color:#222}video{width:480px;height:270px;display:block}button{display:block;width:400px;height:70px;margin:15px 0}</style>
<h1>Independent media fixture</h1><button id="play" onclick="start()">Play synthetic audio</button>
<button id="video" onclick="movie()">Play synthetic video</button>
<audio id="audio" src="/tone.wav" loop controls></audio><video id="film" controls></video>
<script>
let a=document.querySelector('audio'), v=document.querySelector('video');
function start(){navigator.mediaSession.metadata=new MediaMetadata({title:'Synthetic tone — track one'}); a.play();}
function movie(){
 a.pause();const c=document.createElement('canvas');c.width=480;c.height=270;
 const x=c.getContext('2d');x.fillStyle='#426080';x.fillRect(0,0,480,270);x.fillStyle='white';x.font='24px sans-serif';x.fillText('Synthetic video',90,140);
 const context=new AudioContext(), oscillator=context.createOscillator(), gain=context.createGain(), destination=context.createMediaStreamDestination();
 gain.gain.value=.04;oscillator.connect(gain);gain.connect(destination);oscillator.start();
 const stream=c.captureStream(1);destination.stream.getAudioTracks().forEach(t=>stream.addTrack(t));v.srcObject=stream;v.play();
 navigator.mediaSession.metadata=new MediaMetadata({title:'Synthetic video'});
 setTimeout(()=>{x.fillRect(0,0,20,20);stream.getVideoTracks()[0].requestFrame?.();},100);window.fixtureContext=context;
}
</script>"""

class Page(s.Page):
    def do_GET(self):
        if self.path.startswith('/blank'): data=b'<title>Quiet destination</title><h1>Quiet destination</h1>'
        elif self.path.startswith('/tone.wav'): data=wave_data.getvalue()
        elif self.path.startswith('/frame'): data=b"""<title>Iframe source</title>
<button id="frame-play" style="display:block;width:400px;height:70px;margin:60px" onclick="document.querySelector('iframe').contentDocument.querySelector('#play').click()">Play iframe</button>
<audio src="/tone.wav" preload="auto"></audio><iframe src="/audio" width="800" height="500"></iframe>"""
        else: data=HTML.encode()
        self.send_response(200);self.send_header('Content-Type','audio/wav' if self.path.startswith('/tone.wav') else 'text/html; charset=utf-8')
        self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)

def b(*args):return json.loads(s.command(str(s.ROOT/'bench'),'--world',s.WORLD,'--json',*args))
def state():return b('media')
def find(tab):return next((x for x in state()['sources'] if x['id'].lower().startswith(tab.lower())),None)
def visible(tab):return any(x.lower().startswith(tab.lower()) for x in state()['visible'])
def js(tab,script):return b('eval',tab,script)['value']
def action(tab,name,**args):
    b('media',tab,json.dumps(dict(action=name,**args)))
    s.until(name+' completed',lambda:not find(tab) or not find(tab)['busy'])
def open_page(base,path='/audio'):
    b('bookmark',base+path,'new');tab=next(t for t in s.tabs() if t['active'])['id'];b('wait',tab,'10');return tab
def start(tab,selector='#play'):
    b('tap',tab,selector);s.until('audible source observed',lambda:find(tab) and find(tab)['playing'])
    s.until('real controls discovered',lambda:'volume' in find(tab)['actions'])
def main():
    server=ThreadingHTTPServer(('127.0.0.1',0),Page);Thread(target=server.serve_forever,daemon=True).start();base=f'http://127.0.0.1:{server.server_port}'
    try:
        s.command(str(s.ROOT/'fresh.sh'),'wipe');s.command('defaults','write',s.SUITE,'bench','-bool','YES');s.launch()
        b('ui','welcome','off');b('ui','sidebar','on');b('ui','spaces','on');b('resize','1100','760')
        first=open_page(base);s.require('no media reader before playback',state()['listeners'],0);start(first)
        s.require('foreground source hidden',visible(first),False)
        quiet=open_page(base,'/blank');s.until('background player visible',lambda:visible(first))
        assert find(first)['noisy'];assert set(find(first)['actions'])=={'pause','volume'}
        pages=b('space')['pages'];action(first,'pause');s.until('paused state',lambda:not find(first)['playing'])
        assert js(first,'document.querySelector("audio").paused') is True
        action(first,'dismiss');b('select',first);b('select',quiet);s.until('paused dismissed source reopens',lambda:find(first) and 'play' in find(first)['actions'])
        action(first,'play');s.until('resumed',lambda:find(first)['playing']);assert js(first,'document.querySelector("audio").paused') is False
        action(first,'volume',value=.3);s.until('volume confirmed',lambda:abs(find(first)['volume']-.3)<.01)
        assert abs(js(first,'document.querySelector("audio").volume')-.3)<.01
        js(first,'document.querySelector("audio").muted=true');s.until('muted',lambda:find(first)['muted'])
        js(first,'document.querySelector("audio").muted=false');s.until('unmuted',lambda:not find(first)['muted'])
        js(first,"navigator.mediaSession.metadata=new MediaMetadata({title:'Track two'});document.querySelector('audio').dispatchEvent(new Event('loadedmetadata'));true")
        s.until('metadata changes',lambda:find(first)['title']=='Track two')
        action(first,'dismiss');assert not visible(first);assert not find(first);s.require('dismissal removes DOM reader',state()['listeners'],0)
        assert js(first,'window.__escaleMedia === undefined') is True
        assert js(first,'document.querySelector("audio").paused') is False
        b('select',first);b('select',quiet);s.until('leaving source reopens',lambda:visible(first))
        action(first,'dismiss');js(first,'document.querySelector("audio").pause()');s.until('WebKit goes quiet',lambda:js(first,'document.querySelector("audio").paused'))
        # A user restart is a new audible session, even while source stays behind.
        js(first,'document.querySelector("audio").play();true');s.until('new session reappears',lambda:visible(first))
        b('space','new','Media destination');s.until('source survives Space switch',lambda:visible(first));assert js(first,'document.querySelector("audio").paused') is False
        action(first,'pause');assert js(first,'document.querySelector("audio").paused') is True
        action(first,'play');action(first,'return');assert next(t for t in s.tabs() if t['active'])['id']==first
        b('space','go','2');second=open_page(base);start(second);quiet2=open_page(base,'/blank')
        s.until('two distinct background sources',lambda:len(state()['visible'])==2)
        pages=b('space')['pages']
        action(first,'pause');assert js(second,'document.querySelector("audio").paused') is False
        action(first,'play');assert js(first,'document.querySelector("audio").paused') is False
        assert b('space')['pages']==pages, 'controls must never construct a page'
        if os.environ.get('INSPECT'):
            done=Path('/tmp/sidebar-media-inspect-done');done.unlink(missing_ok=True)
            Path('/tmp/sidebar-media-inspect.json').write_text(json.dumps({'world':s.WORLD,'first':first,'second':second,'quiet':quiet2,'base':base,'binary':s.BINARY}))
            print('inspect /tmp/sidebar-media-inspect.json; finish with /tmp/sidebar-media-inspect-done',flush=True)
            s.until('manual inspection',lambda:done.exists(),900)
        # Full navigation clears state; late commands cannot start the new page.
        b('select',second);b('field',base+'/blank-navigated','go');s.until('navigation tears down reader',lambda:find(second) is None)
        action(second,'play');assert find(second) is None
        action(first,'return');b('press','13','w','cmd');s.until('closed source removed',lambda:find(first) is None)
        s.require('all readers released',state()['listeners'],0)
        third=open_page(base);start(third);b('space','transfer',third,'2');s.until('transferred source released',lambda:find(third) is None)
        s.require('transfer creates no player on replacement',state()['listeners'],0)
        video=open_page(base);start(video,'#video');quiet3=open_page(base,'/blank');assert visible(video)
        action(video,'pause');assert js(video,'document.querySelector("video").paused') is True
        action(video,'play');assert js(video,'document.querySelector("video").paused') is False
        action(video,'return');b('press','35','p','cmd','shift');s.until('PiP excludes same source',lambda:not visible(video))
        b('select',quiet3);s.require('PiP has priority',visible(video),False)
        b('press','35','p','cmd','shift');s.until('landing restores mini player',lambda:visible(video))
        action(video,'return');b('press','13','w','cmd');s.until('video cleanup',lambda:state()['listeners']==0)
        ending=open_page(base);start(ending);open_page(base,'/blank')
        js(ending,'a.loop=false;a.currentTime=9.8;true');s.until('ended removes player',lambda:find(ending) is None)
        sleeper=open_page(base);start(sleeper);open_page(base,'/blank')
        s.require('audible page cannot sleep',b('sleep',sleeper)['asleep'],False)
        action(sleeper,'pause');s.until('audio quiet before sleep',lambda:not next(t for t in s.tabs() if t['id']==sleeper)['noisy'])
        s.require('paused page can sleep',b('sleep',sleeper)['asleep'],True)
        s.require('sleep releases reader',state()['listeners'],0)
        b('select',sleeper);b('wait',sleeper,'10');s.require('wake does not revive controls',find(sleeper),None)
        denied=open_page(base);start(denied);open_page(base,'/blank');action(denied,'pause')
        js(denied,"a.play=()=>Promise.reject(new Error('synthetic refusal'));true")
        action(denied,'play');assert find(denied)['error'];assert 'play' not in find(denied)['actions'];assert js(denied,'a.paused')
        js(denied,'delete a.play;a.play();true');s.until('new playback clears rejected command',lambda:find(denied)['playing'])
        action(denied,'return');b('press','13','w','cmd');s.until('rejected-command cleanup',lambda:state()['listeners']==0)
        b('press','45','n','cmd','shift');b('field',base+'/private','go');private=next(t for t in s.tabs() if t['active']);assert private['shy']
        b('wait',private['id'],'10');start(private['id']);open_page(base,'/blank');assert visible(private['id'])
        action(private['id'],'return');b('press','13','w','cmd');s.until('private source cleanup',lambda:state()['listeners']==0)
        for _ in range(5):
            t=open_page(base);start(t);b('press','13','w','cmd');s.until('churn cleanup',lambda:state()['listeners']==0)
        framed=open_page(base,'/frame')
        s.until('iframe and unrelated main element ready',lambda:js(framed,"document.querySelector('audio').readyState>0 && document.querySelector('iframe').contentDocument.querySelector('audio')?.readyState>0"))
        b('tap',framed,'#frame-play');s.until('iframe audible',lambda:find(framed) and find(framed)['noisy'])
        frameQuiet=open_page(base,'/blank');s.until('iframe uses tab-wide controls',lambda:find(framed)['actions']==['pause'])
        action(framed,'pause');s.until('iframe actually paused',lambda:js(framed,"document.querySelector('iframe').contentDocument.querySelector('audio').paused"))
        action(framed,'dismiss');b('select',framed);b('select',frameQuiet)
        s.until('dismissed iframe does not adopt inactive main audio',lambda:find(framed) and not find(framed)['playing'] and find(framed)['actions']==[])
        js(framed,"document.querySelector('iframe').contentDocument.querySelector('audio').play();true")
        s.until('iframe restart restores pause',lambda:find(framed)['playing'] and find(framed)['actions']==['pause'])
        action(framed,'return');b('press','13','w','cmd');s.until('iframe reader cleanup',lambda:state()['listeners']==0)
        parent=open_page(base);start(parent)
        before={t['id'] for t in s.tabs()};js(parent,"window.open('/audio','_blank');true")
        s.until('popup tab created',lambda:len(s.tabs())>len(before));child=next(t['id'] for t in s.tabs() if t['id'] not in before)
        b('select',child);b('wait',child,'10');start(child);open_page(base,'/blank')
        action(parent,'pause');s.until('opener handler still active',lambda:not find(parent)['playing']);assert find(child)['playing']
        action(parent,'return');b('press','13','w','cmd');action(child,'pause');assert not find(child)['playing']
        action(child,'return');b('press','13','w','cmd');s.until('popup reader cleanup',lambda:state()['listeners']==0)
        b('space','go','1')
        final=open_page(base);start(final);open_page(base,'/blank')
        print('ok: activation, pause/resume/volume, mute, metadata, dismiss/reappear, Spaces, multiple sources, navigation, close, transfer, video/PiP, end, sleep/wake, command refusal, popup isolation, iframe fallback/restart, five churn cycles',flush=True)
    except Exception:
        print(json.dumps({'tabs':s.tabs(),'media':state()},indent=2),flush=True)
        for tab in s.tabs():
            print(tab['id'],b('eval',tab['id'],"JSON.stringify([...document.querySelectorAll('audio,video')].map(m=>({paused:m.paused,ready:m.readyState,error:m.error?.message,time:m.currentTime})))"),flush=True)
        raise
    finally:
        s.command(str(s.ROOT/'fresh.sh'),'wipe');server.shutdown();server.server_close()

if __name__=='__main__':main()
