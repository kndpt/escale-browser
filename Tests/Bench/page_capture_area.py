#!/usr/bin/env python3
"""Select Area for captures, with real AppKit mouse events in an owned world.

A rectangle is dragged over the visible page and captured the moment it is
let go; the PNG is decoded and its corners compared with the element the
rectangle was laid over, so an offset of a couple of points shows. Escape and
tab changes end the selection without an image, and the page never sees a
pointer, mouse or selection event during the gesture. Exports go to /tmp only.
"""
from pathlib import Path
from threading import Thread
from http.server import ThreadingHTTPServer
import json
import struct
import sys
import tempfile
import time
import zlib
import page_data_tools as p
import page_visual_tools as v
import suite as h

BLUE = (20, 120, 210)


def decode(data):
    """Rows of an 8-bit, non-interlaced RGB(A) PNG, without a library."""
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    pos, idat = 8, b''
    while pos < len(data):
        (size,) = struct.unpack('>I', data[pos:pos + 4])
        kind, body = data[pos + 4:pos + 8], data[pos + 8:pos + 8 + size]
        pos += 12 + size
        if kind == b'IHDR':
            width, height, depth, colour, _, _, interlace = struct.unpack('>IIBBBBB', body)
        elif kind == b'IDAT':
            idat += body
    assert depth == 8 and colour in (2, 6) and interlace == 0, (depth, colour, interlace)
    bpp = 4 if colour == 6 else 3
    raw, stride, rows, prev, at = zlib.decompress(idat), width * bpp, [], bytearray(width * bpp), 0
    for _ in range(height):
        kind, line = raw[at], bytearray(raw[at + 1:at + 1 + stride])
        at += 1 + stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if kind == 1: line[x] = (line[x] + a) & 255
            elif kind == 2: line[x] = (line[x] + b) & 255
            elif kind == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif kind == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line)
        prev = line
    return width, height, lambda x, y: tuple(rows[y][x * bpp:x * bpp + 3])


def near(colour, expected, slack=14):
    return all(abs(a - b) <= slack for a, b in zip(colour, expected))


def area(tab):
    return p.ask('page-capture', id=tab)['area']


def draw(start, end):
    # Live: every event, press included, goes through AppKit. Events handed to
    # the hit view directly never begin a SwiftUI DragGesture on macOS 26.5.1.
    p.ask('drag', x=start[0], y=start[1], toX=end[0], toY=end[1], live=True)


def draw_area(tab, start, end):
    """Drag a rectangle once; a drag that draws nothing fails with what it saw.

    A press that reaches the layer before SwiftUI has mounted it would draw
    nothing (seen only in long ./verify campaigns). Whether that is the
    harness or a real defect of Select Area is not established, so the drag is
    never made again: a retry would pass over the defect. The area and the page
    frame go to stderr, where the next failure leaves its evidence.
    """
    draw(start, end)
    state = area(tab)
    if state['active']:
        print(f'select area: the drag drew nothing: area={state} page={p.ask("probe")["pageFrame"]}', file=sys.stderr)
        raise AssertionError(f'the drag captured no rectangle: {state}')


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), v.Page)
    Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    # The shared runner owns the world, its bundle snapshot and its cleanup.
    with h.world(server):
        h.launch()
        p.WORLD = h.WORLD
        p.ask('ui', welcome=False)
        p.ask('resize', width=1100, height=800)
        tab = p.ask('open', url=base)['id']
        p.ask('select', id=tab)
        p.ask('wait', id=tab, seconds=15)
        v.js(tab, "window.seen=[];for(const t of ['pointerdown','pointerup','mousedown','mouseup','click','selectstart','dragstart','contextmenu'])"
                  "window.addEventListener(t,e=>window.seen.push(t),true);true")

        def element_box():
            """The link's box in the web view's points, from the inspection card."""
            p.ask('visual-pick', id=tab, action='start')
            p.ask('tap', id=tab, selector='#target')
            box = v.selected(tab)['anchor']
            p.ask('visual-pick', id=tab, action='stop')
            v.js(tab, 'window.seen.length=0;true')
            return box

        # Where the page sits in the window, from the window's own state.
        frame = p.ask('probe')['pageFrame']
        origin = (frame[0], frame[1])
        p.ask('page-capture', id=tab, action='area', step='start')
        state = area(tab)
        assert state['active'] and not state['ready'] and state['rect'] == [], state
        # Escape: no image, no page change.
        p.ask('press', code=53, chars='\x1b')
        p.until('escape ends selection', lambda: not area(tab)['active'])
        assert not p.ask('page-capture', id=tab)['shown']
        # A click without a drag draws and captures nothing, and keeps waiting.
        p.ask('page-capture', id=tab, action='area', step='start')
        draw((500, 300), (503, 302))
        time.sleep(.3)
        assert area(tab)['active'] and area(tab)['rect'] == [] and not p.ask('page-capture', id=tab)['shown'], area(tab)
        p.ask('page-capture', id=tab, action='area', step='stop')

        with tempfile.TemporaryDirectory(prefix='escale-area-', dir='/tmp') as folder:
            def capture_element(name):
                box = element_box()
                p.ask('page-capture', id=tab, action='area', step='start')
                draw_area(tab, (origin[0] + box['x'], origin[1] + box['y']),
                          (origin[0] + box['x'] + box['width'], origin[1] + box['y'] + box['height']))
                # Let go: captured at once, with no step in between.
                state = v.captured(tab)
                assert not area(tab)['active'] and 'Area:' in state['context'], state
                path = Path(folder) / f'{name}.png'
                p.ask('page-capture', id=tab, path=str(path))
                width, height, pixel = decode(path.read_bytes())
                assert abs(width - box['width']) <= 1.5 and abs(height - box['height']) <= 1.5, (width, height, box)
                # The rectangle was laid on the blue link: its corners and edges are blue.
                for x, y in [(2, 2), (width - 3, 2), (2, height - 3), (width - 3, height - 3), (2, height // 2), (width - 3, height // 2)]:
                    assert near(pixel(x, y), BLUE), (name, x, y, pixel(x, y))
                p.ask('page-capture', id=tab, action='close')
                return width, height

            sizes = {'100': capture_element('normal')}
            for code, chars, name in [(24, '+', 'zoomed-in'), (27, '-', 'zoomed-out')]:
                p.ask('press', code=code, chars=chars, mods=['cmd'])
                time.sleep(.3)
                sizes[name] = capture_element(name)
            assert sizes['zoomed-in'][0] > sizes['100'][0], sizes

        # Another tab ends the selection.
        other = p.ask('open', url=base)['id']
        p.ask('wait', id=other, seconds=15)
        p.ask('page-capture', id=tab, action='area', step='start')
        assert area(tab)['active']
        p.ask('select', id=other)
        assert not area(tab)['active'] and area(tab)['rect'] == [], area(tab)
        p.ask('select', id=tab)
        assert not area(tab)['active'] and not p.ask('page-capture', id=tab)['shown']

        # None of it reached the page.
        assert v.js(tab, 'window.seen.length') == 0, v.js(tab, 'JSON.stringify(window.seen)')
        assert v.js(tab, "getSelection().toString()") == ''
        print(json.dumps({'result': 'PASS', 'sizes': sizes}))


if __name__ == '__main__':
    main()
