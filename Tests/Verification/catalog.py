"""Select checks by affected inputs; the agent adds behavioural risks.

Local rules, app journeys and shared infrastructure have different costs.
Quick runs defer automatic app checks; explicit requests always take precedence.
File hints cannot prove a feature, and unknown tooling stays visible.
"""
from dataclasses import dataclass
from fnmatch import fnmatch

APP = ("Sources/Escale/**", "Package.swift", "Icon/**", "VERSION", "GITHUB_CLIENT_ID", "GITHUB_APP_SLUG", "LICENSE", "NOTICE",
       "notify", "Escale*.entitlements", "Escale.provisionprofile", "build.sh")
SWIFT = APP + ("Tests/EscaleTests/**", "test.sh")
BENCH = APP + ("bench", "fresh.sh", "Tests/Bench/suite.py", "Tests/Bench/diagnostics.py")
ENGINE = ("verify", "Tests/Verification/catalog.py", "Tests/Verification/run.py",
          "Tests/Verification/evidence.py", "Tests/Verification/compiler.py")
SHARED_BENCH = ("bench", "fresh.sh", "Tests/Bench/suite.py", "Tests/Bench/diagnostics.py",
                "Sources/Escale/Bench/**")


@dataclass(frozen=True)
class Check:
    name: str
    command: tuple
    inputs: tuple
    risks: str
    category: str = "fast"
    needs: tuple = ()
    timeout: int = 600
    paths: tuple = ()
    # An app check that needs the keyboard and pointer of the Mac: it runs in
    # front, one at a time; the others run behind it, side by side.
    foreground: bool = False


