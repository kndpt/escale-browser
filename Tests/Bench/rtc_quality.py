#!/usr/bin/env python3
"""Local synthetic receive-path diagnostic for call quality, not a Meet
qualification.

Uses ordinary foreground tabs, production scheduling, no microphone/display
capture and no remote ICE server. The receiver's decoded tone and colour patches
are checked; physical output, WAN and getDisplayMedia remain manual comparisons.
"""
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread
import json
import os
import time
import suite as s


def main():
    fixture = Path(__file__).parent / 'fixtures' / 'rtc-quality'
    server = ThreadingHTTPServer(('127.0.0.1', 0), partial(SimpleHTTPRequestHandler, directory=str(fixture)))
    Thread(target=server.serve_forever, daemon=True).start()
    with s.world(server):
        # suite.command intentionally strips ESCALE_MEASURE; use env explicitly
        # for the launch so scheduling and App Nap match a production call.
        s.command('env', 'ESCALE_MEASURE=1', str(s.ROOT / 'fresh.sh'), 'again')
        s.until('probe socket', s.probe_ready, 30)
        s.command(str(s.ROOT / 'bench'), '--world', s.WORLD, 'ui', 'welcome', 'off')
        reports = []
        for run in range(6):
            policy = 'default' if run % 2 == 0 else 'detail'
            s.ask('bookmark', url=f'http://127.0.0.1:{server.server_port}/?run={run}&policy={policy}', new=True)
            tab = next(t for t in s.tabs() if t['active'])['id']
            loaded = s.ask('wait', id=tab, seconds=15)
            assert not loaded.get('timeout') and not loaded.get('failure'), loaded
            s.ask('tap', id=tab, selector='#start')

            def completed():
                state = s.ask('eval', id=tab, js='window.probe')['value']
                assert state['state'] != 'failed', state
                if state['state'] != 'complete':
                    time.sleep(0.8)
                return state if state['state'] == 'complete' else None

            report = s.until('30 media samples', completed, 45)
            reports.append(report)
            output = Path(os.environ.get('RESULTS', s.ROOT / 'build/rtc-quality.json'))
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(json.dumps(reports, indent=2) + '\n')
            assert len(report['samples']) == 30, report
            assert report['videoHints'] == (['detail'] if policy == 'detail' else ['']), report
            for sample in report['samples'][5:]:
                assert sample['connection'] == 'connected', sample
                assert sample['width'] > 0 and sample['height'] > 0, sample
                if policy == 'detail':
                    assert (sample['width'], sample['height']) == (1280, 720), sample
                assert abs(sample['hz'] - 1000) < 15 and sample['db'] is not None and sample['db'] > -40, sample
                assert sample['red'][0] > 200 and sample['red'][1] < 40 and sample['red'][2] < 40, sample
                assert sample['blue'][2] > 200 and sample['blue'][0] < 40 and sample['blue'][1] < 40, sample
                assert {row['kind'] for row in sample['inbound']} == {'audio', 'video'}, sample
            first = {row['kind']: row for row in report['samples'][5]['inbound']}
            last = {row['kind']: row for row in report['samples'][-1]['inbound']}
            assert last['audio']['packetsReceived'] > first['audio']['packetsReceived'], report
            assert last['video']['framesDecoded'] > first['video']['framesDecoded'], report
            s.ask('press', code=13, chars='w', mods=['cmd'])
            print(f"{policy}: received sizes {sorted({(x['width'], x['height']) for x in report['samples'][5:]})}", flush=True)
        print(f'ok: 6 synthetic calls, received 1 kHz tone and colours; detail preserves 1280×720; Meet remains unqualified; {output}')


if __name__ == '__main__':
    main()
