#!/usr/bin/env python3
"""Real drags and WebKit identity, focus, limits, boundaries and split restore.

The standard runner owns a random world; all pages are synthetic loopback
documents.
Run under the shared desktop verification lock after packaging the candidate.
--require-reduced-motion refuses a disabled system setting rather than
mistaking a normal-motion run for accessibility qualification.
"""
from argparse import ArgumentParser
from http.server import ThreadingHTTPServer
from threading import Thread
import base64
import io
import json
import subprocess
import time
import wave
import suite as s


def bench(*args):
    return json.loads(s.command(str(s.ROOT / 'bench'), '--world', s.WORLD, '--json', *map(str, args)))


def active():
    return next(t for t in bench('tabs')['tabs'] if t['active'])


def short(value):
    return value[:8].lower()


def state():
    value = bench('panels')
    for group in value['groups']:
        group['members'] = list(map(short, group['members']))
        group['active'] = short(group['active'])
    for key in ('entries', 'pages'):
        for entry in value[key]:
            entry['id'] = short(entry['id'])
    return value


def page(id):
    return next(p for p in state()['pages'] if p['id'] == id)


def settled():
    previous = None; identical = 0
    def stable():
        nonlocal previous, identical
        now = state()
        current = [p.get('frame') for p in now['pages']] + [e['frame'] for e in now['entries']]
        identical = identical + 1 if current == previous else 0
        previous = current
        return identical >= 3
    s.until('native page and row geometry settles after chrome animation', stable, 5)


def point(frame):
    x, y, w, h = frame
    return x + min(w / 3, 45), y + h / 2


def target(edge):
    x, y, w, h = state()['frame']
    return {'left': (x + 12, y + h / 2), 'right': (x + w - 12, y + h / 2),
            'top': (x + w / 2, y + 12), 'bottom': (x + w / 2, y + h - 12),
            'centre': (x + w / 2, y + h / 2)}[edge]