CHECKS = {
    c.name: c for c in (
        Check("harness", ("python3", "-m", "unittest", "discover", "-s", "Tests/Verification"),
              ("Tests/Verification/**", "Tests/Bench/diagnostics.py", "Tests/Bench/suite.py", "fresh.sh",
               "Tests/Bench/navigation_history.py", "Tests/Bench/address_field.py", "Tests/Bench/glass_frame.py"),
              "selection, invalidation, interruption, diagnostics and receipt integrity"),
        Check("portable", ("python3", "-m", "unittest", "discover", "-s", "Tests/Bench", "-p", "test_*.py"),
              ("Tests/Bench/test_*.py", "Tests/Bench/resource_*.py"),
              "resource archive and collector invariants"),
        Check("links", ("python3", "Tests/Verification/check_links.py"),
              ("**",),
              "local documentation destinations and anchors"),
        Check("whitespace", ("git", "diff", "--check"), ("**",), "changed-line whitespace"),
        Check("changelog", ("./changelog", "check"), ("**",),
              "each change note is one well-formed paragraph and CHANGELOG.md keeps one Unreleased heading",
              paths=("changelog.d/*.md", "changelog", "CHANGELOG.md", "NOTES.md", "Tests/Verification/fragments.py")),
        Check("icons", ("./test.sh", "--filter", "IconSizeTests|IconListTests"), SWIFT,
              "favicon pixels, proportions, legacy and versioned PNGs; lists never read an icon while drawn",
              paths=("Sources/Escale/Tabs/Icons.swift", "Tests/EscaleTests/IconsTests.swift")),
        Check("build", ("swift", "build"), APP, "compilation"),
        Check("swift", ("./test.sh",), SWIFT, "all Swift rules and persistence regressions", needs=("build",)),
        Check("warnings", (), APP, "clean build diagnostics compared with the base, same toolchain",
              needs=("build",), timeout=1200),
        Check("bundle", ("./build.sh", "debug"), APP, "source-to-bundle provenance", needs=("build",)),
        Check("app", ("python3", "Tests/Bench/suite.py"), BENCH,
              "load/close, lazy restore, real-key draft and sleep failure paths", "app", ("bundle",),
              paths=("Sources/Escale/App/App.swift", "Sources/Escale/Browser/Browser.swift",
                     "Sources/Escale/Tabs/Tab.swift", "Sources/Escale/Tabs/Sleep.swift",
                     "Sources/Escale/Storage/**", "Sources/Escale/Spaces/Session.swift",
                     "Sources/Escale/Spaces/Spaces.swift", "Sources/Escale/Spaces/SpaceCopy.swift",
                     "Package.swift", "build.sh", ".github/workflows/ci.yml")),
        Check("wake", ("python3", "Tests/Bench/wake_transition.py"),
              BENCH + ("Tests/Bench/wake_transition.py",),
              "commit versus paint, preview expiry, scroll/history, Space return, pressure and process loss",
              "app", ("bundle",),
              paths=("Sources/Escale/Browser/Browser.swift", "Sources/Escale/Tabs/Tab.swift", "Sources/Escale/Tabs/Sleep.swift",
                     "Sources/Escale/Tabs/Pictures.swift", "Sources/Escale/Window/Stage.swift")),
        Check("sleeping", ("python3", "Tests/Bench/sleep_indicator.py"),
              BENCH + ("Tests/Bench/sleep_indicator.py",),
              "automatic tab/bookmark state, wake, critical pressure, closed pins and lazy restore",
              "app", ("bundle",),
              paths=("Sources/Escale/Tabs/Tab.swift", "Sources/Escale/Tabs/Sleeping.swift",
                     "Sources/Escale/Window/TabBar.swift", "Sources/Escale/Window/Side.swift",
                     "Sources/Escale/Bookmarks/Shelf.swift")),
        Check("tabs", ("python3", "Tests/Bench/tab_clear.py"),
              BENCH + ("Tests/Bench/tab_clear.py",),
              "Clear at the Tabs heading: loose tabs only, landing, other Space and a real click", "app", ("bundle",),
              paths=("Sources/Escale/Bookmarks/Shelf.swift", "Sources/Escale/Browser/Browser.swift"),
              foreground=True),
        Check("shortcut-motion", ("python3", "Tests/Bench/shortcut_motion.py"),
              BENCH + ("Tests/Bench/shortcut_motion.py",),
              "shortcut bursts, stable tab slots, pointer origin, create/close and persisted pace in both layouts",
              "app", ("bundle",),
              paths=("Sources/Escale/Design/ShortcutMotion.swift", "Sources/Escale/Design/Design.swift",
                     "Sources/Escale/App/App.swift", "Sources/Escale/Browser/Browser.swift",
                     "Sources/Escale/Settings/Prefs.swift", "Sources/Escale/Settings/Settings.swift",
                     "Sources/Escale/Window/TabBar.swift", "Sources/Escale/Window/Side.swift",
                     "Sources/Escale/Window/PanelStage.swift", "Tests/EscaleTests/ShortcutMotionTests.swift"),
              foreground=True),
        Check("sidebar-rows", ("python3", "Tests/Bench/sidebar_row_slots.py"),
              BENCH + ("Tests/Bench/sidebar_row_slots.py",),
              "Tabs rows stay on their slots while the column swaps its plain and scrolling copies",
              "app", ("bundle",),
              paths=("Sources/Escale/Window/Side.swift", "Sources/Escale/Bookmarks/Shelf.swift")),
        Check("tab-search-button", ("python3", "Tests/Bench/tab_search_button.py"),
              BENCH + ("Tests/Bench/tab_search_button.py",),
              "visible tab search: pointer equals Cmd K, focus, typing, selection and cancellation across layouts",
              "app", ("bundle",),
              paths=("Sources/Escale/Window/TabSearchDoor.swift", "Sources/Escale/Window/Side.swift",
                     "Sources/Escale/Window/Bar.swift", "Sources/Escale/Window/TabBar.swift",
                     "Tests/Bench/tab_search_button.py"),
              foreground=True),
        Check("capture-area", ("python3", "Tests/Bench/page_capture_area.py"),
              BENCH + ("Tests/Bench/page_capture_area.py", "Tests/Bench/page_visual_tools.py"),
              "Select Area: drawn, adjusted and captured rectangle, cancellation and no event reaching the page",
              "app", ("bundle",),
              paths=("Sources/Escale/Page/AreaPick.swift", "Sources/Escale/Page/PageCapture.swift",
                     "Sources/Escale/Page/CaptureBounds.swift", "Sources/Escale/Page/Scripts/capture-bounds.js",
                     "Sources/Escale/Window/PanelStage.swift"),
              foreground=True),
        Check("favicon", ("python3", "Tests/Bench/icon_alignment.py"),
              BENCH + ("Tests/Bench/icon_alignment.py",), "fetch, legacy cache and restart", "app", ("icons", "bundle"),
              paths=("Sources/Escale/Tabs/Icons.swift", "Tests/EscaleTests/IconsTests.swift")),
        Check("icon-lists", ("python3", "Tests/Bench/icon_lists.py"),
              BENCH + ("Tests/Bench/icon_lists.py",),
              "a 500-bookmark shelf draws, then holds every icon read in the background", "app", ("bundle",),
              paths=("Sources/Escale/Tabs/Icons.swift", "Sources/Escale/Bookmarks/Shelf.swift",
                     "Sources/Escale/Bookmarks/Bookmarks.swift")),
        Check("keyboard-settings", ("python3", "Tests/Bench/keyboard_settings.py"),
              BENCH + ("Tests/Bench/keyboard_settings.py",),
              "custom keys, inactive old bindings, Space order/wrap/disable, AZERTY, restart and native typing",
              "app", ("bundle",),
              paths=("Sources/Escale/Keyboard/**", "Tests/Bench/keyboard_settings.py"),
              foreground=True),
        Check("github-search", ("python3", "Tests/Bench/github_search.py"),
              BENCH + ("Tests/Bench/github_search.py",),
              "GitHub local grouping, native keys, shared replies, stable selection, tab reuse, reference offer and private search",
              "app", ("bundle",), paths=("Sources/Escale/GitHub/**", "Sources/Escale/Address/Field.swift",
              "Sources/Escale/Address/Omnibox.swift", "Sources/Escale/Keyboard/**", "Tests/Bench/github_search.py")),
        Check("keyboard", ("python3", "Tests/Bench/new_tab_search.py"),
              BENCH + ("Tests/Bench/new_tab_search.py",),
              "actual keys, focus, recents, environments, no duplicate page and privacy", "app", ("bundle",),
              paths=("Sources/Escale/Address/NewTab.swift", "Sources/Escale/Address/Field.swift",
                     "Sources/Escale/Address/SearchEnvironments.swift",
                     "Tests/EscaleTests/FieldTests.swift"),
              foreground=True),
        Check("habits", ("python3", "Tests/Bench/bearings_habits.py"),
              BENCH + ("Tests/Bench/bearings_habits.py",),
              "rows taken by Return, click action and environment lead their query; walking, private search "
              "and other queries learn nothing; relaunch, Space deletion and Clear History",
              "app", ("bundle",),
              paths=("Sources/Escale/Address/Habits.swift", "Sources/Escale/Address/Field.swift",
                     "Sources/Escale/Address/SearchEnvironments.swift", "Tests/EscaleTests/HabitsTests.swift")),
        Check("commands", ("python3", "Tests/Bench/bearings_commands.py"),
              BENCH + ("Tests/Bench/bearings_commands.py",),
              "> in New Tab lists available commands only; Return runs one, closes Bearings and makes no tab",
              "app", ("bundle",),
              paths=("Sources/Escale/Address/Field.swift", "Sources/Escale/Address/Omnibox.swift",
                     "Sources/Escale/Browser/Browser.swift", "Sources/Escale/Keyboard/KeyCommand.swift",
                     "Sources/Escale/Keyboard/KeyRouting.swift", "Tests/EscaleTests/FieldTests.swift")),
        Check("environments", ("python3", "Tests/Bench/environment_hosts.py"),
              BENCH + ("Tests/Bench/environment_hosts.py",),
              "host labels, ambiguity, saved destinations, search/capture and sleeping bookmark isolation",
              "app", ("bundle",),
              paths=("Sources/Escale/Bookmarks/Environments.swift", "Tests/EscaleTests/BookmarkEnvironmentsTests.swift",
                     "Sources/Escale/Address/Field.swift", "Sources/Escale/Address/SearchEnvironments.swift")),
        Check("navigation", ("python3", "Tests/Bench/navigation_history.py"),
              BENCH + ("Tests/Bench/navigation_history.py",),
              "recent history order and direct backward/forward jumps", "app", ("bundle",),
              paths=("Sources/Escale/Window/HistoryDoor.swift",)),
        Check("navigation-command-click", ("python3", "Tests/Bench/navigation_command_click.py"),
              BENCH + ("Tests/Bench/navigation_command_click.py",),
              "native Command-click Back, Forward and Reload preserve the source and open in its Space/privacy context",
              "app", ("bundle",),
              paths=("Sources/Escale/Window/HistoryDoor.swift", "Sources/Escale/Window/TabBar.swift"),
              foreground=True),
        Check("history-menus", ("python3", "Tests/Bench/navigation_controls.py"),
              BENCH + ("Tests/Bench/navigation_controls.py",),
              "held native Back/Forward menus reopen at the current entry with readable labels and exact URLs",
              "app", ("bundle",),
              paths=("Sources/Escale/Window/HistoryDoor.swift", "Sources/Escale/Bench/BenchPointer.swift"),
              foreground=True),
        Check("update", ("python3", "Tests/Bench/update_gate.py"),
              BENCH + ("Tests/Bench/update_gate.py",),
              "update door and panels: download to relaunch, Escape, the updater's relaunch keeps tabs, arrival once",
              "app", ("bundle",),
              paths=("Sources/Escale/App/Gate.swift", "Sources/Escale/App/GatePanel.swift",
                     "Sources/Escale/App/Updater.swift", "Sources/Escale/Bench/UpdateBench.swift")),
        Check("history-panel", ("python3", "Tests/Bench/history_panel.py"),
              BENCH + ("Tests/Bench/history_panel.py",),
              "History panel over a full history: open, close and search states, lazy-list guard",
              "app", ("bundle",),
              paths=("Sources/Escale/History/Recall.swift", "Sources/Escale/History/History.swift",
                     "Sources/Escale/Design/Plate.swift")),
        Check("address", ("python3", "Tests/Bench/address_field.py"),
              BENCH + ("Tests/Bench/address_field.py",),
              "real typing, suggestions, focus, switcher, refusal and Space transition", "app", ("bundle",),
              paths=("Sources/Escale/Address/Field.swift", "Tests/EscaleTests/FieldTests.swift")),
        Check("keywords", ("python3", "Tests/Bench/search_keywords.py"),
              BENCH + ("Tests/Bench/search_keywords.py",),
              "a keyword's row first, nothing sent while typing, Return opens its loopback template; "
              "unknown or bare keywords stay searches", "app", ("bundle",),
              paths=("Sources/Escale/Address/Keyword.swift", "Sources/Escale/Address/Engine.swift",
                     "Sources/Escale/Address/Field.swift", "Tests/EscaleTests/KeywordTests.swift")),
        Check("chrome", ("python3", "Tests/Bench/glass_frame.py"),
              BENCH + ("Tests/Bench/glass_frame.py",),
              "page preservation, hit boundaries, Settings and appearance persistence; not visual approval",
              "app", ("bundle",),
              paths=("Sources/Escale/Design/Glass.swift", "Sources/Escale/Window/Stage.swift",
                     "Sources/Escale/Window/Fold.swift")),
        Check("routes", ("python3", "Tests/Bench/link_routes.py"),
              BENCH + ("Tests/Bench/link_routes.py",),
              "first-request store, real links, private isolation, destination deletion and restart",
              "app", ("bundle",),
              paths=("Sources/Escale/Spaces/Link*.swift", "Tests/EscaleTests/LinkRuleTests.swift"),
              foreground=True),
        Check("calls", ("python3", "Tests/Bench/network_calls.py"),
              BENCH + ("Tests/Bench/network_calls.py",),
              "API Calls: 15 loopback exchanges, bodies, shared Web Inspector session and teardown",
              "app", ("bundle",),
              paths=("Sources/Escale/Page/Call*.swift", "Sources/Escale/Page/Inspector.swift",
                     "Sources/Escale/Page/Developer.swift", "Sources/Escale/Page/Curl.swift",
                     "Sources/Escale/Page/JSONPreview.swift",
                     "Sources/Escale/Page/Scripts/calls.js", "Sources/Escale/Bench/CallsBench.swift",
                     "Tests/EscaleTests/CallTests.swift")),
        Check("calls-browse", ("python3", "Tests/Bench/network_calls_browse.py"),
              BENCH + ("Tests/Bench/network_calls_browse.py", "Tests/Bench/network_calls.py"),
              "API Calls: arrows through the list, pause, resume and Clear, search in responses",
              "app", ("bundle",),
              paths=("Sources/Escale/Page/Call*.swift", "Sources/Escale/Page/Scripts/calls.js",
                     "Sources/Escale/Page/JSONReader.swift", "Sources/Escale/Bench/CallsBench.swift",
                     "Tests/EscaleTests/CallTests.swift"),
              foreground=True),
        Check("extension-speech", ("python3", "Tests/Bench/extension_speech.py"),
              BENCH + ("Tests/Bench/extension_speech.py", "Tests/Bench/fixtures/speech-extension/**"),
              "native speech, voices/rate, pause/resume, bounded queue and unload/Space cleanup",
              "app", ("bundle",),
              paths=("Sources/Escale/App/Links.swift", "Sources/Escale/Extensions/ExtensionSpeech.swift", "Sources/Escale/Extensions/ExtensionShims.swift",
                     "Sources/Escale/Extensions/Extensions.swift", "Tests/EscaleTests/ExtensionSpeechTests.swift",
                     "Tests/Bench/fixtures/speech-extension/**")),
        Check("extension-bar", ("python3", "Tests/Bench/extension_bar.py"),
              BENCH + ("Tests/Bench/extension_bar.py", "Tests/Bench/fixtures/shim-extension/**"),
              "the bar's extension buttons follow the Space on screen across switches and layout rebuilds",
              "app", ("bundle",),
              paths=("Sources/Escale/Extensions/Extensions.swift", "Sources/Escale/Window/Bar.swift",
                     "Sources/Escale/Window/TabBar.swift", "Sources/Escale/App/App.swift",
                     "Sources/Escale/Spaces/Spaces.swift", "Tests/Bench/fixtures/shim-extension/**")),
        Check("space-media", ("python3", "Tests/Bench/space_media.py"),
              BENCH + ("Tests/Bench/space_media.py", "Tests/Bench/calls.py", "Tests/Bench/media_player.py",
                       "Tests/Bench/fixtures/call/**"),
              "a meeting, song and film survive Space changes with camera, microphone and sleep rules",
              "app", ("bundle",),
              paths=("Sources/Escale/Spaces/Spaces.swift", "Sources/Escale/Spaces/Presence.swift", "Sources/Escale/Tabs/Media.swift",
                     "Sources/Escale/Tabs/Tab.swift", "Tests/Bench/calls.py", "Tests/Bench/media_player.py", "Tests/Bench/fixtures/call/**"),
              foreground=True),
        Check("call-float", ("python3", "Tests/Bench/call_float.py"),
              BENCH + ("Tests/Bench/call_float.py", "Tests/Bench/calls.py", "Tests/Bench/media_player.py",
                       "Tests/Bench/fixtures/call/**"),
              "the meeting window: people, whole shared screen, the page's commands, cameras off, Spaces, sleep, end",
              "app", ("bundle",),
              paths=("Sources/Escale/Page/Float.swift", "Sources/Escale/Page/Meeting.swift",
                     "Sources/Escale/Page/Scripts/meeting.js", "Sources/Escale/Page/Scripts/isolate-*.js",
                     "Sources/Escale/Browser/Browser.swift",
                     "Sources/Escale/Spaces/Spaces.swift", "Sources/Escale/Tabs/Tab.swift",
                     "Tests/Bench/calls.py",
                     "Tests/Bench/media_player.py", "Tests/Bench/fixtures/call/**"),
              foreground=True),
        Check("tab-source", ("python3", "Tests/Bench/tab_source.py"),
              BENCH + ("Tests/Bench/tab_source.py",),
              "closing a link-opened tab returns to its source; neighbour fallback otherwise",
              "app", ("bundle",),
              paths=("Sources/Escale/Browser/Browser.swift", "Sources/Escale/Spaces/LinkRoutes.swift",
                     "Sources/Escale/Tabs/Tab.swift")),
    )
}
RISK_CHECKS = {"app": ("app",), "icons": ("icons", "favicon", "icon-lists"), "keyboard": ("keyboard",),
               "navigation": ("navigation", "navigation-command-click", "history-menus"), "address": ("address", "keyboard", "habits"), "chrome": ("chrome",),
               "routes": ("routes",), "calls": ("calls", "calls-browse"), "visual": (), "resources": ()}


