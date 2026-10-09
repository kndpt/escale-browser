"""Keep verification proportional without losing app or isolation checks.

These cases use real repository concerns, including small edits to sensitive
owners. Selection depends on affected behaviour, never line counts or models.
They run without launching Escale; runtime integration is checked separately.
"""
from pathlib import Path
import re
import unittest

from catalog import CHECKS, plan

ROOT = Path(__file__).resolve().parents[2]


class WorkflowTests(unittest.TestCase):
    def test_docs_are_the_same_light_path_in_both_modes(self):
        for path in ('docs/TESTING.md', 'docs/ARCHITECTURE.md'):
            for quick in (False, True):
                with self.subTest(path=path, quick=quick):
                    self.assertEqual(set(plan([path], quick=quick)['checks']),
                                     {'links', 'whitespace'})

    def test_preferences_select_rules_and_the_shortcut_journey(self):
        selected = plan(['Sources/Escale/Settings/Prefs.swift'])
        self.assertFalse(selected['unknown'])
        self.assertEqual(set(selected['checks']),
                         {'whitespace', 'build', 'swift', 'warnings', 'bundle', 'shortcut-motion'})

    def test_shortcut_motion_follows_commands_preferences_and_both_layouts(self):
        for path in ('Sources/Escale/App/App.swift', 'Sources/Escale/Browser/Browser.swift',
                     'Sources/Escale/Settings/Prefs.swift', 'Sources/Escale/Settings/Settings.swift',
                     'Sources/Escale/Window/TabBar.swift', 'Sources/Escale/Window/Side.swift',
                     'Sources/Escale/Window/PanelStage.swift', 'Sources/Escale/Design/Design.swift',
                     'Sources/Escale/Design/ShortcutMotion.swift'):
            with self.subTest(path=path):
                selected = plan([path])['checks']
                self.assertIn('shortcut-motion', selected)
                self.assertLess(selected.index('bundle'), selected.index('shortcut-motion'))
                self.assertNotIn('shortcut-motion', plan([path], quick=True)['checks'])

    def test_speech_bridge_owner_and_fixture_select_native_playback(self):
        for path in ('Sources/Escale/App/Links.swift',
                     'Sources/Escale/Extensions/ExtensionSpeech.swift',
                     'Sources/Escale/Extensions/ExtensionShims.swift',
                     'Sources/Escale/Extensions/Extensions.swift',
                     'Tests/Bench/fixtures/speech-extension/manifest.json'):
            with self.subTest(path=path):
                selected = plan([path])
                self.assertFalse(selected['unknown'])
                self.assertIn('extension-speech', selected['checks'])
                self.assertLess(selected['checks'].index('bundle'), selected['checks'].index('extension-speech'))
                self.assertNotIn('extension-speech', plan([path], quick=True)['checks'])
        selected = plan([], checks=['extension-speech'], quick=True)
        self.assertIn('extension-speech', selected['checks'])

    def test_new_feature_file_is_known_but_does_not_invent_app_coverage(self):
        selected = plan(['Sources/Escale/Page/NewFeature.swift'])
        self.assertFalse(selected['unknown'])
        self.assertIn('swift', selected['checks'])
        self.assertNotIn('app', selected['checks'])

    def test_harness_report_edit_does_not_compile_the_browser(self):
        selected = plan(['Tests/Verification/run.py', 'Tests/Verification/test_verify.py'])
        self.assertEqual(set(selected['checks']), {'harness', 'whitespace'})

    def test_quick_compiles_but_defers_automatic_app_journeys(self):
        selected = plan(['Sources/Escale/Address/NewTab.swift'], quick=True)
        self.assertEqual(set(selected['checks']), {'whitespace', 'build'})
        explicit = plan(['Sources/Escale/Address/NewTab.swift'], risks=['keyboard'], quick=True)
        self.assertIn('keyboard', explicit['checks'])
        self.assertLess(explicit['checks'].index('bundle'), explicit['checks'].index('keyboard'))

    def test_quick_honors_explicit_checks_and_their_prerequisites(self):
        selected = plan([], checks=['swift', 'warnings', 'routes'], quick=True)
        self.assertEqual(set(selected['checks']),
                         {'whitespace', 'build', 'swift', 'warnings', 'bundle', 'routes'})
        self.assertLess(selected['checks'].index('build'), selected['checks'].index('swift'))
        self.assertLess(selected['checks'].index('bundle'), selected['checks'].index('routes'))

    def test_small_sensitive_change_still_gets_app_checks(self):
        for path in ('Sources/Escale/Storage/Store.swift', 'Sources/Escale/Tabs/Sleep.swift',
                     'Sources/Escale/Spaces/Session.swift', 'Sources/Escale/Browser/Browser.swift'):
            with self.subTest(path=path):
                self.assertIn('app', plan([path])['checks'])

    def test_wake_callbacks_and_bench_state_select_the_wake_regression(self):
        for path in ('Sources/Escale/Browser/Browser.swift', 'Sources/Escale/Bench/Bench.swift'):
            with self.subTest(path=path):
                selected = plan([path])
                self.assertIn('wake', selected['checks'])
                self.assertEqual(CHECKS['wake'].command, ('python3', 'Tests/Bench/wake_transition.py'))
                self.assertLess(selected['checks'].index('bundle'), selected['checks'].index('wake'))

    def test_update_gate_routes_its_scenario(self):
        for path in ('Sources/Escale/App/GatePanel.swift', 'Sources/Escale/App/Updater.swift'):
            with self.subTest(path=path):
                selected = plan([path])
                self.assertFalse(selected['unknown'])
                self.assertIn('update', selected['checks'])
                self.assertLess(selected['checks'].index('bundle'), selected['checks'].index('update'))
        self.assertEqual(CHECKS['update'].command, ('python3', 'Tests/Bench/update_gate.py'))

    def test_learned_ranking_routes_its_scenario(self):
        for path in ('Sources/Escale/Address/Habits.swift', 'Sources/Escale/Address/Field.swift'):
            with self.subTest(path=path):
                selected = plan([path])
                self.assertFalse(selected['unknown'])
                self.assertIn('habits', selected['checks'])
                self.assertLess(selected['checks'].index('bundle'), selected['checks'].index('habits'))
        self.assertIn('habits', plan([], risks=['address'])['checks'])
        self.assertEqual(CHECKS['habits'].command, ('python3', 'Tests/Bench/bearings_habits.py'))

    def test_history_panel_routes_its_scenario(self):
        selected = plan(['Sources/Escale/History/Recall.swift'])
        self.assertFalse(selected['unknown'])
        self.assertIn('history-panel', selected['checks'])
        self.assertEqual(CHECKS['history-panel'].command, ('python3', 'Tests/Bench/history_panel.py'))
        self.assertLess(selected['checks'].index('bundle'), selected['checks'].index('history-panel'))
        # Slice, the lazy list's card, lives beside Card.
        self.assertIn('history-panel', plan(['Sources/Escale/Design/Plate.swift'])['checks'])

    def test_routes_use_the_existing_real_scenario(self):
        selected = plan(['Sources/Escale/Spaces/LinkRule.swift',
                         'Sources/Escale/Spaces/LinkRoutes.swift', 'Tests/Bench/link_routes.py'])
        self.assertFalse(selected['unknown'])
        self.assertIn('routes', selected['checks'])
        self.assertEqual(CHECKS['routes'].command, ('python3', 'Tests/Bench/link_routes.py'))
        self.assertLess(selected['checks'].index('bundle'), selected['checks'].index('routes'))

    def test_calls_panel_selects_its_scenario(self):
        for path in ('Sources/Escale/Page/Calls.swift', 'Sources/Escale/Page/Inspector.swift',
                     'Sources/Escale/Page/Developer.swift', 'Sources/Escale/Page/Curl.swift',
                     'Sources/Escale/Page/Scripts/calls.js', 'Tests/Bench/network_calls.py'):
            with self.subTest(path=path):
                selected = plan([path])
                self.assertFalse(selected['unknown'])
                self.assertIn('calls', selected['checks'])
                self.assertLess(selected['checks'].index('bundle'), selected['checks'].index('calls'))

    def test_calls_browsing_selects_its_scenario(self):
        for path in ('Sources/Escale/Page/CallSearch.swift', 'Sources/Escale/Page/CallsPanel.swift',
                     'Sources/Escale/Page/Scripts/calls.js', 'Tests/Bench/network_calls_browse.py'):
            with self.subTest(path=path):
                selected = plan([path])
                self.assertFalse(selected['unknown'])
                self.assertIn('calls-browse', selected['checks'])
                self.assertLess(selected['checks'].index('bundle'), selected['checks'].index('calls-browse'))

    def test_meeting_scenarios_follow_the_floating_window_and_space_switch(self):
        for path, expected in (('Sources/Escale/Page/Float.swift', {'call-float'}),
                               ('Sources/Escale/Page/Scripts/isolate-on.js', {'call-float'}),
                               ('Sources/Escale/Browser/Browser.swift', {'call-float'}),
                               ('Sources/Escale/Spaces/Spaces.swift', {'call-float', 'space-media'}),
                               ('Sources/Escale/Tabs/Tab.swift', {'call-float', 'space-media'}),
                               ('Sources/Escale/Spaces/Presence.swift', {'space-media'}),
                               ('Tests/Bench/fixtures/call/index.html', {'call-float', 'space-media'})):
            with self.subTest(path=path):
                selected = plan([path])
                self.assertFalse(selected['unknown'])
                self.assertTrue(expected <= set(selected['checks']))
                self.assertLess(selected['checks'].index('bundle'), selected['checks'].index(next(iter(expected))))
        self.assertEqual(CHECKS['call-float'].command, ('python3', 'Tests/Bench/call_float.py'))
        self.assertEqual(CHECKS['space-media'].command, ('python3', 'Tests/Bench/space_media.py'))

    def test_rail_code_selects_the_space_reorder_scenario(self):
        for path in ('Sources/Escale/Spaces/Spaces.swift', 'Sources/Escale/Spaces/SpaceReorder.swift',
                     'Sources/Escale/App/App.swift', 'Tests/Bench/space_reorder.py'):
            with self.subTest(path=path):
                selected = plan([path])
                self.assertIn('space-reorder', selected['checks'])
                self.assertLess(selected['checks'].index('bundle'), selected['checks'].index('space-reorder'))
        self.assertTrue(CHECKS['space-reorder'].foreground)

    def test_tab_opening_and_closing_code_selects_the_source_tab_scenario(self):
        for path in ('Sources/Escale/Browser/Browser.swift', 'Sources/Escale/Spaces/LinkRoutes.swift',
                     'Sources/Escale/Tabs/Tab.swift', 'Tests/Bench/tab_source.py'):
            with self.subTest(path=path):
                selected = plan([path])
                self.assertIn('tab-source', selected['checks'])
                self.assertLess(selected['checks'].index('bundle'), selected['checks'].index('tab-source'))
        self.assertEqual(CHECKS['tab-source'].command, ('python3', 'Tests/Bench/tab_source.py'))

    def test_shared_launcher_selects_all_supported_app_scenarios(self):
        for path in ('fresh.sh', 'bench', 'Tests/Bench/suite.py', 'Tests/Bench/diagnostics.py'):
            with self.subTest(path=path):
                selected = plan([path])
                self.assertIn('harness', selected['checks'])
                self.assertTrue(all(name in selected['checks'] for name, check in CHECKS.items()
                                    if check.category == 'app'))

    def test_visual_risk_only_records_a_pending_review(self):
        selected = plan(['Sources/Escale/Settings/Settings.swift'], risks=['visual'])
        self.assertTrue(selected['observations'])
        self.assertEqual(selected['checks'], plan(['Sources/Escale/Settings/Settings.swift'])['checks'])

    def test_resource_collector_edit_only_runs_its_tests(self):
        selected = plan(['Tests/Bench/resource_baseline.py'])
        self.assertEqual(set(selected['checks']), {'portable', 'whitespace'})

    def test_unknown_tool_requires_an_explicit_scope_decision(self):
        selected = plan(['tools/new-tool.sh'])
        self.assertEqual(selected['unknown'], ['tools/new-tool.sh'])
        self.assertIsNone(selected['acknowledge'])

    def test_clean_checkout_does_not_trigger_app_work(self):
        self.assertEqual(plan([])['checks'], ['whitespace'])


if __name__ == '__main__':
    unittest.main()


class LaneTests(unittest.TestCase):
    """A check that brings its app to the front runs in front: behind, it would
    take the keyboard from the foreground check or from the person at the Mac."""
    ACTIVATING = re.compile(r"""(,\s*['"]live['"]\s*\)|live=True|\(\s*['"]pointer['"]|['"]open['"],\s*['"]-[ab]['"]|external\()""")

    def test_app_checks_that_activate_their_app_are_foreground(self):
        for name, check in CHECKS.items():
            if check.category != "app":
                continue
            script = (ROOT / check.command[-1]).read_text()
            with self.subTest(check=name):
                if self.ACTIVATING.search(script):
                    self.assertTrue(check.foreground, f"{name} activates its app but runs behind")
