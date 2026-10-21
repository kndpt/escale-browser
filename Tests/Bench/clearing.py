#!/usr/bin/env python3
"""Clearing asks first, from Settings and from History, and keeps to its scope.

Each clearing button and the sheet that follows are pressed as VoiceOver
presses them, through the app's accessibility tree read from outside (the
helpers of tab_access.py). Two Spaces each visit a loopback page and keep a
cookie. History, from Settings and then from the History panel: Cancel keeps
every line, Clear History empties this Space's and leaves the other Space's
alone. Sign out of everything: Cancel keeps both cookies, confirming removes
them in both Spaces. Cache: its sheet names every Space, Cancel clears
nothing and Clear Cache announces it is done. Each sheet's words are checked
for the scope they state.
Needs Accessibility access for the app that runs this script (System Settings
› Privacy & Security). Not covered: the menu's Clear History (the same
confirmation, from KeyRouting), what the cache held, and how the sheets look
in light and dark. Run after ./build.sh debug; the world is owned by the
shared runner and pages are served from loopback.
"""
from http.server import ThreadingHTTPServer
from threading import Thread
import suite as h
import tab_access as ax

COOKIE = "document.cookie = 'kept=1; max-age=3600; path=/'"


def bench(*args):
    return ax.bench(*args)


def walk(element, depth=0):
    yield element
    if depth < 6:
        for child in ax.attribute(element, 'AXChildren') or []:
            yield from walk(child, depth + 1)


def sheet(root):
    """The window's sheet: its words and its buttons by title, or None."""
    for window in ax.attribute(root, 'AXWindows') or []:
        for child in ax.attribute(window, 'AXChildren') or []:
            if ax.attribute(child, 'AXRole') != 'AXSheet':
                continue
            items = list(walk(child))
            return {'texts': [ax.attribute(e, 'AXValue') for e in items if ax.attribute(e, 'AXRole') == 'AXStaticText'],
                    'buttons': {ax.attribute(e, 'AXTitle'): e for e in items if ax.attribute(e, 'AXRole') == 'AXButton'}}
    return None


def buttons(root, title):
    """The window's buttons named `title`, in tree order, or None."""
    return [f for f in ax.labelled(root, title) if f['role'] == 'AXButton'] or None


def press(root, title, index=0):
    """The `index`th button named `title`, pressed."""
    found = h.until(f'a {title} button', lambda: (lambda f: f if f and len(f) > index else None)(buttons(root, title)), 15)
    ax.perform(found[index], 'AXPress')


def answer(root, title, says, button):
    """The sheet `title` opened, saying each of `says`, answered with `button`."""
    shown = h.until(f'the “{title}” sheet', lambda: (lambda s: s if s and title in s['texts'] else None)(sheet(root)), 15)
    words = ' '.join(t or '' for t in shown['texts'])
    for part in says:
        h.require(f'“{title}” says “{part}”', part in words, True)
    h.require(f'“{title}” offers {button}', button in shown['buttons'], True)
    h.require(f'{button} pressed', ax.AX.AXUIElementPerformAction(shown['buttons'][button], ax.text('AXPress')), 0)
    h.until(f'the “{title}” sheet gone', lambda: sheet(root) is None, 15)


def history():
    return bench('space')['history']


def cookie(ident):
    return 'kept=1' in (bench('eval', ident, 'document.cookie').get('value') or '')


def clear_history(root, start, rows):
    """History cleared from `start`: Cancel keeps it, Clear History empties it."""
    before = history()
    h.require('history to clear', before > 0, True)
    start()
    press(root, 'Clear', rows)
    answer(root, 'Clear this Space’s history?', ['in this Space', 'Other Spaces keep theirs'], 'Cancel')
    h.require('history after Cancel', history(), before)
    start()
    press(root, 'Clear', rows)
    answer(root, 'Clear this Space’s history?', [], 'Clear History')
    h.until('history after Clear History', lambda: history() == 0, 10)


def main():
    if not ax.AX.AXIsProcessTrusted():
        raise AssertionError('this script needs Accessibility access for the app that runs it '
                             '(System Settings › Privacy & Security › Accessibility)')
    server = ThreadingHTTPServer(('127.0.0.1', 0), h.Page)
    Thread(target=server.serve_forever, daemon=True).start()
    origin = f'http://127.0.0.1:{server.server_port}'
    with h.world(server):
        h.command('defaults', 'write', h.SUITE, 'settings.page', 'privacy')
        h.launch()
        bench('resize', 1180, 800)
        root = ax.app()

        bench('space', 'new', 'Other')
        other = h.open_ordinary(f'{origin}/other')
        bench('eval', other, COOKIE)
        h.until('the other Space remembers its page', lambda: history() > 0, 10)
        kept = history()
        bench('space', 'go', '1')
        here = h.open_ordinary(f'{origin}/here')
        bench('eval', here, COOKIE)
        h.until('this Space remembers its page', lambda: history() > 0, 10)

        def settings():
            bench('ui', 'settings', 'on')

        def panel():
            """The History panel's sweeps, through its Clear… unless they are already up."""
            bench('ui', 'history', 'on')
            h.until('the History panel', lambda: buttons(root, 'Clear…') or buttons(root, 'Back'), 15)
            if buttons(root, 'Clear…'):
                press(root, 'Clear…')

        # From Settings: History is its first Clear, Cache its second.
        clear_history(root, settings, 0)
        print('ok: Settings asks before clearing history; Cancel keeps it, Clear History empties it', flush=True)
        bench('ui', 'settings', 'off')
        bench('go', here, f'{origin}/again')
        h.until('this Space remembers a page again', lambda: history() > 0, 10)
        # In the panel's sweeps: History, then Cache.
        clear_history(root, panel, 0)
        h.until('the panel back on its list', lambda: buttons(root, 'Clear…'), 10)
        bench('ui', 'history', 'off')
        print('ok: History asks before clearing history; Cancel keeps it, Clear History empties it', flush=True)

        panel()
        press(root, 'Sign out of everything')
        answer(root, 'Sign out of every site?', ['in every Space', 'sign in again'], 'Cancel')
        h.require('cookie here after Cancel', cookie(here), True)
        bench('ui', 'history', 'off')
        settings()
        press(root, 'Clear', 1)
        answer(root, 'Clear the cache in every Space?', ['Cookies and sign-ins are kept'], 'Cancel')
        press(root, 'Sign out of everything')
        answer(root, 'Sign out of every site?', [], 'Sign Out of Everything')
        h.until('cookie here signed out', lambda: not cookie(here), 10)
        press(root, 'Clear', 1)
        answer(root, 'Clear the cache in every Space?', [], 'Clear Cache')
        h.until('cache cleared', lambda: bench('probe')['announcement'] == 'Cache cleared', 10)
        bench('ui', 'settings', 'off')
        print('ok: Sign out and Cache ask first; Cancel keeps cookies, confirming removes them', flush=True)

        bench('space', 'go', '2')
        h.require('the other Space keeps its history', history(), kept)
        h.until('the other Space signed out too', lambda: not cookie(other), 10)
        print('PASS: every clearing asks, from Settings and from History; history stays per Space, '
              'sign-out reaches every Space')


if __name__ == '__main__':
    main()
