#!/usr/bin/env python3
"""Web Inspector follows its page, however it was opened, and leaves no gap.

An owned probe world serves two local pages and a playing canvas video. The
inspector is opened from the page's right-click menu (WebKit's own Inspect
Element item) and with ⌥⌘I, then taken through tab and Space switches, a
window of its own, a floating video and each way of closing it. After every
step the page is checked against its stage (`probe`): docked, the page and
one inspector view share the stage; closed, the page fills it alone. Docked
bottom, split view, sleep and full screen are not replayed here. No Internet
page, extension or installed browser participates.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
import json
import suite as s

VIDEO = ("<video muted autoplay playsinline width=480 height=270></video><canvas width=160 height=90></canvas>"
         "<script>const c=document.querySelector('canvas'),x=c.getContext('2d');let n=0;"
         "setInterval(()=>{x.fillStyle='hsl('+(n++%360)+',60%,50%)';x.fillRect(0,0,160,90)},40);"
         "const v=document.querySelector('video');v.srcObject=c.captureStream(25);v.play()</script>")


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        body = ("<title>" + self.path + "</title><body style='margin:0;background:#547f91;height:3000px'>"
                "<h1>" + self.path + "</h1>" + (VIDEO if self.path == "/video" else "") + "</body>").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def bench(*args):
    return json.loads(s.command(str(s.ROOT / 'bench'), '--world', s.WORLD, '--json', *map(str, args)))


def tab(path):
    return next(t['id'] for t in s.tabs() if t['url'].endswith(path))


def frontend(id, script):
    return bench('calls', id, json.dumps({'action': 'frontend', 'js': script}))


def near(a, b):
    return abs(a - b) <= 1


def layout():
    probe = bench('probe')
    return probe.get('pageFrame'), probe.get('stageFrame'), probe.get('inspectorFrames')


def full():
    page, stage, inspectors = layout()
    return bool(page and stage) and inspectors == [] and all(map(near, page, stage))


def docked():
    """The page at the stage's left, one inspector at its right, no gap."""
    page, stage, inspectors = layout()
    if not (page and stage and inspectors and len(inspectors) == 1):
        return False
    inspector = inspectors[0]
    return (page[2] < stage[2] - 100 and near(page[0], stage[0]) and near(page[3], stage[3])
            and near(inspector[0], page[0] + page[2]) and near(page[2] + inspector[2], stage[2]))


def expect(what, condition):
    try:
        s.until(what, condition, 5)
    except s.WaitExpired as error:
        raise AssertionError(f'{what}: page, stage, inspectors = {layout()}') from error
    print(f'ok: {what}', flush=True)


def inspect_from_menu():
    page = layout()[0]
    menu = bench('pointer', 'menu', page[0] + 60, page[1] + page[3] - 60)
    titles = [item['title'] for item in menu['items']]
    assert 'Inspect Element' in titles, menu
    bench('pointer', 'choose', titles.index('Inspect Element'))


def toggle():
    bench('press', '34', 'i', 'cmd', 'opt')


def floating():
    return any(w['kind'] == 'Panel' and w['visible'] for w in bench('probe')['windows'])


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Page)
    Thread(target=server.serve_forever, daemon=True).start()
    with s.world(server):
        s.launch()
        bench('resize', '1400', '850')
        for path in ('/first', '/second', '/video'):
            bench('bookmark', f'http://127.0.0.1:{server.server_port}{path}', 'new')
            loaded = bench('wait', tab(path), '10')
            assert not loaded.get('timeout') and not loaded.get('failure') and not loaded['loading'], loaded
        first, second = tab('/first'), tab('/second')
        bench('select', first)
        expect('a page alone fills its stage', full)

        inspect_from_menu()
        expect('right-click › Inspect Element docks it at the right', docked)
        assert bench('calls', first)['inspection']['session'] is True, 'the menu bypassed InspectorSession'
        bench('select', second)
        expect('it follows to the next tab', docked)
        bench('select', first)
        expect('and back, with its inspector beside it, not an empty gap', docked)

        bench('space', 'new', 'Other')
        bench('space', 'go', '1')
        bench('select', tab('/first'))
        expect('it is beside the page again after a Space switch', docked)

        first = tab('/first')
        frontend(first, "InspectorFrontendHost.requestSetDockSide('undocked'), 1")
        expect('in a window of its own, the page fills the stage', full)
        toggle()
        expect('⌥⌘I closes it', lambda: full() and bench('calls', first)['inspection']['visible'] is False)
        toggle()
        expect('⌥⌘I docks it again though WebKit last left it detached', docked)
        frontend(first, 'InspectorFrontendHost.closeWindow(), 1')
        expect('its own ✕ gives the page the whole stage', full)

        video = tab('/video')
        bench('select', video)
        s.until('the video plays', lambda: bench('eval', video, "!document.querySelector('video').paused")['value'], 5)
        toggle()
        expect('⌥⌘I docks it beside the video page', docked)
        bench('press', '35', 'p', 'cmd', 'shift')
        s.until('the video floats', floating, 5)
        assert bench('calls', video)['inspection']['visible'] is False, 'the inspector stayed behind a floating page'
        bench('press', '35', 'p', 'cmd', 'shift')
        s.until('the video lands', lambda: not floating(), 5)
        expect('the landed page fills the stage', full)
        print('ok: right-click and ⌥⌘I inspectors follow tabs and Spaces and close without a gap', flush=True)


if __name__ == '__main__':
    main()
