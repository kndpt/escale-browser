#!/usr/bin/env python3
"""Check the sidebar/PiP round trip with a synthetic video in real WebKit.

Only this focused journey runs: source targeting, paused playback, parked tabs
and restoration without another page. INSPECT retains the owned test world for
native button inspection; no account or external media is involved.
"""
import json
import os
from pathlib import Path
from http.server import ThreadingHTTPServer
from threading import Thread
import media_player as m


def main():
    s,b=m.s,m.b
    server=ThreadingHTTPServer(('127.0.0.1',0),m.Page)
    Thread(target=server.serve_forever,daemon=True).start()
    base=f'http://127.0.0.1:{server.server_port}'
    try:
        s.command(str(s.ROOT/'fresh.sh'),'wipe')
        s.command('defaults','write',s.SUITE,'bench','-bool','YES');s.launch()
        b('ui','welcome','off');b('ui','sidebar','on');b('ui','spaces','on');b('resize','1100','760')
        audio=m.open_page(base);m.start(audio)
        s.require('audio has no video action',m.find(audio)['video'],False)
        m.action(audio,'float');s.require('audio cannot float',m.state()['floating'],None)
        video=m.open_page(base);m.start(video,'#video')
        s.until('video capability',lambda:m.find(video)['video'])
        quiet=m.open_page(base,'/blank')

        def roundtrip(paused=False):
            active=next(t for t in s.tabs() if t['active'])['id']
            pages=b('space')['pages']
            m.action(video,'float')
            s.until('selected video floats',lambda:(m.state()['floating'] or '').lower().startswith(video.lower()))
            s.require('floating source excluded',m.visible(video),False)
            s.require('correct DOM isolated',m.js(video,"document.querySelector('#film').hasAttribute('data-escale-float')"),True)
            s.require('same playback state in PiP',m.js(video,"document.querySelector('#film').paused"),paused)
            s.require('same active page',next(t for t in s.tabs() if t['active'])['id'],active)
            m.action(video,'minimize')
            s.until('mini player restored',lambda:m.visible(video) and m.state()['floating'] is None)
            s.until('DOM restored',lambda:not m.js(video,"document.documentElement.classList.contains('escale-floating')"))
            s.require('restored selected source',m.state()['selected'].lower().startswith(video.lower()),True)
            s.require('unchanged playback',m.js(video,"document.querySelector('#film').paused"),paused)
            s.require('same active page after return',next(t for t in s.tabs() if t['active'])['id'],active)
            s.require('no page created',b('space')['pages'],pages)
            s.require('no isolation timer',m.js(video,'window.__escaleFloatWatch === null'),True)

        roundtrip()
        m.action(video,'pause');s.until('paused',lambda:not m.find(video)['playing']);roundtrip(True)
        m.action(video,'play');s.until('resumed',lambda:m.find(video)['playing'])
        b('space','new','PiP destination');m.open_page(base,'/blank-other-space');roundtrip()
        m.action(video,'return');roundtrip()
        m.action(video,'return');s.require('source return hides minimized active source',m.visible(video),False)
        b('select',quiet)
        if os.environ.get('INSPECT'):
            done=Path('/tmp/escale-pip-inspect-done');done.unlink(missing_ok=True)
            Path('/tmp/escale-pip-inspect.json').write_text(json.dumps({'world':s.WORLD,'video':video,'audio':audio,'binary':s.BINARY}))
            print('inspect /tmp/escale-pip-inspect.json; finish with /tmp/escale-pip-inspect-done',flush=True)
            s.until('native inspection',done.exists,900)
        print('PASS: video-only PiP, playing/paused round trip, other Space, active source, same page and playback',flush=True)
    finally:
        server.shutdown();server.server_close()
        s.command(str(s.ROOT/'fresh.sh'),'wipe')


if __name__=='__main__':main()
