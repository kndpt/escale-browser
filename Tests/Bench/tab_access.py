#!/usr/bin/env python3
"""Each tab is a button to VoiceOver, with Close Tab and Copy Link of its own.

Reads the app's accessibility tree from outside, as VoiceOver and Full
Keyboard Access do: SwiftUI builds it only for such a client, so the bench
cannot read it from inside. In the sidebar and then the top bar, every tab is
one button named by its title, with its state (Active, Pinned) as the value
and its context menu as its own. Its press selects it, Copy Link copies its
address (read from the announcement, as other checks may use the clipboard,
which is put back at the end) and Close Tab closes it, all without a pointer.
Needs Accessibility access for the app that runs this script (System Settings
› Privacy & Security). Not covered: Sleeping in the value (TabAccessTests),
how VoiceOver speaks it, and the Full Keyboard Access key that lists actions.
Run after ./build.sh debug; the world is owned by the shared runner and pages
are served from loopback.
"""
from functools import cache
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
import ctypes
import json
import subprocess
import suite as h

AX = ctypes.cdll.LoadLibrary('/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices')
CF = ctypes.cdll.LoadLibrary('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
REF = ctypes.c_void_p
UTF8 = 0x08000100
AX.AXIsProcessTrusted.restype = ctypes.c_bool
AX.AXUIElementCreateApplication.argtypes, AX.AXUIElementCreateApplication.restype = [ctypes.c_int], REF
AX.AXUIElementSetMessagingTimeout.argtypes = [REF, ctypes.c_float]
AX.AXUIElementCopyAttributeValue.argtypes, AX.AXUIElementCopyAttributeValue.restype = [REF, REF, ctypes.POINTER(REF)], ctypes.c_int32
AX.AXUIElementCopyActionNames.argtypes, AX.AXUIElementCopyActionNames.restype = [REF, ctypes.POINTER(REF)], ctypes.c_int32
AX.AXUIElementPerformAction.argtypes, AX.AXUIElementPerformAction.restype = [REF, REF], ctypes.c_int32
CF.CFStringCreateWithCString.argtypes, CF.CFStringCreateWithCString.restype = [REF, ctypes.c_char_p, ctypes.c_uint32], REF
CF.CFStringGetLength.argtypes, CF.CFStringGetLength.restype = [REF], ctypes.c_long
CF.CFStringGetCString.argtypes, CF.CFStringGetCString.restype = [REF, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32], ctypes.c_bool
CF.CFGetTypeID.argtypes, CF.CFGetTypeID.restype = [REF], ctypes.c_ulong
CF.CFStringGetTypeID.restype = CF.CFArrayGetTypeID.restype = ctypes.c_ulong
CF.CFArrayGetCount.argtypes, CF.CFArrayGetCount.restype = [REF], ctypes.c_long
CF.CFArrayGetValueAtIndex.argtypes, CF.CFArrayGetValueAtIndex.restype = [REF, ctypes.c_long], REF


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        body = f'<title>{self.path[1:]}</title><h1>{self.path}</h1>'.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def bench(*args):
    return json.loads(h.command(str(h.ROOT / 'bench'), '--world', h.WORLD, '--json', *map(str, args)))


# The objects read below live as long as this short script; none is released.
@cache
def text(value):
    return CF.CFStringCreateWithCString(None, value.encode(), UTF8)


def python(value):
    if not value:
        return None
    if CF.CFGetTypeID(value) == CF.CFStringGetTypeID():
        size = CF.CFStringGetLength(value) * 4 + 1
        buffer = ctypes.create_string_buffer(size)
        return buffer.value.decode() if CF.CFStringGetCString(value, buffer, size, UTF8) else None
    if CF.CFGetTypeID(value) == CF.CFArrayGetTypeID():
        return [CF.CFArrayGetValueAtIndex(value, i) for i in range(CF.CFArrayGetCount(value))]
    return value


def attribute(element, name):
    out = REF()
    if AX.AXUIElementCopyAttributeValue(element, text(name), ctypes.byref(out)):
        return None
    return python(out.value)


def actions(element):
    out = REF()
    if AX.AXUIElementCopyActionNames(element, ctypes.byref(out)):
        return []
    return [python(name) for name in python(out.value) or []]


def app():
    lines = subprocess.run(['ps', '-axo', 'pid=,comm='], capture_output=True, text=True, timeout=5).stdout
    pid = next(int(line.split(None, 1)[0]) for line in lines.splitlines()
               if line.split(None, 1)[1:] == [h.BINARY])
    element = AX.AXUIElementCreateApplication(pid)
    AX.AXUIElementSetMessagingTimeout(element, 5.0)
    return element


def labelled(root, title):
    """Every element of the window named `title`, the window itself and pages left out."""
    found = []

    def walk(element, depth):
        role = attribute(element, 'AXRole')
        if role == 'AXWebArea' or depth > 60:
            return
        if role != 'AXWindow' and title in (attribute(element, 'AXDescription'), attribute(element, 'AXTitle')):
            found.append({'element': element, 'role': role, 'value': attribute(element, 'AXValue') or '',
                          'actions': actions(element)})
        for child in attribute(element, 'AXChildren') or []:
            walk(child, depth + 1)

    for window in attribute(root, 'AXWindows') or []:
        walk(window, 0)
    return found


def offered(found, action):
    """An action by the name VoiceOver lists; a custom one carries its target too."""
    return next((n for n in found['actions'] if n == action or n.startswith(f'Name:{action}\n')), None)


def tab(root, title):
    """The one element for a tab, once the layout has drawn it. The address
    bar's button can bear the same title; only a tab offers Close Tab."""
    def one():
        found = [f for f in labelled(root, title) if offered(f, 'Close Tab')]
        return found[0] if len(found) == 1 else None
    return h.until(f'one tab element for {title}', one, 15)


def perform(found, action):
    name = offered(found, action)
    h.require(f'{action} offered', name is not None, True)
    h.require(f'{action} performed', AX.AXUIElementPerformAction(found['element'], text(name)), 0)


def state(ident):
    return next(({'active': t['active'], 'pin': t['pin']} for t in h.tabs() if t['id'] == ident), None)


def exercise(root, origin, layout):
    names = [f'{layout}-pinned', f'{layout}-first', f'{layout}-second']
    ids = {name: h.open_ordinary(f'{origin}/{name}') for name in names}
    pinned, first, second = names
    bench('pin', ids[pinned], 'on')
    bench('select', ids[second])
    for name in names:
        found = tab(root, name)
        h.require(f'{layout}: {name} is a button', found['role'], 'AXButton')
        h.require(f'{layout}: {name} offers Copy Link', offered(found, 'Copy Link') is not None, True)
        h.require(f'{layout}: {name} keeps its menu', offered(found, 'AXShowMenu') is not None, True)
    h.until(f'{layout}: the tab on screen says so', lambda: tab(root, second)['value'] == 'Active', 10)
    h.until(f'{layout}: the pin says so', lambda: tab(root, pinned)['value'] == 'Pinned', 10)
    h.require(f'{layout}: an ordinary tab has no state', tab(root, first)['value'], '')

    perform(tab(root, first), 'AXPress')
    h.wait_for(f'{layout}: its press selects it', lambda: state(ids[first]), {'active': True})

    url = f'{origin}/{second}'
    perform(tab(root, second), 'Copy Link')
    h.wait_for(f'{layout}: Copy Link copies its address',
               lambda: {'said': bench('probe')['announcement']}, {'said': f'Link copied: {url}'})
    h.require(f'{layout}: Copy Link leaves the tab where it was', state(ids[second])['active'], False)

    perform(tab(root, second), 'Close Tab')
    h.until(f'{layout}: Close Tab closes it', lambda: state(ids[second]) is None, 10)


def main():
    if not AX.AXIsProcessTrusted():
        raise AssertionError('this script needs Accessibility access for the app that runs it '
                             '(System Settings › Privacy & Security › Accessibility)')
    server = ThreadingHTTPServer(('127.0.0.1', 0), Page)
    Thread(target=server.serve_forever, daemon=True).start()
    origin = f'http://127.0.0.1:{server.server_port}'
    kept = subprocess.run(['pbpaste'], capture_output=True, text=True, timeout=5).stdout
    try:
        with h.world(server):
            h.launch()
            bench('resize', 1180, 800)
            root = app()
            bench('ui', 'sidebar', 'on')
            exercise(root, origin, 'side')
            bench('ui', 'sidebar', 'off')
            exercise(root, origin, 'top')
            print('PASS: every tab is a button with Close Tab and Copy Link, in the sidebar and the top bar')
    finally:
        subprocess.run(['pbcopy'], input=kept, text=True, timeout=5)


if __name__ == '__main__':
    main()
