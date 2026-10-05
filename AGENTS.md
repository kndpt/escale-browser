# AGENTS.md

Escale is a native WebKit browser for developers on Mac, written in Swift.
It started from [Search](https://github.com/driceroland/Search) (Office Commun,
MIT) and is licensed under the GPL-3.0-or-later. These rules apply to people
and coding agents alike; [CONTRIBUTING](CONTRIBUTING.md) has the workflow.

## Efficiency first

Efficiency is the word to keep in mind for everything in this project.

- **The app** spends as little CPU, memory, energy and network as it can.
  Nothing runs until it is needed, and what is no longer needed is let go.
- **The code** is the smallest change that solves the problem: no speculative
  options, layers or abstractions, no dead code, no dependency.
- **The words** are short. A comment, a doc or a pull request says one thing
  once, plainly; if one sentence is enough, there is no second.

When two solutions work, choose the one that costs less to run, to read and
to maintain.

## Reference

| Decision | Reference |
|---|---|
| Product scope or a new workflow | [DIRECTION](docs/DIRECTION.md) |
| Interface, materials and controls | [DESIGN](docs/DESIGN.md) |
| Owners, lifetime, persistence, where a file goes | [ARCHITECTURE](docs/ARCHITECTURE.md) |
| Which tests, and how to run them | [TESTING](docs/TESTING.md) |
| Safe test launch and resource costs | [PERFORMANCE](docs/PERFORMANCE.md) |
| Private API, WebKit workarounds, extensions | [COMPATIBILITY](docs/COMPATIBILITY.md) |
| Assets, attackers and trust boundaries | [THREAT-MODEL](docs/THREAT-MODEL.md) |

The [documentation map](docs/README.md) lists the rest.

## Non-negotiables

- **No new external dependencies or vendored code.** Apple frameworks and the bundled toolchain only. The one test target, `EscaleTests`, is not a precedent.
- **WebKit only.** Where Chrome behaves differently, the fix belongs in Escale (see `ExtensionShims.swift`), not in another engine.
- **Nothing phones home.** No analytics, telemetry or network traffic the user didn't ask for. The README's [Privacy](README.md#privacy) section lists every request Escale makes; a new one needs a reason and a row there.
- **No force-unwraps (`!`, `try!`, `as!`) on anything that can fail at run time,** such as a network response, a file read or a keychain lookup.
- **`swift build` adds zero new warnings.**
- **Swift 5 language mode is on purpose** (`Package.swift`). No Swift 6 strict concurrency, no `Sendable` or actor ceremony.
- **A small footprint is a requirement.** A change that can cost CPU, memory or energy is measured before and after, as in [PERFORMANCE](docs/PERFORMANCE.md).

## Conventions

- **Every file opens with a prose comment** saying what the concern is and *why* it works that way (see `Sleep.swift`, `Store.swift`, `Design.swift`).
- **Comments say why, not what the next line does.** `///` doc comments are short plain sentences.
- **Names are plain words** (`Shield`, `Vault`, `Curtain`, `sleepIdle`), not `Manager`, `Service` or `Helper`. File names are unique across the target.
- **Injected JavaScript lives in a `.js` file** in the `Scripts/` folder of the domain that injects it, read with `Bundled.text`, or `Bundled.script` for a page script. One-line scripts are the exception. A new `Scripts/` folder is declared in `Package.swift`.
- **Colours come from `Palette` in `Design.swift` only**, each a light/dark pair; nothing else checks the appearance. Spacing, sizes and timings live there too (`Metrics`, `Motion`).
- **Settings go in `Preferences` (`Prefs.swift`)** as a `@Published` value backed by `Store.settings`. Defaults keep an unconfigured browser behaving as before.
- **Anything persisted goes through `Store` (`Store.swift`)**, so test runs stay apart from the real browser. Passwords live only in the keychain (`Vault.swift`).
- **The UI is SwiftUI.** AppKit only where SwiftUI can't reach (title bar, window dragging, text fields); pages are `WKWebView`.

## One concern per change

A new concern gets its own file and a concrete owner; wiring it in stays a small hook. Don't bundle refactors, moves, renames or formatting with a feature or a fix. If a change can't stay isolated, stop and ask. A separate problem found on the way is reported, not fixed in passing.

## Never touch a real browser's data

- Run the app with `./fresh.sh`, which opens a copy of `build/Escale.app` in an isolated test world under its own bundle id. Use a world per task (`ESCALE_PROBE=NAME ./fresh.sh`), and stop only processes you know are that world's.
- Never `open build/Escale.app`: it has the production identity.
- Never read, edit or delete a real install's data: `~/Library/Application Support/Escale`, the `com.kndpt.escale` defaults and its WebKit store, or an installed Search's (`~/Library/Application Support/Search`, `com.officecommun.search`).
- Test storage never falls back to production storage; `Store.admit` and `Store.settings` stop the run instead. [PERFORMANCE](docs/PERFORMANCE.md) has the safe-launch procedure.

## Before you hand it over

- `./verify run` selects and runs the checks for the changed files (`--quick` while iterating). A green run covers its named checks, not every requirement; [TESTING](docs/TESTING.md) says what else a change needs.
- A change people will notice adds a note in [changelog.d](changelog.d/README.md).
- Commits are in English: `<type>(<scope>): <subject>`.
- Report what changed, how it was verified and what it doesn't cover.

Releases are the maintainer's: don't change `VERSION`, `NOTES.md` or `CHANGELOG.md` or run `build.sh release` or `publish.sh` unless asked.

## Review guidelines

A review checks the non-negotiables above and the [threat model](docs/THREAT-MODEL.md), and flags:

- a request missing from the README's [Privacy](README.md#privacy) table, or a new dependency or vendored code;
- a message handler that trusts an origin, URL or host from the message body instead of `frameInfo`;
- a credential filled or saved across origins, frames or spaces;
- an update path that skips HTTPS, the hash or the signature check;
- a local socket that is on by default or open beyond this user;
- data persisted outside `Store` or `Vault`, or a path that can reach a real install's data;
- a force-unwrap on network, file or keychain data.

Style and naming are worth a comment only when they break a rule here.

## Identity

What ties Escale to itself is hard-coded in a few places that change together:

- the bundle id `com.kndpt.escale` and the test ids derived from it (grep for it);
- the repository `kndpt/escale-browser`: `Links.repository` in `Links.swift`, `ESCALE_REPOSITORY` in `build.sh` and `publish.sh`;
- the update feed `escalebrowser.com/appcast.json`: `Updater.swift`, and the site's redirects;
- the Team ID for passkeys, not set yet: `Escale.passkeys.entitlements`;
- the GitHub App `escale-browser`: `GITHUB_CLIENT_ID` and `GITHUB_APP_SLUG`, which `build.sh` writes into Info.plist;
- the mark: [BRAND](docs/BRAND.md) lists every copy.

Escale uses nothing of Office Commun's: not the name "Search", its mark, bundle id, update feed or contact address. `LICENSE` (GPL-3.0) and `NOTICE` (Office Commun's MIT notice) are copied into every app `build.sh` makes; keep both.

## Independence from Search

Escale is developed on its own. Don't track Search, sync with it or port its commits.
