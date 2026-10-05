#!/usr/bin/env python3
"""Escale to another Escale through one sealed file, between isolated worlds.

A source world is seeded with synthetic state (three Spaces, two sharing a
name, nested bookmark folders, environments, pins and a split, history, what
Bearings learned, hidden elements, zoom, blocker pauses, link rules, settings,
one password per Space), saved with `bench transfer`, and brought into fresh
worlds: an empty one, a used one, and ones that refuse. Persistence is read
from the destination's own files and across a real restart; nothing of the
source is touched and no page is started by the import. Refusals (wrong
passphrase, altered, cut, newer, oversized) and failed writes must leave the
destination exactly as it was. Every world is random and wiped in `finally`.
"""
from datetime import datetime, timedelta, timezone
from http.server import ThreadingHTTPServer
from pathlib import Path
from threading import Thread
import hashlib
import json
import os
import subprocess
import tempfile
import time
import uuid
import suite as s

ROOT = s.ROOT
PHRASE = 'a synthetic passphrase'
SECRET = 'synthetic-test-secret'
FIRST = '00000000-0000-0000-0000-000000000001'
# Seconds since 2001, as the owners write dates; recent, or what was learned fades away.
SEED = time.time() - 978_307_200 - 3600


class World:
    def __init__(self):
        self.name = 'tests-' + uuid.uuid4().hex[:20]
        self.folder = Path.home() / 'Library/Application Support' / f'Escale ({self.name})'
        self.suite = f'com.kndpt.escale.test.{self.name}'
        self.binary = str(ROOT / 'build/probe' / self.name / 'Escale.app/Contents/MacOS/Escale')

    def run(self, *cmd, seconds=60, check=True):
        result = subprocess.run([str(c) for c in cmd], cwd=ROOT, env=dict(os.environ, ESCALE_PROBE=self.name),
                                capture_output=True, text=True, timeout=seconds)
        if check and result.returncode:
            raise AssertionError(f"{cmd}: {result.stdout} {result.stderr}")
        return result.stdout

    def default(self, key, kind, *value):
        self.run('defaults', 'write', self.suite, key, kind, *value)

    def prepare(self):
        assert not self.folder.exists() and not (ROOT / 'build/probe' / self.name).exists(), 'occupied world'
        self.default('bench', '-bool', 'YES')
        self.default('welcomed', '-bool', 'YES')
        checked = (datetime.now(timezone.utc) + timedelta(days=1)).strftime('%Y-%m-%d %H:%M:%S +0000')
        self.default('update.checked', '-date', checked)
        self.folder.mkdir(parents=True, exist_ok=True)

    def running(self):
        out = subprocess.run(['ps', '-axo', 'comm='], capture_output=True, text=True, timeout=5).stdout
        return self.binary in out.splitlines()

    def launch(self, layout=True):
        self.run(ROOT / 'fresh.sh', 'again')
        def ready():
            try:
                return bool(self.bench('tabs'))
            except AssertionError as error:
                if "isn't listening" in str(error): return False
                raise
        s.until(f'{self.name} listening', ready, 30)
        self.bench('ui', 'welcome', 'off'); self.bench('resize', 1180, 780)
        # Setting a preference is what makes an Escale not new: only when asked.
        if layout: self.bench('ui', 'sidebar', 'on')

    def restart(self):
        self.bench('press', 12, 'q', 'cmd')
        s.until('app quit', lambda: not self.running(), 20)
        self.launch()

    def bench(self, *args):
        raw = self.run(ROOT / 'bench', '--world', self.name, '--json', *args, seconds=40, check=False)
        try:
            value = json.loads(raw)
        except ValueError:
            raise AssertionError(f"bench {args}: {raw!r}")
        if isinstance(value, dict) and 'error' in value and 'isn' in value['error']:
            raise AssertionError(value['error'])
        return value

    def transfer(self, *args):
        return self.bench('transfer', *args)

    def until_state(self, what, **expected):
        def matches():
            value = self.transfer('state')
            return value if all(value[k] == v for k, v in expected.items()) else None
        return s.until(what, matches, 40)

    def file(self, name):
        return self.folder / name

    def json(self, name):
        return json.loads(self.file(name).read_text())

    def listing(self):
        # By content: an owner's encoder may order the keys of one object differently each write.
        return {p.name: hashlib.sha256(json.dumps(json.loads(p.read_text()), sort_keys=True).encode()).hexdigest()
                for p in sorted(self.folder.iterdir()) if p.suffix == '.json'}

    def wipe(self):
        self.run('./fresh.sh', 'wipe', check=False)


