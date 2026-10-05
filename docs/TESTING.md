# Testing Escale

Protect user data, page behaviour and resource limits with the smallest test
that can expose the failure. Use fast tests for rules and persistence, and the
bench for real application behaviour.

## Run the checks

One entry point, from the repository root. It needs only Python's standard
library and the toolchain:

```sh
./verify run                     # final checks selected from the change
./verify run --quick             # iteration: defers automatic app checks, the Swift suite for app-only edits, and warnings
./verify run --risk routes       # add the checks for a behaviour the paths cannot reveal
./verify run --check swift       # add one named check
./verify run --jobs 1            # app checks one after another (default: 3 at once)
./verify plan                    # preview the selection
./verify status                  # are the last results still valid for this tree?
./verify report                  # print the last summary again
./verify report --export PATH    # copy the last report and its evidence for review
./verify clean --days 14         # remove this checkout's old, inactive evidence
```

The [catalogue](../Tests/Verification/catalog.py) compares the tree, dirty and
untracked files included, with its merge base with `origin/main` (`--base REF`
changes it). `./verify --help` lists every check and risk.

| Changed paths | Checks selected |
|---|---|
| Any change | `whitespace` |
| Markdown | `links` |
| `changelog.d/*.md`, `CHANGELOG.md`, `NOTES.md`, `changelog` | `changelog` |
| App sources and resources | `build`, `swift`; `warnings` when a Swift file or `build.sh` changes |
| `Tests/EscaleTests/`, `test.sh` | `swift` |
| `Tests/Verification/`, `verify` | `harness` |
| `Tests/Bench/test_*.py`, `Tests/Bench/resource_*.py` | `portable` |
| `Tests/Bench/suite.py`, `diagnostics.py`, `bench`, `fresh.sh`, `Sources/Escale/Bench/` | `harness` and every app check |
| A file listed in a check's `paths` | That check: a fast Swift filter such as `icons`, or an app scenario |

App checks need `bundle` (`./build.sh debug`), which needs `build`. A changed
path that matches nothing is listed as unmapped: name the checks you ran and
why with `--acknowledge "…"`.

Risks add the checks that a path cannot reveal:

