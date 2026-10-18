#!/usr/bin/env python3
"""View Page Source shows the main resource as the server sent it.

An owned probe world serves local pages whose script rewrites their DOM.
⌥⌘U, a real key press, and `view-source:` typed in the address field must each
open Web Inspector, docked, on the page's main resource, and its text must be
the server's HTML, not the DOM the script left. The view is read from the
inspector frontend's own model (`WI.*`), not from pixels. No Internet page,
extension or installed browser participates.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
import json
import time
import suite as s

# The script writes a word the HTML never spells out.
PAGE = ("<title>{path}</title><p id='m'>sent-by-server {path}</p>"
        "<script>document.getElementById('m').textContent = 'changed-' + 'by-script'</script>")

# What the inspector shows: its tab, the resource on screen, and its text.
SHOWN = """(() => {
  const tab = WI.tabBrowser.selectedTabContentView;
  const view = tab && tab.contentBrowser && tab.contentBrowser.currentContentView;
  const main = WI.networkManager.mainFrame && WI.networkManager.mainFrame.mainResource;
  const text = view && view.responseContentView && view.responseContentView.textEditor
    && view.responseContentView.textEditor.string;
  return JSON.stringify({tab: tab && tab.type, url: view && view.representedObject && view.representedObject.url,
    main: !!main && view && view.representedObject === main, text: text || ''});
})()"""


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('/slow'):
            time.sleep(3)
        body = PAGE.format(path=self.path).encode()
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


def active():
    return next(t['id'] for t in s.tabs() if t['active'])


def shown(tab):
    answer = bench('calls', tab, json.dumps({'action': 'frontend', 'js': SHOWN}))
    return json.loads(answer['value']) if isinstance(answer.get('value'), str) else {}


def docked():
    return len(bench('probe').get('inspectorFrames') or []) == 1


def expect_source(what, tab, path):
    def ready():
        seen = shown(tab)
        return seen.get('main') and seen.get('url', '').endswith(path) and 'sent-by-server ' + path in seen.get('text', '')
    try:
        s.until(what, lambda: ready() and docked(), 10)
    except s.WaitExpired as error:
        raise AssertionError(f'{what}: {shown(tab)}, inspectors {bench("probe").get("inspectorFrames")}') from error
    seen = shown(tab)
    assert 'changed-by-script' not in seen['text'], seen
    assert bench('eval', tab, "document.getElementById('m').textContent")['value'] == 'changed-by-script'
    print(f'ok: {what}: {seen["url"]} in the {seen["tab"]} tab', flush=True)


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Page)
    Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    with s.world(server):
        s.launch()
        bench('resize', '1400', '850')
        bench('bookmark', f'{base}/first', 'new')
        first = active()
        loaded = bench('wait', first, '10')
        assert not loaded.get('timeout') and not loaded.get('failure') and not loaded['loading'], loaded

        bench('press', '32', 'u', 'cmd', 'opt')
        expect_source('⌥⌘U shows the HTML the server sent', first, '/first')

        bench('press', '34', 'i', 'cmd', 'opt')
        s.until('⌥⌘I closes it', lambda: not bench('probe').get('inspectorFrames'), 5)
        bench('field', f'view-source:{base}/second', 'go')
        expect_source('view-source: loads the address, then shows its HTML', first, '/second')

        # A source request replaced before its page arrives goes with it.
        bench('press', '34', 'i', 'cmd', 'opt')
        s.until('⌥⌘I closes it again', lambda: not bench('probe').get('inspectorFrames'), 5)
        bench('field', f'view-source:{base}/slow', 'go')
        bench('field', f'{base}/third', 'go')
        loaded = bench('wait', first, '10')
        assert not loaded.get('timeout') and not loaded.get('failure'), loaded
        time.sleep(4)
        assert not bench('probe').get('inspectorFrames'), 'a replaced view-source: opened the inspector'
        print('ok: a view-source: replaced before it loads opens nothing', flush=True)


if __name__ == '__main__':
    main()