def flat(nodes, depth=0):
    for node in nodes:
        yield depth, node
        yield from flat(node.get('children') or [], depth + 1)


def tree(nodes):
    """Shape without identities: titles, addresses, environments, nesting."""
    return [dict(title=n['title'], url=n.get('url'), children=tree(n.get('children') or []),
                 environments=[(e['name'], e['url']) for e in n.get('environments') or []]) for n in nodes]


def seed(world, base):
    """The source's state: files the app reads at launch, and settings."""
    work, twin = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()
    def site(title, path, env=None):
        node = dict(id=str(uuid.uuid4()).upper(), title=title, url=base + path)
        if env: node['environments'] = [dict(id=str(uuid.uuid4()).upper(), name=env, url=base + path + '-env')]
        return node
    def folder(title, children):
        return dict(id=str(uuid.uuid4()).upper(), title=title, children=children)
    marks = {
        FIRST: [folder('Docs', [folder('API', [site('Spec', '/spec', 'STG'), site('Guide', '/guide')])]), site('Home', '/home')],
        work: [folder('Docs', [folder('API', [site('Spec', '/w-spec', 'PROD'), site('Guide', '/w-guide')])])],
        twin: [folder('Docs', [site('Notes', '/notes')])],
    }
    spec_work = marks[work][0]['children'][0]['children'][0]['id']
    names = [('Personal', FIRST), ('Work', work), ('Personal', twin)]
    def name(space): return 'session.json' if space == FIRST else f'session-{space}.json'
    def pick(space, stem):
        return stem if space == FIRST else f'{stem[:-5]}-{space}.json'
    spaces = [dict(id=i, name=n, colour=k, icon=None) for k, (n, i) in enumerate(names)]
    world.file('spaces.json').write_text(json.dumps(spaces))
    for space, nodes in marks.items():
        world.file('bookmarks.json' if space == FIRST else f'bookmarks-{space}.json').write_text(json.dumps(nodes))
    world.file(name(FIRST)).write_text(json.dumps(dict(active=1, tabs=[
        dict(url=base + '/a', title='A', pin='A'), dict(url=base + '/b', title='B'), dict(url=base + '/c', title='C')],
        panels=[dict(members=[1, 2], active=1, horizontal=True, weights=[0.5, 0.5])])))
    spec, guide = marks[work][0]['children'][0]['children']
    world.file(name(work)).write_text(json.dumps(dict(active=0, tabs=[
        dict(url=base + '/w-spec', title='W1', bookmark=spec['id']),
        dict(url=base + '/w-guide', title='W2', bookmark=guide['id'])],
        panels=[dict(members=[0, 1], active=0, horizontal=False, weights=[0.5, 0.5])])))
    world.file(name(twin)).write_text(json.dumps(dict(active=0, tabs=[dict(url=base + '/t1', title='T1')])))
    def visits(n, tag): return [dict(url=f'{base}/{tag}{i}', key=f'127.0.0.1/{tag}{i}', title=f'{tag}{i}', count=i + 1, last=SEED) for i in range(n)]
    for space, n, tag in ((FIRST, 4, 'h'), (work, 3, 'w'), (twin, 1, 't')):
        world.file('history.json' if space == FIRST else f'history-{space}.json').write_text(json.dumps(visits(n, tag)))
    world.file(f'habits-{work}.json').write_text(json.dumps([dict(query='spec', picks=[dict(to='bookmark:' + spec_work, count=2.5, last=SEED)])]))
    world.file(f'hidden-{work}.json').write_text(json.dumps({'ads.invalid': [dict(selector='.banner', label='A banner', date=SEED)]}))
    world.file('link-rules.json').write_text(json.dumps([dict(id=str(uuid.uuid4()).upper(), scope='host', host='docs.invalid',
                                                              subdomains=False, port='', path='', exact='', destination=work)]))
    world.default('look', '-string', 'dark'); world.default('interface.size', '-string', 'large')
    world.default('search.engine', '-string', 'standard')
    world.default('zoom.first.invalid', '-float', '1.25')
    world.default(f'zoom.{work}.work.invalid', '-float', '1.5')
    world.default(f'shield.paused.{work}', '-array', 'paused.invalid')
    world.default(f'passwords.never.{work}', '-array', 'never.invalid')
    return dict(work=work, twin=twin, marks=marks, spec_work=spec_work)