def drag(id, edge, name, escape=False):
    print('drag:', name, flush=True)
    entry = s.until('mounted source row', lambda: next((p for p in state()['entries'] if p['id'] == id), None))
    start = point(entry['frame']); end = target(edge)
    # A hand reaches a row before it presses: without a pointer move the
    # column, after a fold and unfold, answered a press with the window-wide
    # WindowSetup host and no gesture began. Arrive first, as a hand does.
    bench('pointer', 'move', *start)
    cmd = [str(s.ROOT / 'bench'), '--world', s.WORLD, '--json', 'drag', *map(str, (*start, *end)), '2200', 'live']
    process = subprocess.Popen(cmd, cwd=s.ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        time.sleep(0.7)  # Inside the explicit 2.2-second mouse hold, never a load wait.
        if escape:
            bench('press', 53, '\x1b')
        output, error = process.communicate(timeout=15)
        assert process.returncode == 0, (output, error)
        result = json.loads(output)
        assert 'error' not in result, result
        return result
    finally:
        if process.poll() is None:
            process.terminate(); process.wait(timeout=5)


def click_page(id):
    x, y, _, _ = page(id)['frame']
    bench('hit', x + 20, y + 20, 'click', 'live')
    assert active()['id'] == id


def page_commands(a, b, base):
    print('commands: navigation, capture, inspector, audio', flush=True)
    click_page(b)
    bench('press', 37, 'l', 'cmd')
    bench('field', base + '/bravo-next', 'go')
    def loaded(path):
        result = bench('wait', b, 10)
        assert not result['loading'] and not result.get('failure') and not result.get('timeout'), result
        assert active()['url'] == base + path, active()
    loaded('/bravo-next')
    bench('press', 33, '[', 'cmd'); loaded('/bravo')
    bench('press', 30, ']', 'cmd'); loaded('/bravo-next')
    bench('eval', b, "window.beforePanelReload=true")
    bench('press', 15, 'r', 'cmd'); loaded('/bravo-next')
    assert bench('eval', b, 'typeof window.beforePanelReload')['value'] == 'undefined'
    bench('press', 33, '[', 'cmd'); loaded('/bravo')
    assert bench('eval', a, "document.querySelector('#draft').value")['value'] == 'unsent panel draft'
    for id, sibling in ((a, b), (b, a)):
        click_page(id)
        bench('press', 1, 's', 'cmd', 'opt')
        result = s.until('active panel capture finishes', lambda: (value if value['bytes'] and not value['busy'] else None)
                         if (value := bench('page-capture', id)) else None)
        assert not result['failure'] and result['shown'], result
        assert not bench('page-capture', sibling)['shown']
        bench('press', 53, '\x1b')
        assert not bench('page-capture', id)['shown']
    click_page(a); bench('press', 34, 'i', 'cmd', 'opt')
    def inspector_state():
        current = state()
        return dict(tab=short(current['inspector']), failure=current['inspectorFailure'], foreground=current['foreground'])
    s.wait_for('inspector opens for alpha', inspector_state, dict(tab=a, failure=''))
    click_page(b)
    s.wait_for('inspector follows bravo', inspector_state, dict(tab=b, failure=''))
    bench('press', 34, 'i', 'cmd', 'opt')
    s.until('inspector closes', lambda: state()['inspector'] == '')
    # A silent local WAV exercises actual playback and the active-tab pause
    # command without making noise or requesting an external media asset.
    stream = io.BytesIO()
    with wave.open(stream, 'wb') as audio:
        audio.setnchannels(1); audio.setsampwidth(2); audio.setframerate(8000)
        audio.writeframes(b'\0\0' * 4000)
    source = 'data:audio/wav;base64,' + base64.b64encode(stream.getvalue()).decode()
    for id in (a, b):
        bench('eval', id, "(()=>{const a=document.createElement('audio');a.id='panelAudio';a.loop=true;a.muted=true;a.src=" + json.dumps(source) + ";document.body.append(a);const b=document.createElement('button');b.id='panelPlay';b.textContent='Play';b.onclick=()=>a.play();document.body.prepend(b);return true})()")
        bench('tap', id, '#panelPlay')
        s.until('local audio starts', lambda: bench('eval', id, "!document.querySelector('#panelAudio').paused")['value'])
    click_page(a); bench('press', 46, 'm', 'cmd', 'shift')
    s.until('alpha audio pauses', lambda: bench('eval', a, "document.querySelector('#panelAudio').paused")['value'])
    assert not bench('eval', b, "document.querySelector('#panelAudio').paused")['value']
    for id in (a, b):
        bench('eval', id, "document.querySelector('#panelAudio').pause();document.querySelector('#panelAudio').remove();document.querySelector('#panelPlay').remove();true")


def main(require_reduced_motion=False):
    server = ThreadingHTTPServer(('127.0.0.1', 0), s.Page)
    Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    try:
        s.command(str(s.ROOT / 'fresh.sh'), 'wipe')
        s.command('defaults', 'write', s.SUITE, 'bench', '-bool', 'YES')
        s.launch()
        if require_reduced_motion:
            s.require('actual macOS Reduce Motion setting', bench('probe')['reduceMotion'], True)
        bench('ui', 'welcome', 'off'); bench('ui', 'sidebar', 'on'); bench('ui', 'spaces', 'on')
        bench('resize', 1180, 780)
        ids = []
        for name in ('alpha', 'bravo', 'charlie', 'delta'):
            bench('bookmark', base + '/' + name, 'new')
            id = active()['id']; ids.append(id)
            loaded = bench('wait', id, 10)
            assert not loaded['loading'] and not loaded.get('failure') and not loaded.get('timeout'), loaded
            bench('eval', id, f"window.panelToken='{name}';document.body.style.height='2500px';'ready'")
        a, b, c, d = ids
        names = dict(zip(ids, ('alpha', 'bravo', 'charlie', 'delta')))
        identities = {id: page(id)['page'] for id in ids}
        bench('select', a); bench('tap', a, '#draft'); bench('key', a, 'unsent panel draft')
        for edge in ('left', 'right', 'top', 'bottom'):
            bench('select', a)
            result = drag(b, edge, edge)
            assert result['heldPanels']['preview'] == edge, result
            # The carried face follows the pointer and the row steps back.
            held = result['heldPanels']
            assert held['lifted'] and short(held['carrying']) == b, held
            assert not state()['lifted'] and not state()['carrying']
            group = state()['groups'][0]
            assert group['members'] == ([b, a] if edge in ('left', 'top') else [a, b]), group
            assert group['horizontal'] == (edge in ('left', 'right')), group
            assert len([entry for entry in state()['entries'] if entry['id'] in (a, b)]) == 1
            outer = state()['frame']
            for id in (a, b):
                rect = page(id)['frame']
                assert rect[0] >= outer[0] - 1 and rect[0] + rect[2] <= outer[0] + outer[2] + 1, (outer, rect)
                assert rect[1] >= outer[1] - 1 and rect[1] + rect[3] <= outer[1] + outer[3] + 1, (outer, rect)
                assert page(id)['page'] == identities[id], (id, page(id))
                assert bench('eval', id, 'window.panelToken')['value'] == names[id]
            assert bench('eval', a, "document.querySelector('#draft').value")['value'] == 'unsent panel draft'
            # A native click into either WebKit panel retargets page commands.
            for id in (a, b):
                x, y, w, h = page(id)['frame']
                bench('hit', x + 20, y + 20, 'click', 'live')
                assert active()['id'] == id, (id, active())
                bench('press', 37, 'l', 'cmd')
                assert bench('probe')['typed'] == base + '/' + names[id]
                bench('press', 53, '\x1b')
                before = active()['zoom']
                bench('press', 24, '=', 'cmd')
                assert abs(active()['zoom'] - before * 1.1) < 0.001, active()
                bench('press', 29, '0', 'cmd')
            assert bench('sleep', a)['said'] == 'on screen'
            viewed = {id: page(id)['lastViewed'] for id in (a, b)}
            bench('panels', 'separate', b)
            assert not state()['groups']
            assert all(page(id)['lastViewed'] > viewed[id] for id in (a, b))
            s.until('focus observation ends', lambda: not state()['focusWatching'])
        # The tab on screen, carried alone, joins the one looked at before it.
        bench('select', b); bench('select', a); settled()
        result = drag(a, 'right', 'active')
        assert result['heldPanels']['preview'] == 'right', result
        group = state()['groups'][0]
        assert group['members'] == [b, a] and group['active'] == a, group
        # A composition's entry stands for several pages and is not carried.
        result = drag(a, 'left', 'group-entry')
        assert result['heldPanels']['preview'] == '' and not result['heldPanels']['lifted'], result
        assert state()['groups'][0]['members'] == [b, a], state()['groups']
        bench('panels', 'separate', a)
        assert not state()['groups']
        # Invalid centre and Escape preserve membership, page identity and order.
        bench('select', a)
        before = [t['id'] for t in bench('tabs')['tabs']]
        result = drag(b, 'centre', 'invalid')
        assert result['heldPanels']['preview'] == '' and not state()['groups'], result
        drag(b, 'right', 'cancelled', escape=True)
        assert not state()['groups']
        assert [t['id'] for t in bench('tabs')['tabs']] == before
        # Two layouts and all three interface scales use the same targets.
        for sidebar in ('on', 'off'):
            bench('ui', 'sidebar', sidebar); settled()
            for size in ('compact', 'standard', 'large'):
                bench('ui', 'size', size); bench('select', a); settled()
                result = drag(b, 'right', f'{sidebar}-{size}')
                assert result['heldPanels']['preview'] == 'right', result
                assert len(state()['groups']) == 1
                assert len([entry for entry in state()['entries'] if entry['id'] in (a, b)]) == 1
                if sidebar == 'on':
                    bench('press', 1, 's', 'cmd')
                    assert bench('probe')['folded']
                    for id in (a, b):
                        assert page(id)['page'] == identities[id]
                    bench('press', 1, 's', 'cmd')
                    assert not bench('probe')['folded']
                    settled()
                bench('panels', 'separate', a)
        bench('ui', 'size', 'standard'); bench('ui', 'sidebar', 'on'); bench('select', a); settled()
        # A linked favourite is carried from its shelf row without losing the
        # association, its existing page or its session membership.
        bench('select', c); bench('shelf', 'keep')
        bookmark = page(c)['bookmark']; assert bookmark
        bench('select', a); settled()
        result = drag(short(bookmark), 'left', 'bookmark')
        assert result['heldPanels']['preview'] == 'left', result
        assert page(c)['bookmark'] == bookmark and page(c)['page'] == identities[c]
        bench('panels', 'separate', a)
        assert page(c)['bookmark'] == bookmark
        assert bench('panels', 'add', b, a, 'right')['accepted']
        # Search stays attached to the targeted page when focus changes.
        bench('select', b); bench('press', 3, 'f', 'cmd')
        for code, char in ((0, 'a'), (37, 'l'), (35, 'p'), (4, 'h'), (0, 'a')):
            bench('press', code, char)
        def search_state():
            probe = bench('probe')
            panels = state()
            return dict(needle=probe['needle'], missed=probe['missed'], active=active()['id'],
                        finding=probe['finding'], foreground=panels['foreground'],
                        firstResponder=panels['firstResponder'])
        s.wait_for('search misses in bravo', search_state,
                   dict(needle='alpha', missed=True, active=b, finding=True, foreground=True))
        frame = page(a)['frame']
        bench('hit', frame[0] + 20, frame[1] + 20, 'click', 'live')
        assert active()['id'] == a
        bench('press', 5, 'g', 'cmd')
        s.until('search finds in alpha', lambda: not bench('probe')['missed'])
        bench('press', 53, '\x1b')
        assert not bench('probe')['finding']
        page_commands(a, b, base)
        assert bench('panels', 'add', c, a, 'right')['accepted']
        group = state()['groups'][0]
        assert not bench('panels', 'add', d, a, 'right')['accepted']
        # Real separator drag changes proportions without replacing WebKit.
        first = page(a)['frame']; x = first[0] + first[2] + 3; y = first[1] + first[3] / 2
        bench('drag', x, y, x + 60, y, 'live')
        changed = state()['groups'][0]
        assert changed['weights'] != group['weights'], (group, changed)
        bench('panels', 'reverse', a); bench('panels', 'turn', a)
        assert state()['groups'][0]['members'] == [c, b, a]
        bench('resize', 640, 420)
        for id in (a, b, c):
            assert page(id)['frame'][3] >= 108, page(id)
            bench('select', id); settled()
            frame = page(id)['frame']; outer = state()['frame']
            assert frame[1] >= outer[1] - 1 and frame[1] + frame[3] <= outer[1] + outer[3] + 1, (outer, frame)
        bench('resize', 1180, 780)
        # A Space parks the whole composition; a cross-Space merge is rejected.
        bench('space', 'new', 'Panel boundary')
        bench('field', base + '/other-space', 'go'); other = active()['id']
        assert not bench('panels', 'add', a, other, 'right')['accepted']
        bench('space', 'go', '1')
        assert len(state()['visible']) == 3
        for id in (a, b, c):
            assert page(id)['page'] == identities[id]
        # Copying a Space copies organisation with new bookmark/tab identities;
        # deleting that copy removes its group without touching the source.
        bench('space', 'duplicate', 'Panels Copy'); bench('space', 'go', 3)
        copied = state()
        assert len(copied['groups']) == 2 and len(copied['visible']) == 3, copied
        copied_bookmarks = [p['bookmark'] for p in copied['pages'] if p['bookmark']]
        assert len(copied_bookmarks) == 1 and copied_bookmarks[0] != bookmark, copied
        assert all(p['page'] not in identities.values() for p in copied['pages'] if p['page']), copied
        bench('space', 'delete'); bench('space', 'go', 1)
        assert len(state()['groups']) == 1
        viewed = {id: page(id)['lastViewed'] for id in (a, b, c)}
        bench('press', 45, 'n', 'cmd', 'shift'); bench('field', base + '/private', 'go')
        assert all(page(id)['lastViewed'] > viewed[id] for id in (a, b, c)), state()
        private = active()['id']
        assert not bench('panels', 'add', a, private, 'right')['accepted']
        bench('press', 2, 'd', 'cmd'); private_child = active()['id']
        assert private_child != private and active()['shy']
        assert bench('panels', 'add', private_child, private, 'right')['accepted']
        # Ordinary selection outside the group restores lazily at next launch.
        bench('select', d)
        assert bench('sleep', a)['said'] == 'holding something typed'
        assert bench('sleep', b)['asleep'] and bench('sleep', c)['asleep']
        expected = state()['groups'][0]
        urls = {tab['id']: tab['url'] for tab in bench('tabs')['tabs']}
        expected_urls = [urls[id] for id in expected['members']]
        expected_active = urls[expected['active']]
        bench('press', 12, 'q', 'cmd'); s.until('quit', lambda: not s.running(), 15)
        s.launch(); bench('ui', 'welcome', 'off')
        restored = state(); group = restored['groups'][0]
        assert len(restored['groups']) == 1, restored
        assert group['horizontal'] == expected['horizontal'] and group['weights'] == expected['weights']
        urls = {tab['id']: tab['url'] for tab in bench('tabs')['tabs']}
        assert [urls[id] for id in group['members']] == expected_urls
        assert urls[group['active']] == expected_active
        assert all(not p['page'] for p in restored['pages'] if p['id'] in group['members']), restored
        assert all(not t['shy'] for t in bench('tabs')['tabs'])
        assert any(p['bookmark'] == bookmark for p in restored['pages']), restored
        bench('select', group['members'][0])
        s.until('restored group wakes', lambda: all(page(id)['page'] for id in group['members']))
        # The selected group is the only set of pages built at launch.
        bench('press', 12, 'q', 'cmd'); s.until('quit with group', lambda: not s.running(), 15)
        s.launch(); bench('ui', 'welcome', 'off')
        group = state()['groups'][0]
        s.until('selected group restores', lambda: all(page(id)['page'] for id in group['members']))
        assert all(not p['page'] for p in state()['pages'] if p['id'] not in group['members'])
        for id in group['members']:
            loaded = bench('wait', id, 10)
            assert not loaded['loading'] and not loaded.get('failure') and not loaded.get('timeout'), loaded
        settled()
        # Its capsule acts on that page alone: closing it keeps the other two.
        bench('panels', 'tools', group['members'][0])
        bench('panels', 'close', group['members'][0])
        assert len(state()['groups'][0]['members']) == 2
        bench('select', state()['groups'][0]['members'][0]); bench('press', 13, 'w', 'cmd')
        assert not state()['groups']
        pins = []
        for name in ('pin-a', 'pin-b', 'pin-c'):
            bench('bookmark', base + '/' + name, 'new')
            id = active()['id']; pins.append(id)
            bench('wait', id, 10); bench('pin', id, 'on')
        bench('select', pins[0]); settled()
        result = drag(pins[1], 'right', 'pinned')
        assert result['heldPanels']['preview'] == 'right', result
        assert len(state()['groups']) == 1
        bench('panels', 'close', pins[1])
        assert not state()['groups'] and active()['id'] == pins[0]
        assert next(t for t in bench('tabs')['tabs'] if t['id'] == pins[1])['asleep']
        if require_reduced_motion:
            s.require('macOS Reduce Motion stayed enabled', bench('probe')['reduceMotion'], True)
        print('ok: four real drag directions, carried face, active tab partner, inert group entry, preview, cancellation, identity, focus, zoom, layouts/sizes, resize, boundaries, lazy restoration and closure')
    finally:
        s.command(str(s.ROOT / 'fresh.sh'), 'wipe')
        server.shutdown(); server.server_close()


if __name__ == '__main__':
    parser = ArgumentParser(description=__doc__)
    parser.add_argument('--require-reduced-motion', action='store_true',
                        help='require the actual macOS setting; never change it')
    main(parser.parse_args().require_reduced_motion)
