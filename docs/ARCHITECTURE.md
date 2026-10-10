# Architecture contract

Escale stays a small Swift/WebKit application. These rules apply to new work;
existing code is a target, not proof of compliance, and the
[open exceptions](#open-exceptions) list its gaps. Coding conventions are in
[AGENTS.md](../AGENTS.md), the product in [DIRECTION](DIRECTION.md), resource
reviews in [PERFORMANCE](PERFORMANCE.md) and test layers in [TESTING](TESTING.md).

## Shape and boundaries

One executable, no external dependencies, Swift 5 language mode, and one test
target, `EscaleTests`. Sources live in `Sources/Escale/`:

- **A folder is a domain.** A new concern gets its own file in its domain's
  folder; a folder is made for a new domain, never for one file. No layer
  folders (`Views/`, `Models/`): a feature's view sits beside its state.
- **File names are unique across the target.** Swift requires it, and comments
  cross-reference files by name (`see Shelf.swift`).
- **600 lines is a review signal, not a ceiling.** A split needs a useful
  boundary, follows whole types or owners, and is a change of its own.
- **The [source map](#source-map) changes with the folders**, in the same change.

A folder separates neither dependencies nor lifetimes. SwiftPM modules are not
used: `Tab`, `Browser` and `Extensions` still reach each other through statics.
The responsibilities below are logical, not production targets.

| Responsibility | Anchors | Contract |
|---|---|---|
| UI | `App`, `Side`, `Stage`, `TabBar`, `Bar`, `Shelf` | Render small observable inputs and issue actions. No disk reads, whole-history sorting, keychain queries or page construction while computing a view. |
| Coordination | `Browser`, `Spaces` | Decide which action applies to which tab or Space. Delegate page mechanics, persistence and substantial feature state. |
| Page lifetime | `Tab`, `Sleep` | `Tab` owns its page, observers, handlers and pending work. Sleep policy decides eligibility; UI placement does not decide existence. |
| Feature state | `Find`, `Calls`, `Float`, `LinkRoutes`… | Own the concern's state and cleanup. An `extension Browser` suits a small coordinating action, not application lifetime for a feature. |
| Persistence | `Session`, `History`, `Bookmarks`, `Loot`, `Store`, `Writer` | Receive value snapshots, keep order, expose failures. No dependency on a view or a live `WKWebView`. |
| Compatibility | `Extensions`, shims, native and socket bridges, platform adapters | Engine workarounds stay at this boundary. Product workflows never depend on a Chrome shim or a private selector. |

Use concrete types and small callbacks. Add a protocol only for a real second
implementation or a needed test seam. No dependency container or event bus.

## Extracting a responsibility

Taking state out of `Browser`, or any owner that holds more than its concern,
is a pull request of its own. It names the state moved, its owner, lifetime,
dependencies, actions and what stays behind. The new owner receives values,
focused objects or narrow callbacks, never the whole `Browser` or a singleton;
a necessary exception is listed below. Views observe the new owner directly:
while a relay through `Browser.objectWillChange` remains, the extraction is not
finished. Methods moved into an `extension Browser`, or a file under 600 lines,
separate nothing. Prove failures and transitions at the layer
[TESTING](TESTING.md) assigns, and measure affected paths per
[PERFORMANCE](PERFORMANCE.md).

## Ownership and lifetime

Every resource has an owner, an upper bound and an end condition. Each owner's
file header states its own bounds.

| Lifetime | Owners and resources | End condition |
|---|---|---|
| Application | preferences, icon cache, updater, link routes | Quit. Only deliberately shared state lives here. |
| Space | session, bookmarks, history, `Habits`, downloads, passwords, site settings, website store, extension controller, GitHub state | Space deletion; switching only parks a Space. |
| Tab | address, title, page configuration, subscriptions, `Media`, `Calls`, page tools | Close or replacement. Sleep keeps metadata, not a page. |
| Split | `Panels`, observed by `PanelStage` | Two or three tab identities per group; a singleton dissolves. No group owns a page. |
| Background media | `Media` per tab, `Playback` per window, observed by `MiniPlayer` | Navigation, sleep, close or dismissal ([MEDIA](MEDIA.md)). |
| API Calls | `Calls` per tab, observed by `CallsPanel`; the inspector session is `InspectorSession`'s | Opened by hand, three tabs at most; ends by hand, on close or on page process loss. |
| Extension speech | `ExtensionSpeech` | One utterance playing, a bounded queue; extension unload or quit. |
| Page tools | `JSONReader`, `SiteStorage`, `VisualPick`, `AreaPick`, `PageCapture` | Requested only; cleared by a new page, closed by tab or Space change. |
| Page generation | `WKWebView`, KVO, script handlers, navigation retries | Replacement, discard, sleep or close. |
| Interaction | popup, inspector action, floating controls, suggestion request | Dismissal, completion, cancellation or loss of eligibility. |

- Resolve callbacks, downloads, preferences and saves against the owning tab
  and Space, parked ones included: the Space on screen is not the registry of
  live tabs. Read `Spaces.current` only for a new user action.
- Each Space owns its files, keychain items, site settings, WebKit store and
  extension controller; a switch never exposes another Space's data.
- `Tab.built` inspects an existing page; `Tab.web` may build one and is an
  action. Menus, caches, status queries and background policies never wake a tab.
- Closing is terminal. A delayed callback checks its page or generation and the
  tab's eligibility; weak capture alone is not cancellation. Tab subscriptions
  belong to the tab, or a registry keyed by its ID, and end with it.
- Disabling or dismissing a feature stops its timers, tasks, observers and
  running JavaScript; a flag that blocks the next start is not cleanup.
- Sleep preserves drafts, downloads and calls; an unknown draft check is not
  permission to discard. A split's visible pages sleep and wake together.
- Under memory pressure, bound simultaneous snapshots; allow a cheap placeholder.

The page model is `unbuilt → live → sleeping → live`, with `closed` terminal:
a contract, not a required enum. Bench scenarios check each transition.

## Persistence and execution

- Paths, settings domains and website stores come from `Store`. Never fall back
  to production storage when test storage fails.
- Each saved destination has one ordered `Writer` that coalesces snapshots.
  Flush writes the latest snapshot behind earlier work; quit flushes every
  dirty Space and store.
- Save selection in the same filtered set as the saved entries; private, bench
  and shelf tabs never shift it.
- Decoding checks invariants (unique IDs, valid selection, sizes). Corrupt input
  is quarantined; a failed write is surfaced.
- UI and WebKit stay on the main thread; unbounded work, encoding and file I/O
  do not. A `Task` made on the main actor does not leave it.
- Coalesce bursty events, compare before publishing, observe the smallest state.

## Optional features and compatibility

A new feature states what starts it, what it owns, its idle and disabled cost,
and how it stops. Prefer deriving data from tab metadata. A script declares its
content world, frames, triggers and teardown; heavy DOM work is bounded.

Link routing picks the destination Space before a tab is built
(`Browser.routeLink`), for top-level user link openings only. Keyboard commands
are one finite catalogue (`KeyCommand`) with bindings saved in `Preferences`.

Extension compatibility is measured per extension; prefer an explicit
unsupported answer to simulated success. Private WebKit names need an
availability check, a fallback and a test. Existing uses (`Tab`, `Inspector`,
`Calls`, `Media`, `ExtensionPopup` and others) are debt, not a pattern.
[COMPATIBILITY](COMPATIBILITY.md) lists each private name, workaround and
extension; a change that adds or removes one updates its row.

## SwiftUI and AppKit pitfalls

- A long-lived view that reads `X.shared` through unpublished global state
  (`Spaces.current`) keeps what it first read. Pass the key (the Space) to the
  view as a parameter.
- Do not attach `task` or `onAppear` to a `Group` whose branches are all empty
  before loading: keep a concrete container.
- A panel's keyboard handling does not rely on SwiftUI focus: a click on text
  or empty space removes it, and the page keeps the keyboard. Watch the window
  while the surface is shown, leaving arrows to the page and to fields.
- AppKit calls local event monitors in no guaranteed order. A filter that must
  run first is consulted by the monitor it precedes.
- Inside a view `ViewThatFits` recreates, do not combine a `.scale` transition
  with `matchedGeometryEffect`: the row leaves its place.

## Source map

Sources sit in `Sources/Escale/`, one folder per domain. A `Scripts/` folder
holds the JavaScript its domain injects.

| Folder | Concern | Files |
|---|---|---|
| `App/` | App entry and root view; first launch and its GitHub step; links from other apps; self-update and what a new build brought; local developer notifications; bundled resources | `App`, `Welcome`, `WelcomeGitHub`, `Links`, `Updater`, `Gate`, `GatePanel`, `DeveloperAlerts`, `Bundled` |
| `Design/` | Colours, metrics, motion, interface scale; glass and the Transparency setting; panel plate; hover timing; tooltips; copy button; door marks; mode capsule; the mark | `Design`, `ChromeScale`, `Glass`, `Plate`, `HoverDwell`, `ShortcutMotion`, `Swatch`, `InfoTip`, `CopyButton`, `DoorMark`, `Modes` (app icon: `Icon/icon.swift`) |
| `Keyboard/` | Command catalogue, key normalisation, saved bindings, menus, dispatch, the Settings recorder | `KeyCommand`, `KeyStroke`, `KeyBindings`, `KeyRouting`, `KeyMenus`, `KeyCapture`, `KeyboardSettings` |
| `Browser/` | The window's coordinator: tabs, selection, navigation, most commands; site data reset and storage editor | `Browser`, `SiteData`, `SiteStorage`; `Scripts/` |
| `Window/` | What surrounds the page: page area and splits, tab row, sidebar, address bar, tab search, history menus, reading line, localhost hub, mini player, folding, traffic lights | `Stage`, `PanelStage`, `TabBar`, `Side`, `Bar`, `TabSearchDoor`, `HistoryDoor`, `ReadingLine`, `LocalhostHub`, `MiniPlayer`, `Fold`, `Lights` |
| `Tabs/` | One page's lifetime: lazy web view, sleep and wake, sleep with the window closed, splits, zoom, audio and screen-sharing hints, pictures of sleeping tabs, site icons | `Tab`, `Panels`, `PageZoom`, `Media`, `Sleep`, `Sleeping`, `Away`, `Pictures`, `Icons`, `ScreenShare`; `Scripts/` |
| `Page/` | What happens in a page: dialogs, menus, Web Inspector, developer mode and API Calls, JSON viewer, swipe, auto-scroll, status line, reader, visual inspection, area selection and capture, find, floating video and meetings | `Dialogs`, `ImageMenu`, `SelectionMenu`, `Inspector`, `Developer`, `Calls`, `Call`, `CallSearch`, `CallReport`, `Curl`, `CallsPanel`, `JSONPreview`, `JSONDocument`, `JSONReader`, `Swipe`, `AutoScroll`, `StatusLine`, `Reader`, `VisualPick`, `AreaPick`, `CaptureBounds`, `PageCapture`, `Find`, `Float`, `Meeting`; `Scripts/` (`calls.js` runs in the inspector frontend, never in a page) |
| `Spaces/` | Spaces, swiping and dragging between them, session restore, session cookies across a quit, split sessions, duplication, presence marks, link routing to a Space | `Spaces`, `Presence`, `SpaceSwipe`, `SpaceDrag`, `Session`, `Jar`, `PanelSession`, `SpaceCopy`, `LinkRule`, `LinkRoutes`, `LinkRulesView`, `LinkRuleRow`, `LinkDraft`, `LinkAddress`, `LinkRouteMenu`, `LinkRoutesBench` |
| `Address/` | Bearings (⌘T, ⌘L, ⌘K): address field, suggestions, word matching, learned order, search engines, GitHub mode, environment suggestions, visited local endpoints and listening ports | `Address`, `Field`, `Terms`, `Habits`, `Engine`, `Omnibox`, `NewTab`, `Bearing`, `SearchEnvironments`, `Environment`, `Localhost`, `Listening` |
| `GitHub/` | Bearings' GitHub items: identities and observations, bounded per-Space cache, per-Space sign-in and keychain, refresh of visible items, page state reading, search, ranking and presentation | `GitHubItem`, `GitHubState`, `GitHubMemory`, `GitHubDisk`, `GitHubAccess`, `GitHubSecrets`, `GitHubHTTP`, `GitHubRefresh`, `GitHubWatch`, `GitHubShares`, `GitHubSpaces`, `GitHubPage`, `GitHubSearch`, `GitHubNavigation`, `GitHubResults`, `GitHubResult`, `GitHubSettings`, `GitHubSignIn`, `GitHubSpecimen`, `GitHubSymbol`, `GitHubMark`, `GitHubPrototype`, `GitHubBench`; `Scripts/`, `Assets/` |
| `History/` | History, downloads, the History and Downloads panel | `History`, `Recall`, `Downloads`, `DownloadDoor`, `DownloadFlight`, `Loot` |
| `Bookmarks/` | Bookmarks, their environments, the sidebar shelf and its folder search, their right-click actions | `Bookmarks`, `Shelf`, `FolderSearch`, `BookmarkActions`, `Environments`, `EnvironmentEditor`, `EnvironmentScope` |
| `Passwords/` | Keychain, passwords, passkeys, forms, accounts menu | `Vault`, `Logins`, `Passwords`, `Passkeys`, `Forms`, `Accounts`; `Scripts/` |
| `Blocking/` | Content blocker and hidden page elements | `Shield`, `Curtain`, `Hidden`; `Scripts/` |
| `Extensions/` | Chrome extensions and the Chrome Web Store | `Extensions`, `ExtensionShims`, `ExtensionSpeech`, `ExtensionPopup`, `ExtensionNative`, `ExtensionSocket`, `ExtensionsUI`, `Crx`, `StoreRelay`; `Scripts/` |
| `Migration/` | Import from other browsers: profile choice, bounded readers, plans, application, onboarding and Settings UI | `Migration`, `MigrationBrowsers`, `MigrationProfiles`, `MigrationInput`, `MigrationChoices`, `MigrationSuggestions`, `MigrationSteps`, `MigrationPassage`, `MigrationValues`, `MigrationExchange`, `MigrationPlan`, `MigrationFlow`, `MigrationPanel`, `MigrationTabs`, `MigrationSQLite`, `MigrationZIP`, `MigrationMozLZ4`, `MigrationChromium`, `MigrationChromiumSession`, `MigrationGecko`, `MigrationGeckoSession`, `MigrationSafari`, `MigrationArc`, `MigrationOrion`, `MigrationZen`, `MigrationBench`, `MigrationKeychainBench` |
| `Transfer/` | Every Space saved to one sealed file and brought into another Mac | `TransferFile`, `TransferValues`, `TransferExport`, `TransferApply`, `TransferPreferences`, `TransferFlow`, `TransferPanel`, `TransferBench` |
| `Settings/` | Settings and preferences | `Settings`, `Prefs`, `ToneChoice` |
| `Storage/` | Test-world boundary, paths, settings, ordered writes flushed at quit | `Store`, `Writer` |
| `Bench/` | Script socket, off by default, driven by `./bench` | `Bench`, `BenchPointer`, `BenchKeys`, `PanelBench`, `CallsBench`, `UpdateBench`, `GitHubDataBench` |

## Where new work plugs in

The hook goes in the file named; the concern lives in its own file.

| New work needs | Plug into | Bound and stop |
|---|---|---|
| A setting | a `@Published` value in `Preferences` (`Prefs.swift`), backed by `Store.settings` | Turning it off stops what it started, in open pages too. |
| Saved data | a value snapshot through `Writer`, at a path from `Store` | One ordered writer per destination, flushed at quit. |
| State for one tab | an owner held by `Tab`, or keyed by the tab's ID | Cancelled on close, replacement and sleep; late callbacks check the page generation. |
| State for one Space | the Space's record and files, keyed by its ID (`Spaces.swift`) | Kept while parked; resolved by Space ID, not the one on screen. |
| A cache or queue | an owner with a count or byte cap and eviction (`Recent` in `Icons.swift`) | Memory and disk bounded; emptied under critical pressure. |
| A page script | a `.js` file in the domain's `Scripts/`, read with `Bundled.script`, installed only while the feature is on | Declares its world, frames and teardown. |
| A coordinating action | an `extension Browser` in the feature's file | Holds no state. |
| A colour, size or timing | `Palette`, `Metrics`, `Motion` (`Design.swift`) | — |
| A surface of Escale's own | `.glass(role, in: shape)` (`Glass.swift`); a selection stands on `Chosen`; a popover keeps the system material with `.popoverGround()` | Follows Transparency and Reduce Transparency; never applied to page content. |
| A private WebKit name or engine workaround | the compatibility adapter that needs it | Checked before use, with a fallback and a row in COMPATIBILITY. |

## Open exceptions

Places where the code does not meet this contract yet. None is a pattern to
copy. Remove a row when its repair lands; add one when a new gap is found.

| Exception | Where | State |
|---|---|---|
| Window-wide state: many `@Published` properties and feature state in `extension Browser` files; preferences, history and bookmarks relayed through `Browser.objectWillChange` | `Browser.swift`, `Shelf.swift` | Reduced one owner at a time: the address field (`Field`), passwords (`Logins`), find (`Find`) and downloads (`Downloads`) have their own owners. |
| Platform passkeys are scoped by app and relying party, not by Space | `Passkeys.swift`, `Tab.swift` | The first Space keeps them; other Spaces suppress them. External providers are not verified across Spaces. |
| Pinned tabs never sleep, even under critical pressure | `Sleep.swift` | Product decision. |
| A tab reads its own icon from disk on the main thread | `Icons.swift` (`cached`), `Tab.swift` | Open. Lists never read the disk while drawing. |
| Standard defaults outside `Store`: `WebAutomatic*` (WebKit reads them) and `AppleActionOnDoubleClick` (system, read only) | `Preferences.configurePageText()` in `Prefs.swift`, `Stage.swift` | Accepted: a test world's own bundle id isolates them. |
| Paths outside `Store`: other browsers' profiles (on request), Chromium native-messaging manifests, `~/Downloads` by default | migration readers, `ExtensionNative.swift`, `Prefs.swift` | Accepted, read only. A test run still reads the real native-messaging manifests and starts the program one names when an extension asks. |
| API Calls depends on private `_WKInspector` selectors and the Web Inspector frontend's `WI.*` model | `Calls.swift`, `Page/Scripts/calls.js`, `Inspector.swift` | Each is checked before use; a missing one stops the panel with its reason. Verified on one macOS version only. |
| No absolute resource budget is validated | — | The gates in PERFORMANCE are provisional. |
