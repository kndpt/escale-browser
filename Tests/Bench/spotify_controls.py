#!/usr/bin/env python3
"""Exercise Spotify's DOM fallback in real WebKit with synthetic Web Audio.

The bench loads local HTML at Spotify's origin, without fetching its page or
using an account. This checks our adapter and native wiring, not the live site's
markup or DRM. INSPECT retains this owned world for native hover/control review.
"""
import json
import os
from pathlib import Path
import media_player as m

HTML = r'''<!doctype html><title>Spotify control fixture</title>
<style>body{font:20px system-ui;background:#fff;color:#222;padding:40px}button{padding:20px;margin:10px}input{width:250px}</style>
<h1>Synthetic Spotify controls — no account</h1>
<button id="start" onclick="start()">Start synthetic audio</button>
<button data-testid="control-button-skip-back" onclick="previous()">Previous</button>
<button data-testid="control-button-playpause" aria-label="Play" onclick="toggle()">Play/pause</button>
<button data-testid="control-button-skip-forward" onclick="next()">Next</button>
<label>Volume <input data-testid="volume-bar" aria-label="Volume" type="range" min="0" max="1" step="0.01" value="0.5" oninput="volume(this.value)"></label>
<span data-testid="playback-position">0:00</span>
<script>
let context, gain, playing=false, track=1, level=.5;
window.fixtureRefuse=false;
function metadata(){navigator.mediaSession.metadata=new MediaMetadata({title:'Synthetic track '+track,artist:'Fixture artist'});document.title='Synthetic track '+track;}
function volume(value){level=Number(value);if(gain)gain.gain.value=playing?level*.03:0;}
function reflect(){
 document.querySelector('[data-testid="control-button-playpause"]').setAttribute('aria-label',playing?'Pause':'Play');
 navigator.mediaSession.playbackState=playing?'playing':'paused';volume(level);
}
function start(){
 if(!context){context=new AudioContext();gain=context.createGain();gain.connect(context.destination);const tone=context.createOscillator();tone.frequency.value=220;tone.connect(gain);tone.start();}
 context.resume();playing=true;metadata();reflect();
}
function toggle(){if(!window.fixtureRefuse){playing=!playing;reflect();}}
function next(){if(!window.fixtureRefuse){track++;metadata();}}
function previous(){if(!window.fixtureRefuse){const pos=document.querySelector('[data-testid="playback-position"]');if(pos.textContent!=='0:00')pos.textContent='0:00';else{track--;metadata();}}}
window.fixtureState=()=>({playing,track,level,amplitude:gain?.gain.value,mediaElements:document.querySelectorAll('audio,video').length});
</script>'''


def fixture():
    m.b('bookmark', 'about:blank', 'new')
    tab = next(t for t in m.s.tabs() if t['active'])['id']
    m.b('media', tab, json.dumps({'action':'fixture','base':'https://open.spotify.com/','html':HTML}))
    m.s.until('fixture ready', lambda: m.js(tab, "typeof window.fixtureState === 'function'"))
    m.s.require('real Spotify origin', m.js(tab, 'location.hostname'), 'open.spotify.com')
    m.b('tap', tab, '#start')
    m.s.until('Spotify DOM controls discovered', lambda: m.find(tab) and m.find(tab)['key'].startswith('spotify:'))
    m.s.require('all observed controls', set(m.find(tab)['actions']), {'pause','previous','next','volume'})
    m.s.require('no HTML media element', m.js(tab, 'fixtureState().mediaElements'), 0)
    return tab


def main():
    s,b=m.s,m.b
    try:
        s.command(str(s.ROOT/'fresh.sh'),'wipe')
        s.command('defaults','write',s.SUITE,'bench','-bool','YES')
        s.launch()
        b('ui','welcome','off');b('ui','sidebar','on');b('ui','size','standard');b('resize','1100','760')
        first=fixture()
        b('bookmark','about:blank','new')
        s.until('background player visible',lambda:m.visible(first))
        m.action(first,'pause')
        s.until('pause stops actual output',lambda:m.js(first,'fixtureState().amplitude')==0)
        s.until('paused DOM controls retained',lambda:m.find(first) and 'play' in m.find(first)['actions'])
        m.action(first,'play')
        s.until('play restores output',lambda:m.js(first,'fixtureState().amplitude')>0)
        m.action(first,'volume',value=.3)
        s.require('volume affects output',round(m.js(first,'fixtureState().amplitude'),3),.009)
        m.js(first,"const slider=document.querySelector('input');slider.value='.7';slider.dispatchEvent(new Event('input',{bubbles:true}));true")
        s.until('site volume changes observed',lambda:abs(m.find(first)['volume']-.7)<.01)
        m.action(first,'next');s.require('next changes track',m.js(first,'fixtureState().track'),2)
        m.action(first,'previous');s.require('previous changes track',m.js(first,'fixtureState().track'),1)
        m.js(first,"document.querySelector('[data-testid=playback-position]').textContent='0:42';true")
        m.action(first,'previous');s.require('previous restarts same track',m.js(first,"document.querySelector('[data-testid=playback-position]').textContent"),'0:00')
        s.require('previous stays available','previous' in m.find(first)['actions'],True)
        m.js(first,"document.querySelector('[data-testid=control-button-skip-forward]').disabled=true;true")
        s.until('disabled next disappears',lambda:'next' not in m.find(first)['actions'])
        m.js(first,"document.querySelector('[data-testid=control-button-skip-forward]').disabled=false;true")
        s.until('enabled next returns',lambda:'next' in m.find(first)['actions'])
        m.js(first,'window.fixtureRefuse=true;true');m.action(first,'next')
        s.require('refused command withheld','next' in m.find(first)['actions'],False)
        s.require('refused command reported',bool(m.find(first)['error']),True)
        m.js(first,'window.fixtureRefuse=false;toggle();true')
        s.until('external pause observed',lambda:not m.find(first)['playing'])
        m.js(first,'toggle();true')
        s.until('restart restores controls',lambda:'next' in m.find(first)['actions'])
        m.js(first,"document.querySelector('[data-testid=control-button-playpause]').disabled=true;true")
        s.until('unavailable site controls use only public fallback',
                lambda:m.find(first) and m.find(first)['key']=='' and set(m.find(first)['actions']) <= {'pause'})
        m.js(first,"document.querySelector('[data-testid=control-button-playpause]').disabled=false;true")
        s.until('available player restores observed commands',lambda:set(m.find(first)['actions'])=={'pause','previous','next','volume'})
        print('ok: Web Audio discovery, native pause/resume, volume, next/previous/restart, disabled/refused commands',flush=True)
        if os.environ.get('INSPECT'):
            second=fixture();b('bookmark','about:blank','new')
            s.until('two sources',lambda:len(m.state()['visible'])==2)
            context={'world':s.WORLD,'first':first,'second':second,'binary':s.BINARY}
            Path('/tmp/escale-media-inspect.json').write_text(json.dumps(context))
            done=Path('/tmp/escale-media-inspect-done');done.unlink(missing_ok=True)
            print('inspect: /tmp/escale-media-inspect.json',flush=True)
            s.until('native UI inspection',done.exists,1200)
        m.action(first,'dismiss')
        s.require('dismiss keeps playback',m.js(first,'fixtureState().playing'),True)
        s.require('dismiss removes reader',m.js(first,'window.__escaleMedia === undefined'),True)
        print('ok: dismissal cleanup without stopping audio',flush=True)
    finally:
        s.command(str(s.ROOT/'fresh.sh'),'wipe')


if __name__=='__main__':main()