def plan(paths, risks=(), checks=(), quick=False, acknowledge=None):
    """Explain hints, explicit choices and gaps without inventing coverage."""
    chosen = {"whitespace": "changed-line whitespace"}
    unknown = []
    for name in checks:
        chosen[name] = "explicit check"
    for risk in risks:
        for name in RISK_CHECKS[risk]:
            chosen[name] = "requested risk: " + risk
    def matches(path, patterns):
        return any(fnmatch(path, pattern) for pattern in patterns)

    def add(name, reason):
        if not quick or CHECKS[name].category != "app":
            chosen.setdefault(name, reason)

    for path in paths:
        known = False
        if path.endswith(".md") or path.startswith("docs/"):
            add("links", "documentation change")
            known = True
        if matches(path, APP):
            add("build", "application change")
            if not quick:
                add("swift", "application rules and persistence")
                if path.endswith(".swift") or path == "build.sh":
                    add("warnings", "changed compiler inputs")
            known = True
        if matches(path, ("Tests/EscaleTests/**", "test.sh")):
            add("swift", "Swift tests changed")
            known = True
        if matches(path, ("Tests/Verification/**", "verify")):
            add("harness", "verification code or tests changed")
            known = True
        if matches(path, ("Tests/Bench/test_*.py", "Tests/Bench/resource_*.py")):
            add("portable", "resource tooling or fixtures changed")
            known = True
        if matches(path, SHARED_BENCH):
            add("harness", "shared app test infrastructure changed")
            for name, check in CHECKS.items():
                if check.category == "app":
                    add(name, "shared app test infrastructure changed")
            known = True
        if path == ".github/workflows/ci.yml":
            for name in ("harness", "portable", "build", "swift"):
                add(name, "CI recipe changed")
            known = True
        if path == "Tests/Verification/check_links.py":
            add("links", "link checker changed")
            known = True
        for name, check in CHECKS.items():
            if path in check.command or matches(path, check.paths):
                add(name, "affected scenario: " + path)
                known = True
        if not known and path not in (".gitignore", ".gitattributes"):
            unknown.append(path)
    for name in tuple(chosen):
        def include_dependencies(key):
            for dep in CHECKS[key].needs:
                chosen.setdefault(dep, "prerequisite of " + key)
                include_dependencies(dep)
        include_dependencies(name)
    # Dependencies are small and explicit; no scoring or model-specific workflow.
    order = ["icons", "harness", "portable", "links", "whitespace", "changelog", "build", "swift",
             "bundle", "app", "wake", "sleeping", "tabs", "shortcut-motion", "sidebar-rows", "tab-search-button", "capture-area", "navigation", "navigation-command-click", "history-menus", "history-panel", "update", "address", "keywords", "keyboard", "keyboard-settings", "github-search", "habits", "commands", "favicon", "icon-lists", "chrome",
             "routes", "tab-source", "environments", "calls", "calls-browse", "extension-speech", "extension-bar", "space-media", "call-float", "warnings"]
    return {"checks": [n for n in order if n in chosen], "reasons": chosen,
            "risks": list(risks), "requested": list(checks),
            "unknown": unknown, "acknowledge": acknowledge, "quick": quick,
            "excluded": [n for n in CHECKS if n not in chosen],
            "observations": (["visual review of affected surfaces"] if "visual" in risks else [])
                            + (["resource qualification per docs/PERFORMANCE.md"] if "resources" in risks else [])}
