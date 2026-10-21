#!/usr/bin/env python3
"""A page's alert and confirm loop, stopped from its sheet.

A page asks alert() a thousand times, then confirm() until it is told no.
Its first sheet offers no way out, its second offers to stop the page; once
that box is ticked the loop ends at once and the tab still answers: confirm
says no and prompt gives nothing, without a sheet. Reloaded, the page asks
as a new one. Another tab still shows its own question, and a tab behind
another asks nobody until it is shown.

Sheets are read and pressed through the bench's `sheet` command, the
buttons' own action, so no real pointer or key is needed. Not covered: the
checkbox ticked by a real click, a page in the floating window, and a
`while (true) alert()` loop, which keeps its page busy once stopped. Run
after ./build.sh debug; the world is owned by the shared runner and pages are
served from loopback.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
import json
import time
import suite as h

LOOP = """<script>
window.run = () => setTimeout(() => {
  for (let i = 0; i < 1000; i++) alert('alert ' + i);
  let yes = 0;
  while (confirm('again?')) yes++;
  document.title = 'done ' + yes;
}, 0);
</script>"""
# Asked the moment its tab is left, so the page is out of the window then.
BEHIND = """<script>
document.addEventListener('visibilitychange', () => {
  if (!document.hidden || !window.armed) return;
  window.armed = false;
  alert('behind');
  document.title = 'answered';
});
</script>"""


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip('/').split('?')[0]
        body = (f'<title>{name}</title><h1>{name}</h1>' + {'loop': LOOP, 'behind': BEHIND}.get(name, '')).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def bench(*args):
    return json.loads(h.command(str(h.ROOT / 'bench'), '--world', h.WORLD, '--json', *map(str, args)))


def row(ident):
    return next(t for t in h.tabs() if t['id'] == ident)


def title(ident):
    return row(ident)['title']


def asked(text, stop):
    """The sheet showing `text`, offering to stop the page or not."""
    sheet = h.until(f'a sheet saying "{text}"',
                    lambda: (lambda s: s if s.get('shown') and text in s['texts'] else None)(bench('sheet')), 15)
    h.require(f'"{text}" offers to stop the page', sheet['stop'], stop)
    return sheet


def no_sheet(what, seconds=1.5):
    """Nothing asked over the window for a while: a negative needs a span."""
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        h.require(what, bench('sheet')['shown'], False)
        time.sleep(0.15)


def stop_loop(ident, done):
    """The loop's first sheet without the box, its second with it ticked."""
    h.ask('eval', id=ident, js='run(); true')
    asked('alert 0', False)
    bench('sheet', 'press', 'OK')
    asked('alert 1', True)
    bench('sheet', 'press', 'OK', 'stop')
    h.until(f'the loop to end ({done})', lambda: title(ident) == done, 15)
    h.require('no sheet after the loop', bench('sheet')['shown'], False)


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Page)
    Thread(target=server.serve_forever, daemon=True).start()
    origin = f'http://127.0.0.1:{server.server_port}'
    with h.world(server):
        h.launch()
        loop = h.open_ordinary(origin + '/loop')
        other = h.open_ordinary(origin + '/other')
        behind = h.open_ordinary(origin + '/behind')

        h.ask('select', id=loop)
        stop_loop(loop, 'done 0')
        quiet = h.ask('eval', id=loop, js="[confirm('c'), prompt('p'), typeof alert('a')]")
        h.require('a stopped page is answered at once', quiet.get('value'), [False, None, 'undefined'])
        no_sheet('a stopped page asks nobody', 0.5)
        print('ok: the loop stops once the box is ticked; the tab still answers', flush=True)

        h.ask('eval', id=loop, js='location.reload(); true')
        h.until('the page again', lambda: title(loop) == 'loop', 15)
        stop_loop(loop, 'done 0')
        print('ok: a new page asks again, from a sheet without the box', flush=True)

        h.ask('select', id=other)
        h.ask('eval', id=other, js="setTimeout(() => { document.title = 'answered ' + confirm('other?') }, 0); true")
        asked('other?', False)
        bench('sheet', 'press', 'OK')
        h.until('the other tab answered', lambda: title(other) == 'answered true', 15)
        print('ok: another tab still asks', flush=True)

        h.ask('select', id=behind)
        h.ask('eval', id=behind, js='armed = true')
        h.ask('select', id=other)
        # The page's own title waits with it: the question is seen held.
        h.until('the tab behind to ask', lambda: row(behind)['held'] == 1, 15)
        no_sheet('a tab behind asks nobody')
        h.ask('select', id=behind)
        asked('behind', False)
        bench('sheet', 'press', 'OK')
        h.until('the tab behind answered', lambda: title(behind) == 'answered', 15)
        h.require('nothing left held', row(behind)['held'], 0)
        print('PASS: an alert and confirm loop stopped from its sheet, a new page and another tab ask again, '
              'a tab behind waits until shown')


if __name__ == '__main__':
    main()