def keychain(world, space, user):
    """Whether the world's app finds that user's password in that Space, and it is the synthetic one."""
    found = world.transfer('logins', space)['logins']
    digest = hashlib.sha256(SECRET.encode()).hexdigest()
    return SECRET if any(row['user'] == user and row['digest'] == digest for row in found) else None


def bring(world, path, phrase=PHRASE, apply=True, **apply_options):
    world.transfer('choose', path)
    world.until_state('file chosen', bringing='locked')
    world.transfer('unlock', phrase)
    summary = world.until_state('file opened', bringing='summary')
    if not apply:
        return summary
    world.transfer('apply', *apply_options.get('args', []))
    return world.until_state('import finished', bringing='finished')


def refused(world, path, phrase=PHRASE):
    """Choosing then unlocking a file that cannot be used changes nothing."""
    before = world.listing(); spaces = world.transfer('state')['spaces']
    world.transfer('choose', path)
    state = s.until('choose answered', lambda: (v if (v := world.transfer('state'))['bringing'] in ('locked', 'failed') else None), 20)
    if state['bringing'] == 'locked':
        world.transfer('unlock', phrase)
        state = s.until('unlock answered', lambda: (v if (v := world.transfer('state'))['bringing'] in ('locked', 'failed', 'summary') else None), 40)
        assert state['bringing'] == 'locked' and state['mistake'], state
    assert state['bringing'] in ('locked', 'failed'), state
    assert world.listing() == before and world.transfer('state')['spaces'] == spaces, 'a refused file changed the destination'
    world.transfer('forget')
    return state


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), s.Page)
    Thread(target=server.serve_forever, daemon=True).start()
    base = f'http://127.0.0.1:{server.server_port}'
    worlds = []
    def new():
        world = World(); worlds.append(world); world.prepare(); return world
    # Outside ~/Documents: macOS asks a person before an app reads a file there.
    scratch = Path(tempfile.mkdtemp(prefix='escale-transfer-'))
    try:
        # --- the source -------------------------------------------------
        source = new()
        fixture = seed(source, base)
        source.launch()
        assert source.bench('probe')['look'] == 'dark'
        assert source.transfer('state')['pristine'] is False
        assert len(source.transfer('state')['spaces']) == 3
        assert source.bench('space', 'credentials', 'first-user')['saved']
        source.bench('space', 'go', 2)
        assert source.bench('space', 'credentials', 'work-user')['saved']
        source.bench('space', 'go', 1)
        # A tab opened an instant before the save is in the file: the snapshot
        # is the state now, not the last write.
        source.bench('bookmark', base + '/late', 'new')
        late = next(t['id'] for t in source.bench('tabs')['tabs'] if t['url'].endswith('/late'))
        source.bench('wait', late, 10)
        export = scratch / 'Escale-test.escale'
        started = time.monotonic()
        source.transfer('save', export, PHRASE, 'passwords')
        saved = source.until_state('file saved', saving='saved')
        print(f"save: {saved['savedSpaces']} Spaces in {time.monotonic() - started:.2f}s, {export.stat().st_size} bytes", flush=True)
        assert saved['savedSpaces'] == 3 and saved['savedName'] == export.name
        data = export.read_bytes()
        assert data[:8] == b'ESCLXFER', 'not the sealed envelope'
        for needle in (SECRET.encode(), b'Spec', b'first-user', base.encode(), b'Personal'):
            assert needle not in data, f'{needle!r} readable in the file'
        # What the app itself writes a moment after a page loads has landed by
        # now; a second save must not change a single file of the source.
        time.sleep(3)
        before = source.listing()
        source.transfer('save', scratch / 'again.escale', PHRASE)
        source.until_state('second save', saving='saved')
        changed = {k for k, v in source.listing().items() if before.get(k) != v}
        assert not changed, f'saving changed the source: {sorted(changed)}'
        assert len(source.transfer('state')['spaces']) == 3
        assert not list(scratch.glob('.*')), 'a temporary file was left beside the export'
        assert sorted(p.name for p in scratch.iterdir()) == ['Escale-test.escale', 'again.escale']
        assert keychain(source, FIRST, 'first-user') == SECRET
        # A save that cannot be written keeps the export that was there.
        locked = scratch / 'locked'; locked.mkdir()
        (locked / 'Escale-keep.escale').write_bytes(data)
        locked.chmod(0o500)
        try:
            source.transfer('save', locked / 'Escale-keep.escale', PHRASE)
            refusal = source.until_state('save refused', saving='failed')
            assert 'write' in refusal['failure'], refusal
            assert (locked / 'Escale-keep.escale').read_bytes() == data, 'a failed save replaced the earlier export'
            assert sorted(p.name for p in locked.iterdir()) == ['Escale-keep.escale'], 'a partial file was left'
        finally:
            locked.chmod(0o700)
        print('source: saved, unreadable at rest, unchanged', flush=True)

        # --- an empty destination ---------------------------------------
        empty = new(); empty.launch(layout=False)
        refused(empty, str(export), 'not the passphrase')
        print('destination: a wrong passphrase changes nothing', flush=True)
        started = time.monotonic()
        opened = bring(empty, str(export), apply=False)
        assert opened['pristine'] is True, 'an Escale with nothing of its own is recognised'
        summary = opened['summary']
        print(f"open: {time.monotonic() - started:.2f}s", flush=True)
        names = [line['name'] for line in summary['lines']]
        assert names == ['Personal', 'Work', 'Personal'], names
        assert [line['tabs'] for line in summary['lines']] == [4, 2, 1], summary
        assert [line['passwords'] for line in summary['lines']] == [1, 1, 0], summary
        assert [line['history'] >= n for line, n in zip(summary['lines'], (4, 3, 1))] == [True] * 3, summary
        assert [line['bookmarks'] for line in summary['lines']] == [3, 2, 1], summary
        assert summary['includesPasswords'] and summary['linkRules'] == 1 and summary['preferences'] >= 10
        assert empty.transfer('state')['takesPreferences'] is True, 'an empty Escale takes the file settings by default'
        started = time.monotonic()
        empty.transfer('apply')
        report = empty.until_state('import finished', bringing='finished')['report']
        print(f"import: {time.monotonic() - started:.2f}s", flush=True)
        assert report['imported'] == ['Personal', 'Work', 'Personal'] and not report['failed'] and not report['already'], report
        assert report['passwordsAdded'] == 2 and report['passwordsFailed'] == 0 and report['linkRules'] == 1 and report['preferences'] >= 10, report
        arrived = empty.transfer('state')['spaces']
        assert [space['name'] for space in arrived] == ['Personal', 'Personal', 'Work', 'Personal'], arrived
        ids = [space['id'] for space in arrived]
        assert FIRST.upper() in ids[0].upper() and len(set(ids)) == 4 and not {fixture['work'], fixture['twin']} & set(ids)
        first_new, work_new, twin_new = ids[1], ids[2], ids[3]
        assert empty.bench('probe')['look'] == 'dark' and empty.bench('probe')['interfaceSize'] == 'large'

        def check(world, first_new, work_new, twin_new):
            files = lambda stem, space: world.json(f'{stem}-{space}.json')
            for new_id, old in ((first_new, FIRST), (work_new, fixture['work']), (twin_new, fixture['twin'])):
                assert tree(files('bookmarks', new_id)) == tree(fixture['marks'][old]), f'bookmarks of {new_id}'
                old_ids = {n['id'] for _, n in flat(fixture['marks'][old])}
                new_ids = {n['id'] for _, n in flat(files('bookmarks', new_id))}
                assert not old_ids & new_ids and len(new_ids) == len(old_ids), 'identities are remapped together'
            session = files('session', first_new)
            assert [t['url'].rsplit('/', 1)[1] for t in session['tabs']] == ['a', 'b', 'c', 'late'], session
            assert session['tabs'][0]['pin'] == 'A' and session['panels'][0]['members'] == [1, 2]
            split = files('session', work_new)
            linked = split['tabs'][0]['bookmark']
            assert split['panels'][0]['members'] == [0, 1] and split['panels'][0]['horizontal'] is False
            assert linked in {n['id'] for _, n in flat(files('bookmarks', work_new))}, 'a tab keeps its bookmark, remapped'
            assert len(files('history', first_new)) >= 4 and len(files('history', work_new)) >= 3
            learned = files('habits', work_new)[0]
            assert learned['query'] == 'spec' and learned['picks'][0]['to'].lower() == 'bookmark:' + linked.lower(), learned
            assert files('hidden', work_new)['ads.invalid'][0]['selector'] == '.banner'
            rules = world.json('link-rules.json')
            assert [r['destination'].lower() for r in rules] == [work_new.lower()] and rules[0]['host'] == 'docs.invalid'
            settings = world.run('defaults', 'read', world.suite)
            assert f'"zoom.{work_new.upper()}.work.invalid" = "1.5"' in settings or f'zoom.{work_new.upper()}.work.invalid' in settings.upper()
            assert 'paused.invalid' in settings and 'never.invalid' in settings

        check(empty, first_new, work_new, twin_new)
        # The passwords are in the destination's keychain, each in its own Space.
        assert keychain(empty, first_new, 'first-user') == SECRET and keychain(empty, work_new, 'work-user') == SECRET
        assert keychain(empty, work_new, 'first-user') is None and keychain(empty, first_new, 'work-user') is None
        for folder in (empty.folder, scratch):
            for path in folder.rglob('*'):
                if path.is_file() and path.suffix != '.escale':
                    assert SECRET.encode() not in path.read_bytes(), f'a password sits in clear in {path}'
        # Imported tabs are addresses, not pages: nothing starts until a tab is used.
        empty.bench('space', 'go', 2)
        listed = [t for t in empty.bench('tabs')['tabs'] if not t['bench']]
        assert len(listed) == 4, listed
        # Only the tab the person lands on wakes; the rest are addresses.
        assert sum(1 for t in listed if t['view']) <= 1 and all(t['asleep'] or t['active'] for t in listed), listed
        assert all(t['space'].lower() == arrived[1]['id'].lower() for t in listed)
        print('destination: Spaces, bookmarks, tabs, history, learning, rules, settings and passwords arrived, lazily', flush=True)

        # --- across a restart, and the same file again ------------------
        empty.restart()
        assert [space['name'] for space in empty.transfer('state')['spaces']] == ['Personal', 'Personal', 'Work', 'Personal']
        check(empty, first_new, work_new, twin_new)
        empty.bench('space', 'go', 2)
        empty.bench('bookmark', base + '/local-edit', 'new'); empty.bench('press', 12, 'q', 'cmd')
        s.until('quit', lambda: not empty.running(), 20); empty.launch()
        after_edit = empty.json(f'session-{first_new}.json')
        assert any(t['url'].endswith('/local-edit') for t in after_edit['tabs']), 'the local edit was saved'
        spaces_before = empty.transfer('state')['spaces']
        again = bring(empty, str(export))['report']
        assert again['imported'] == [] and sorted(again['already']) == ['Personal', 'Personal', 'Work'], again
        assert empty.transfer('state')['spaces'] == spaces_before, 'the same file made Spaces twice'
        assert empty.json(f'session-{first_new}.json') == after_edit, 'the local edit was overwritten'
        print('destination: survives a restart; the same file again adds nothing and keeps local edits', flush=True)

        # --- a destination where only a setting was changed --------------
        tuned = new(); tuned.launch(layout=False)
        tuned.bench('ui', 'look', 'light')
        opened = bring(tuned, str(export), apply=False)
        assert opened['pristine'] is False and opened['takesPreferences'] is False, 'a changed setting alone is not an empty Escale'
        tuned.transfer('forget')
        print('a destination with only a changed setting keeps it by default', flush=True)

        # --- leaving while a read or an unlock is running ---------------------
        # What finishes after the walk was dropped must not bring the file back.
        tuned.transfer('choose', str(export)); tuned.transfer('forget')
        time.sleep(1.5)
        assert tuned.transfer('state')['bringing'] == 'idle', 'a read that finished after leaving brought the file back'
        tuned.transfer('choose', str(export)); tuned.until_state('chosen', bringing='locked')
        tuned.transfer('unlock', PHRASE); tuned.transfer('forget')
        time.sleep(1.5)
        assert tuned.transfer('state')['bringing'] == 'idle', 'an unlock that finished after leaving kept the opened file'
        print('leaving drops a read or unlock still running', flush=True)

        # --- a destination already in use --------------------------------
        # One file made for each destination sharing this Mac's keychain: a keychain item
        # is unique by site, account and path, so two worlds must not import one transfer.
        def exported(name):
            path = scratch / name
            source.transfer('save', path, PHRASE, 'passwords')
            s.until('export saved', lambda: source.transfer('state')['saving'] == 'saved' and path.exists())
            return path
        used_file = exported('used.escale')
        used = new(); used.launch()
        used.bench('ui', 'look', 'light')
        used.bench('space', 'new', 'Existing')
        existing = used.transfer('state')['spaces']
        used.bench('bookmark', base + '/mine', 'new')
        mine = [t['url'] for t in used.bench('tabs')['tabs']]
        opened = bring(used, str(used_file), apply=False)
        assert opened['pristine'] is False and opened['takesPreferences'] is False, 'settings of a used Escale are kept by default'
        used.transfer('apply', 'keep')
        done = used.until_state('import finished', bringing='finished')
        assert done['report']['preferences'] == 0 and len(done['report']['imported']) == 3, done['report']
        assert [space['name'] for space in done['spaces']] == [space['name'] for space in existing] + ['Personal', 'Work', 'Personal']
        assert used.bench('probe')['look'] == 'light', 'the destination kept its own look'
        assert [t['url'] for t in used.bench('tabs')['tabs']] == mine, 'existing tabs were kept as they were'
        print('used destination: Spaces added after its own, settings kept', flush=True)

        # --- files that cannot be used ------------------------------------
        bad_file = exported('bad.escale')
        bad = new(); bad.launch()
        altered = bytearray(data); altered[len(altered) // 2] ^= 0x01
        (scratch / 'altered.escale').write_bytes(altered)
        (scratch / 'cut.escale').write_bytes(data[:20])
        (scratch / 'half.escale').write_bytes(data[:len(data) // 2])
        newer = bytearray(data); newer[9] = 9
        (scratch / 'newer.escale').write_bytes(newer)
        (scratch / 'text.escale').write_text('this is not an Escale export')
        with (scratch / 'huge.escale').open('wb') as huge:
            huge.write(b'ESCLXFER'); huge.truncate(70 * 1024 * 1024)
        (scratch / 'cost.escale').write_bytes(data[:10] + b'\xff\xff\xff\xff' + data[14:])
        for name in ('altered', 'cut', 'half', 'newer', 'text', 'huge', 'cost'):
            state = refused(bad, str(scratch / f'{name}.escale'))
            print(f'refused {name}: {state["bringing"]} · {state.get("failure") or state["mistake"]}', flush=True)
        assert 'newer Escale' in refused(bad, str(scratch / 'newer.escale'))['failure']
        assert 'larger' in refused(bad, str(scratch / 'huge.escale'))['failure']

        # --- writes that fail ---------------------------------------------
        for step in ('files', 'spaces'):
            before = bad.listing()
            bad.transfer('fail', step)
            outcome = bring(bad, str(bad_file))['report']
            assert outcome['imported'] == [] and len(outcome['failed']) == 3, outcome
            assert bad.transfer('state')['spaces'] == [{'id': FIRST, 'name': 'Personal'}] or len(bad.transfer('state')['spaces']) == 1
            assert bad.listing() == before, f'a failed {step} write left files behind'
        bad.transfer('fail')
        bad.transfer('fail', 'keychain')
        partial = bring(bad, str(bad_file))['report']
        assert len(partial['imported']) == 3 and partial['passwordsFailed'] == 2 and partial['passwordsAdded'] == 0, partial
        bad.transfer('fail')
        ids = [space['id'] for space in bad.transfer('state')['spaces']]
        repaired = bring(bad, str(bad_file))['report']
        assert repaired['imported'] == [] and repaired['passwordsAdded'] == 2, repaired
        assert keychain(bad, ids[2], 'work-user') == SECRET
        print('failed writes leave nothing behind; a refused keychain is retried by opening the file again', flush=True)

        # --- stopped between two Spaces, then finished ----------------------
        halted = new(); halted.launch()
        halted_file = exported('halted.escale')
        halted.transfer('fail', 'slow')
        halted.transfer('choose', str(halted_file)); halted.until_state('locked', bringing='locked')
        halted.transfer('unlock', PHRASE); halted.until_state('opened', bringing='summary')
        halted.transfer('apply')
        # The first Space is being saved; the second waits its turn: stop here.
        s.until('first Space reached', lambda: halted.transfer('state').get('progress') not in (None, '', 'Starting…'), 20)
        halted.transfer('cancel')
        stopped = halted.until_state('stopped', bringing='finished')['report']
        assert stopped['stopped'] and stopped['imported'] == ['Personal'], stopped
        names = [space['name'] for space in halted.transfer('state')['spaces']]
        assert names == ['Personal', 'Personal'], names
        halted.transfer('fail')
        rest = bring(halted, str(halted_file))['report']
        assert rest['already'] == ['Personal'] and rest['imported'] == ['Work', 'Personal'] and not rest['failed'], rest
        assert [space['name'] for space in halted.transfer('state')['spaces']] == ['Personal', 'Personal', 'Work', 'Personal']
        print('a stop between Spaces keeps what was saved; opening the file again adds the rest', flush=True)
        print('ok: one sealed file carries every Space between isolated worlds, refuses what it cannot open, and never changes what it does not bring')
    finally:
        for world in worlds:
            try: world.wipe()
            except Exception as error: print(f'cleanup of {world.name} failed: {error}')
        server.shutdown(); server.server_close()
        subprocess.run(['rm', '-rf', str(scratch)], check=False)


if __name__ == '__main__':
    main()
