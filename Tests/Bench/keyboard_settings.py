#!/usr/bin/env python3
"""Effective configurable commands through real app keys and a saved fixture.

The isolated profile starts with defaults, exercises Space/tab destinations,
then loads a custom snapshot. Old keys must stop working and new keys must keep
working after another restart. Recorder clicks/conflicts are checked separately
in the visible app; this scenario proves the dispatch and persistence boundary.
"""
import json
from http.server import ThreadingHTTPServer
from threading import Thread
import suite as h


def ask(verb, *args):
    return json.loads(h.command(str(h.ROOT / 'bench'), '--world', h.WORLD, '--json', verb, *map(str, args)))


def press(code, char, *mods):
    return ask('press', code, char, *mods)


def quit_app():
    # Leave the typed WebKit field before the app-level native Quit key.
    # WebKit interprets physical key codes using the host input source.
    ask('space', 'go', 3)
    press(12, 'q', 'cmd')
    h.until('app quit', lambda: not h.running())


def active():
    return next(t['id'] for t in h.tabs() if t['active'])


def run():
    server = ThreadingHTTPServer(('127.0.0.1', 0), h.Page)
    Thread(target=server.serve_forever, daemon=True).start()
    with h.world(server):
        h.launch()
        ask('ui', 'spaces', 'on')
        ids = [h.open_ordinary(f'http://127.0.0.1:{server.server_port}/key-{n}') for n in range(2)]
        press(18, '&', 'cmd')
        h.require('AZERTY physical 1 selects first tab', active(), ids[0])
        press(19, 'é', 'cmd')
        h.require('AZERTY physical 2 selects second tab', active(), ids[1])
        first = ask('space')['current']
        ask('space', 'new', 'Second')
        ask('space', 'new', 'Third')
        for code, char, expected in [(126, '\uf700', 'Second'), (126, '\uf700', first), (126, '\uf700', 'Third'), (125, '\uf701', first)]:
            press(code, char, 'opt', 'cmd')
            h.require('Space cycling follows visible order and wraps', ask('space')['current'], expected)
        press(19, 'é', 'ctrl')
        h.require('AZERTY direct Space destination', ask('space')['current'], 'Second')
        ask('space', 'move', 1)
        press(18, '&', 'ctrl')
        h.require('Space destination follows reorder', ask('space')['current'], 'Second')
        ask('ui', 'spaces', 'off')
        before = ask('space')['current']
        press(125, '\uf701', 'opt', 'cmd')
        press(20, '"', 'ctrl')
        h.require('disabled Spaces ignore shortcuts', ask('space')['current'], before)
        ask('ui', 'spaces', 'on')
        ask('space', 'go', 2)
        quit_app()
        # Store uses Data, as Preferences does. Never touch a production suite.
        data = json.dumps({'overrides': {
            'newTab': [{'key': 't', 'modifiers': 1572864}],
            'nextSpace': [{'key': 'k', 'modifiers': 1572864}],
            'downloads': [],
            'closeTab': [{'key': 'w', 'modifiers': 1572864}],
            # A profile written before formatting keys were protected.
            'duplicateTab': [{'key': 'b', 'modifiers': 1048576}],
            'history': [{'key': 'i', 'modifiers': 1048576}],
            'passwords': [{'key': 'u', 'modifiers': 1048576}],
        }}).encode().hex()
        h.command('defaults', 'write', h.SUITE, 'keyboard.bindings', '-data', data)
        for run in range(2):
            h.launch()
            ask('ui', 'settings', 'off')
            names = [x['name'] for x in ask('space')['spaces']]
            home = names.index(first) + 1
            ask('space', 'go', home)
            before = ask('space')['current']
            press(125, '\uf701', 'opt', 'cmd')
            h.require('old Space key disabled', ask('space')['current'], before)
            press(40, 'k', 'opt', 'cmd')
            h.require('custom Space key dispatched', ask('space')['current'], names[home % len(names)])
            ask('space', 'go', home)
            press(53, '\x1b')
            press(17, 't', 'cmd')
            h.require('old New Tab key disabled', ask('probe')['openingTab'], False)
            press(17, 't', 'opt', 'cmd')
            h.require('custom New Tab key works after restart', ask('probe')['openingTab'], True)
            press(53, '\x1b')
            press(38, 'j', 'cmd', 'shift')
            h.require('unassigned Downloads no longer opens', ask('probe')['downloads'], False)
            target = h.open_ordinary(f'http://127.0.0.1:{server.server_port}/close-target')
            count = len(h.tabs())
            press(13, 'w', 'cmd')
            h.require('old Close Tab does not close a tab', len(h.tabs()), count)
            h.require('old Close Tab does not close the window',
                      any(w['title'] == 'Escale' and w['visible'] for w in ask('probe')['windows']), True)
            press(13, 'w', 'opt', 'cmd')
            h.require('custom Close Tab closes the selected tab', target in [t['id'] for t in h.tabs()], False)
            # Native text editing still reaches the web responder.
            restored = h.at(f'http://127.0.0.1:{server.server_port}/key-0')['id']
            ask('select', restored)
            h.loaded_page(restored, 'key-0', 15, 'restored page wakes')
            h.ask('tap', id=restored, selector='#draft')
            h.ask('key', id=restored, text='draft')
            h.ask('key', id=restored, text='kept')
            h.require('ordinary typing intact', h.ask('eval', id=restored, js="document.querySelector('#draft').value")['value'], 'draftkept')
            # Web editors own their formatting commands; the app must deliver the keys
            # despite a profile that previously bound them to browser commands.
            for code, key, formatting in [(11, 'b', 'bold'), (34, 'i', 'italic'), (32, 'u', 'underline')]:
                h.ask('eval', id=restored, js="document.body.innerHTML = '<div id=rich contenteditable=true>format me</div>'")
                h.ask('eval', id=restored, js="""
                    document.querySelector('#rich').onkeydown = event => {
                        const command = {b: 'bold', i: 'italic', u: 'underline'}[event.key];
                        if (event.metaKey && command) {
                            event.preventDefault();
                            document.querySelector('#rich').dataset.received = event.key;
                            document.execCommand(command);
                        }
                    };
                    void 0;
                """)
                h.ask('tap', id=restored, selector='#rich')
                h.ask('eval', id=restored, js="(() => { const range = document.createRange(); range.selectNodeContents(document.querySelector('#rich')); const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range); })()")
                h.require('rich editor has focus', h.ask('eval', id=restored, js="document.activeElement.id")['value'], 'rich')
                count = len(h.tabs())
                press(code, key, 'cmd')
                # The page handles the key in its own process, after the app has.
                h.wait_for(f'{formatting} shortcut reaches the web editor after restart', lambda: {
                    'received': h.ask('eval', id=restored, js="document.querySelector('#rich').dataset.received || ''")['value'],
                    'applied': h.ask('eval', id=restored, js=f"document.queryCommandState('{formatting}')")['value']},
                    {'received': key, 'applied': True}, 5)
                h.require('formatting does not duplicate tabs', len(h.tabs()), count)
                state = ask('probe')
                h.require('formatting does not open History', state['history'], False)
                h.require('formatting does not open Passwords', state['passwords'], False)
            quit_app()
        print('PASS: Space cycles, wrap, reorder, AZERTY tab/Space keys, disabled Spaces, custom bindings, removed defaults, restart, native editing and rich-text formatting')


if __name__ == '__main__':
    run()