| Risk | Checks |
|---|---|
| `app` | `app` (load, close, lazy restore, typed draft, sleep) |
| `icons` | `icons`, `favicon`, `icon-lists` |
| `keyboard` | `keyboard` |
| `navigation` | `navigation`, `navigation-command-click`, `history-menus` |
| `address` | `address`, `keyboard`, `habits` |
| `chrome` | `chrome` |
| `routes` | `routes` |
| `calls` | `calls`, `calls-browse` |
| `visual` | nothing runs; the report asks for a [visual review](DESIGN.md#visual-review) |
| `resources` | nothing runs; the report asks for a measurement under [PERFORMANCE](PERFORMANCE.md) |

Select by behaviour and risk, not by diff size. A short diff to a UI action
still needs that action exercised; a cross-cutting change needs each affected
journey and transition. Stop adding checks once the possible failures are
covered.

A green run means the named assertions passed, nothing more.

## Results and app checks

`run` prints a short summary for the pull request. Logs and receipts stay in
`build/verification/`; scenarios also keep logs in
`build/bench-diagnostics/<world>/`. An unchanged result is reused; a change to
its inputs, the toolchain or the engine invalidates it, and missing evidence
makes it stale. Nothing is retried; `--force` reruns a check.

Each app check launches a frozen copy of the bundle through `fresh.sh` in a
world of its own, and cleans it up after keeping diagnostics. A check marked
`foreground` in the catalogue needs the keyboard or pointer (a live click,
`bench pointer`, a native menu, a page's own key handling): it runs in front,
one at a time. The others open behind (`ESCALE_BACKGROUND=1`) and run beside
it. Leave the Mac alone while foreground checks run: typing in another app can
keep the keyboard there and fail them.

## CI

The [workflow](../.github/workflows/ci.yml) runs on every pull request and on
`main`, on a GitHub-hosted macOS runner without secrets: whitespace of the pull
request's lines, `swift build`, `./test.sh`, the harness tests
(`python3 -m unittest discover -s Tests/Verification`) and the resource tooling
tests. It never launches the app. App scenarios and the warnings comparison
stay local; a pull request reports them under its verification.

## Build warnings

`swift build` must add no new warnings. The `warnings` check compares a clean
build with the change's base on the same toolchain. Fixing an existing warning
is a separate change.

## Pick the layer

| Failure | Layer |
|---|---|
| A rule: parsing, ranking, bounds, geometry | Unit test in `Tests/EscaleTests`, run with `./test.sh --filter <Suite>` |
| Persistence: ordering, flush, deletion, decoding, errors | Swift test on the real writer and files in a temporary folder, never default storage |
| Wiring, UI, WebKit, restart, page lifetime | App scenario in `Tests/Bench` |
| How it looks | [Visual review](DESIGN.md#visual-review) |
| Memory, CPU, wakeups, launch | Measurement under [PERFORMANCE](PERFORMANCE.md) |
| Private API, WebKit workaround, extension | [COMPATIBILITY](COMPATIBILITY.md) and `Tests/Bench/compatibility.py` |

`--filter` matches a `@Suite` name, such as `HabitsRankingTests` or
`LinkRuleTests`, not a file name.

## Writing tests

- Test observable requirements, including empty, invalid, failure and boundary
  cases. Parameterised unit tests cover combinations; one scenario proves the
  rule is wired in. Do not replay every combination through WebKit.
- Use Swift Testing in the one `EscaleTests` target. No new module, copied
  source or mocking framework.
- Give each test its own folder and state. Never initialise app singletons or
  default storage to test a rule.
- Wait for a state with a deadline (`wait_for`, `until`), never a fixed pause.
  A sleep hides the race the test should see, and a retry that passes proves
  nothing.
- A scenario proves a journey only through the user's entry point: setting a
  DOM value with JavaScript does not prove keyboard input or focus.
- Show that a regression fails before its fix and passes after. The "before"
  variant reproduces the original inputs exactly; a partial revert can pass on
  broken code.
- A layout test proves it reached the condition that switches the layout; a
  green run that never crossed it proves nothing.
- A transition is proven by the intermediate frames of a real window video,
  not by a declared duration. `NSAppearance(named:)` never yields increased
  contrast: test contrast rules as pure functions.
- Assert on meaningful state, not private layout, translated strings or a copy
  of the algorithm. Every fixed bug gets a regression at the right layer; an
  unautomated check is reported as such.

## Adding a bench scenario or command

A scenario is a script in `Tests/Bench` built on the shared runner,
`suite.py`: an owned random world, a loopback fixture, `wait_for` with
deadlines, diagnostics before cleanup. Its docstring says what it covers and
what it does not. Fixtures are local and synthetic: no personal profile, live
website or store download. To run under `verify`, register it in
[catalog.py](../Tests/Verification/catalog.py) with its `paths` and
`foreground` when it activates the app; the harness checks that flag. Repeat a
parallel campaign a few times before trusting it: a failure one run in three
does not show alone.

Reuse existing bench actions first. A new command is small, reusable, works on
production behaviour, mutates only a test world, creates no pages (`Tab.built`,
not `Tab.web`), adds no work when unused, and is documented in `./bench help`.
It returns state; the scenario decides pass or fail. Change the Python client,
the Swift handler and the affected scenarios together. The
[bench skill](../.agents/skills/escale-bench/SKILL.md) covers driving the app.

## Finding scenarios

`./verify plan` lists each selected check with what it asserts, and
`catalog.py` maps it to its script; each script's docstring says what it
covers. Scripts that end in `_resources.py` are measurement tools, run as
[PERFORMANCE](PERFORMANCE.md) describes. A script outside the catalogue runs
directly: `python3 Tests/Bench/NAME.py`.

## Build mode

Scenarios run against `./build.sh debug`. Measurements need the optimized
bundle from `./build.sh`.
