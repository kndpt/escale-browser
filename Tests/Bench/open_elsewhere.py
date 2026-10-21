#!/usr/bin/env python3
"""Open Page In lists the other browsers, in the page's menu and the menu bar.

An owned probe world serves one local page with a link on it. A right press
on the page offers Open Page In, on the link Open Link In; the Tabs menu has
Open Page In. Each list is macOS's own, with Safari in it and no copy of
Escale, each name once. Nothing is chosen: that would open the installed
browsers, so the handoff itself and the icons are checked by hand.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
import json
import suite as s


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        body = ("<title>page</title><body style='margin:0;height:2000px'>"
                "<a href='/target' style='display:block;height:300px;background:#547f91'>link</a>page</body>").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def bench(*args):
    return json.loads(s.command(str(s.ROOT / 'bench'), '--world', s.WORLD, '--json', *map(str, args)))


def offered(x, y, title):
    menu = bench('pointer', 'menu', x, y)
    bench('pointer', 'cancel')
    item = next((item for item in menu['items'] if item['title'] == title), None)
    assert item, f'no {title}: {[item["title"] for item in menu["items"]]}'
    names = item.get('submenu', [])
    assert 'Safari' in names and 'Escale' not in names and len(names) == len(set(names)), names
    print(f'ok: {title} lists {names}', flush=True)


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Page)
    Thread(target=server.serve_forever, daemon=True).start()
    with s.world(server):
        s.launch()
        bench('resize', '1400', '850')
        s.open_ordinary(f'http://127.0.0.1:{server.server_port}/page')
        page = bench('probe')['pageFrame']
        offered(page[0] + 60, page[1] + page[3] - 60, 'Open Page In')
        offered(page[0] + 60, page[1] + 100, 'Open Link In')
        bar = bench('panels', 'menu', 'Open Page In')
        assert 'error' not in bar, bar
        print('ok: the Tabs menu has Open Page In', flush=True)


if __name__ == '__main__':
    main()
