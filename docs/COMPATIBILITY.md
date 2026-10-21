# Compatibility register

What Escale takes from outside WebKit's public API, and what it adds so Chrome
extensions run on WebKit. It is the inventory the
[architecture contract](ARCHITECTURE.md#optional-features-and-compatibility)
asks for. A row names the scenario that covers it; "—" means none does, which
is a gap, not a failure.

## Rules

- **Ask before use.** Check every private name first (`responds(to:)`, `dlsym`,
  `#available`) and fall back to the public behaviour. Never crash or pretend
  success when it is missing.
- **Add the row in the same change** as a new private name, shim or engine
  workaround: its check, its fallback, what needed it and what covers it.
- **Remove one only with evidence:** reproduce the before and after first.
- **On a new macOS or Safari,** run `./test.sh` and
  `python3 Tests/Bench/compatibility.py`, which prints the system it ran on.
- **An extension named in a code comment is not a supported extension.**
  Support needs a versioned scenario.

## Private names and platform workarounds

| Name | File | Purpose | Check and fallback | Scenario |
|---|---|---|---|---|
| `_setDeveloperExtrasEnabled:` on `WKPreferences` | `Tab.swift` (`Web.inspector`) | Inspect Element and Web Inspector from the View menu | `responds(to:)`; without it only Safari's Develop menu reaches a page | `compatibility.py` |
| `_inspector`, then `show`, `close`, `inspectorWebView`, `setDelegate:`; delegate `inspectorFrontendLoaded:`, `_webView:willCloseLocalInspector:`; class `WKInspectorWKWebView`; `InspectorFrontendHost.supportsDockSide` / `requestSetDockSide`; menu item `WKMenuItemIdentifierInspectElement` | `Inspector.swift`, `Stage.swift`, `Tab.swift` (`PageView`) | ⌥⌘I and right-click › Inspect Element, a right-docked Web Inspector that stays with the tabs it was opened on | Selectors checked; frontend lookup and dock request are bounded; failure closes the panel; an unknown menu item is left to WebKit | `compatibility.py`, `inspector_layout.py`, `inspector_follow.py` |
| `showConsole`, `toggleElementSelection` | `Inspector.swift` | ⌥⌘J, ⌥⌘C | As above; a missing one does nothing | — |
| `_mainFrame` on `WKWebView` (a `_WKFrameHandle`), `showMainResourceForFrame:` on `_WKInspector` | `Inspector.swift` (`showSource`) | ⌥⌘U and `view-source:` open Web Inspector on the main resource as received | `responds(to:)` and the handle's class; without them Web Inspector opens as ⌥⌘I does | `view_source.py` |
| `isVisible` on `_WKInspector` | `Inspector.swift` | A page too narrow to dock keeps WebKit's separate inspector window | `responds(to:)`; otherwise the panel closes | — |
| `connect`, `hide`, `isConnected`, `inspectorWebView` on `_WKInspector` | `Inspector.swift`, `Calls.swift` | API Calls reads WebKit's network collection with the inspector loaded but unseen, at most `Calls.limit` at once | Checked with `close` and `setDelegate:`; a missing one stops the panel, names it and offers Web Inspector. A leftover connected session is closed first | `compatibility.py`, `network_calls.py` |
| Readiness query `WI.networkManager`, `WI.mainTarget` | `Inspector.swift` (`settle`) | A frontend WebKit reuses is not always announced again | Asked four times a second for at most 10 s, then the collection fails with its reason | `network_calls.py` |
| Frontend model: `WI.Frame`, `WI.Target`, `WI.Resource` events, `WI.networkManager`, `NetworkAgent.getResponseBody` | `Page/Scripts/calls.js` (frontend page only) | API Calls rows, headers, bodies and search, without instrumenting the page | Checks the classes and counts its six listeners; fewer stops the panel. Bodies with no `NetworkAgent` are named unavailable; a read times out after 10 s | `network_calls.py`, `network_calls_browse.py` |
| A script awaited in the frontend (`__escaleCalls.awake()`) | `Calls.swift`, `Page/Scripts/calls.js` | Hidden, the frontend's process is suspended soon after Escale last spoke to it (macOS 26.5), and network events wait with it; WebKit keeps a process running while a script is awaited in it | Public `callAsyncJavaScript`, settled by `stop()`; without it, rows lag until Escale next speaks to the frontend | `network_calls_browse.py` |
| `_isPlayingAudio` (KVO on `WKWebView`) | `Tab.swift` (`AudioWatch`), `Tabs/Media.swift` | Tab audio indicator; activates the media reader | `responds(to:)`; without it, no indicator and one public `requestMediaPlaybackState` on leaving a page. `_playingAudio` crashed and is not used | `media_player.py` |
| `_setPageMuted:`, `_mediaMutedState` on `WKWebView` | `Mute.swift` | A tab's speaker mutes its page without pausing it | `instancesRespond(to:)`; without them the speaker does nothing. The capture bits are written back as read | `tab_mute.py` |
| `_setObservedRenderingProgressEvents:`, delegate `_webView:renderingProgressDidChange:` | `Tab.swift` (`PageView`), `Browser.swift` | First-frame reveal; sleep and process-recovery handoff | `responds(to:)`; without it a view shows at once and a return waits for `didFinish` | `wake_transition.py` |
| `_setLayoutMode:`, `_setFixedLayoutSize:`, `_setViewScale:`, `_setOverrideDeviceScaleFactor:` on `WKWebView` | `Screens.swift` | Screens lays the page out at the size asked for, draws it at the tab's zoom or smaller, and gives it a device's density | `responds(to:)` for each; without the layout pair the page keeps its frame's size, without the factor the Mac's density. The fixed layout leaves page zoom out, so the zoom moves into the view scale while Screens is on. `innerHeight` can read a pixel off a device's height while the layout height is exact; `resolution` queries see the factor before the view scale; a size changed with the density gets no `resize` from WebKit, so `screens.js` sends one | `screens.py`, `ScreensTests` |
| Delegate `_webView:navigationDidFinishDocumentLoad:` | `ExtensionPopup.swift` | Size a popup at DOMContentLoaded, as Chrome does | `didFinish` measures too; measured at 3 s and shown at 5 s regardless | `compatibility.py` |
| `_CFHostIsDomainTopLevel` (CFNetwork, `dlsym`) | `Passkeys.swift` (`publicSuffix`) | A passkey's relying party may be a parent domain that is not a public suffix | Symbol missing: only the page's own host | `PasskeysTests` |
| `CGSSessionScreenIsLocked` in `CGSessionCopyCurrentDictionary()` | `ExtensionShims.swift` (`idle.queryState`) | `chrome.idle` reports `locked` | Key absent: `idle` or `active` from the time since the last input event | — |
| Menu items `WKMenuItemIdentifierCopy`, `WKMenuItemIdentifierPaste`, `WKMenuItemIdentifierCopyLinkWithHighlight` | `Tab.swift` (`PageView`) | Escale's Copy Link with Highlight beside Copy, only where WebKit offers none of its own (a frame; an older WebKit) | Matched by identifier; without Copy nothing is added and the selection menu keeps its link | `text_fragment.py` |
| `WebKitErrorDomain` code 102 | `Browser.swift` | A navigation that became a download is not shown as a failed load | Any other code shows the failure page | — |
| `WebAutomatic*` standard defaults | `Prefs.swift` | Spelling correction, smart quotes and dashes stay off in page code fields | Set before WebKit reads them; test bundles have their own domain | `page_scripts.py` (launch defaults) |
| `libproc` socket table (`proc_listpids`, `proc_pidinfo`, `proc_pidfdinfo`); `sysctl kern.boottime` | `Listening.swift`, `Localhost.swift` | Which visited local endpoints still listen; a visit before the last boot is not counted | Read once per panel opening, off the main thread; a failed read calls nothing stopped. Other users' processes are invisible, so a `sudo` server reads as not listening. Would fail under an App Store sandbox | `LocalhostTests`, `localhost_hub.py` |
| Shared `WKProcessPool` (public, deprecated) | `Tab.swift` (`Web.pool`) | A new tab's web process is ready in advance | Ignored: each view gets its own pool, slower, same behaviour | — |
| Safari's version in the user agent, read from `Safari.app` | `Tab.swift` (`Web.userAgentName`) | Pages send code this WebKit can run | Unreadable: the Safari this macOS shipped with | `compatibility.py` |
| Back/Forward menu identity follows the current `WKBackForwardListItem` (public API) | `HistoryDoor.swift` | A reopened Back menu kept stale rows after a jump | Ordinary Back/Forward still work | `navigation_controls.py` |
| Menu items `WKMenuItemIdentifierOpenLinkInNewWindow`, `WKMenuItemIdentifierReload`; the window that Open Link in New Window asks for, taken as an address | `Elsewhere.swift`, `Tab.swift` (`PageView`), `Browser.swift` (`createWebViewWith`) | Open Page In and Open Link In hand the address to another browser | An unknown item: no entry. A window not asked for within 1 s is not taken | `open_elsewhere.py` (lists only) |
| `WKWebExtension` (public, macOS 15.4+) | `Extensions*.swift` | Chrome extensions | `@available(macOS 15.4, *)`; below it, no extensions | `compatibility.py` |

### Used only by the bench

- `_webProcessIdentifier`: `bench crash` and `bench calls pids`.
- `_inspector` and `inspectorWebView` in `CallsBench.swift`: name the inspector
  frontend's process for measurements.
- `_developerExtrasEnabled` and `_isPlayingAudio` reads: `bench probe`.
- `_setWindowOcclusionDetectionEnabled:`: `bench picture`.
- `_doAfterProcessingAllPendingMouseEvents:`: `bench tap` answers once the
  page has the release too. Without it, the answer comes first and a script
  evaluated before the release can leave the click without its activation.
- `_setMockCaptureDevicesEnabled:` (`Web.mockCapture`, test runs but the beta): WebKit's
  synthetic camera and microphone for `space_media.py` and `call_float.py`.
  Without it those scenarios fail rather than skip.
- `_setICECandidateFilteringEnabled:` (`Web.plainICE`, the same runs): WebRTC gives
  the Mac's own addresses instead of registering a `.local` name with Bonjour,
  which shows each new test identity a Local Network prompt. Without it the
  prompt comes back.

## Page-script workarounds

- **Screen-sharing detail.** `ScreenShare.swift` installs
  `Tabs/Scripts/screen-share.js` at document start in every frame's page world.
  A `getDisplayMedia` video track with an empty `contentHint` gets `detail`. The
  native call runs inside the user's gesture; permissions, errors, cameras and
  audio stay native, and a site can still set `motion`. Covered by
  `ScreenShareTests`.
- **Google Meet** is read by name; the table and its limits are in
  [MEDIA](MEDIA.md#reading-a-meet-page).
- **Hidden windows.** WebKit suspends `requestAnimationFrame` in a hidden
  window. A script that must answer there, a test world included, uses
  `setTimeout(0)`.

## Public WebKit limits

- Capture uses `takeSnapshot` and `createPDF`. WebKit's own rendering
  allocations cannot be capped beforehand and a queued capture cannot be
  cancelled. Escale's bounds are in `CaptureBounds.swift`.
- `pageZoom` is absolute: Escale's 100 % is `PageZoom.reference` (`1 / 1.1`).
  Saved zoom values and the extension tab zoom stay absolute factors.
- Site Data uses `WKHTTPCookieStore` and `WKWebsiteDataStore`. Attributes
  Foundation lacks, such as partition keys, cannot be edited.
- While Web Inspector is attached, `StageView` keeps the narrowed frame WebKit
  gave the page.
- Migration uses Foundation, Security, SQLite and zlib only; see
  [MIGRATION](MIGRATION.md).

## Extensions

The engine is WebKit's `WKWebExtension`. Escale fills in what Chrome has and
WebKit lacks:

- **`ExtensionShims.swift`** prepares an extension at install. It puts
  `escale-shim.js` first in the background and every shipped page, and
  `escale-content.js`, the part that runs on a web page, first in its
  content scripts, adds `nativeMessaging` (and `scripting` for `userScripts`), and records
  the additions in `.escale-added`. Its `run` checks the permission a call
  needs and hands it to its family's file (`ExtensionBookmarks.swift` and the
  files beside it).
- **`Extensions/Scripts/shim*.js`** define the APIs in JavaScript and hold
  most engine workarounds: one function in files assembled in order
  (`ExtensionShims.parts`). `shim.js` opens it and is what content scripts
  get; then calls to the browser, messaging, worker only, namespaces WebKit
  lacks, mends to the ones it has, permissions, user scripts, the
  background's start, the FileSystem API and errors.
- Each extension's folder keeps the shim's data in `_search/`:
  `userscripts.json`, `worlds.json` and `us-*.js` files.

**Answered:** bookmarks; history; downloads (`download`, `search`, `open`,
`show`, `showDefaultFolder`, `erase`); side panel (as a tab); offscreen
documents; font settings; management (itself only); `i18n.detectLanguage`;
`runtime.getContexts`; notifications; tts; user scripts; permissions; tabs by
index (`describe`, `move`, `discard`, `activate`); search; idle; power; browsing
data; sessions; top sites; system (CPU, memory, displays);
`identity.launchWebAuthFlow`; `privacy.*` and `proxy.settings` through
`setting.get`, `set` and `clear`. Answered empty: `readingList.query`,
`tabGroups.query`, `identity.getProfileUserInfo`, `sessions.getDevices`,
`system.storage.getInfo`.

Settings are kept per extension. Only `privacy.services.passwordSavingEnabled`
acts: off, it stops Escale's own offer to save passwords. Defaults: that
preference, `webRTCIPHandlingPolicy` `default`, `privacy.websites.*` `false`,
`proxy.settings` mode `system`.

**Gated by the manifest's permission**, optional grants included, as Chrome
gates them: bookmarks, history, downloads, sessions, top sites, browsing
data, reading list, user scripts, notifications, idle, power, identity,
offscreen, tts, search, font settings, side panel, each part of `system`,
and `management` beyond the caller itself; `privacy.*` and `proxy.settings`
need `privacy` and `proxy`. `tabs.describe` needs `tabs`. Tab groups answer
nothing and need nothing. `permissions.request` grants only what the manifest
lists in `optional_permissions`.

**Refused:** `downloads.pause`, `resume`, `cancel`, `removeFile`, `getFileIcon`;
`management.setEnabled`, `uninstallSelf`; reading-list writes; `tabGroups.get`,
`update`, `move`; `identity.getAuthToken`; any other name.

**Shared by every Space** (`extensions.shared`), one controller serves every
Space and each Space is a window, the one on screen focused. Bookmarks,
history, downloads, sessions and top sites answer for the Space on screen;
`browsingData` clears its store. `chrome.cookies` without a `storeId` reads
the extensions' own pages' store, which holds no Space's site cookies; a tab's
store is reached by its `storeId`, and `getAllCookieStores` lists each. Calls
by a tab's index (`describe`, `move`, `discard`, `activate`, a tab's popup)
reach only the window on screen (`inFront` in the shim): elsewhere they fail
as a parked Space's do, and `describe` leaves the address out. When
`windows.getLastFocused` fails, the call goes through as it did before. WebKit sends `storage.onChanged` to no
page shown as the action's popup in a tab.

Popups follow Chrome's auto-size between 25 × 25 and 800 × 600 points
(`popup-preferred.js`, then `popup-reach.js` as the page changes).

### Messaging

`extension_messaging.py` replays Chrome's messaging on a local fixture: the
listener that answers among several, async and promised answers, a page that
listens without answering, page to page, ports, content scripts both ways and
the extension's page framed in a website. WebKit's runtime answers
`lastError` itself, so pages and the worker see it through a proxy that
reports the shim's errors to callbacks. One gap remains: a message to a tab
nobody listens in settles empty where Chrome rejects.

### Per-extension workarounds

No scenario replays these; the extension is the one the code comment names.

| Extension | Workaround | Where |
|---|---|---|
| 1Password | The browser opens a worker's WebSocket (it froze the extension); tab messages also reach the extension's frames; a website tab sent to an extension page is rebuilt; passkeys go to the claiming extension | `ExtensionSocket.swift`, `shim-worker.js`, `shim-messaging.js`, `Extensions.swift`, `Browser.swift`, `Passkeys.swift`, `Forms.swift` |
| Bitwarden | Chrome's user agent in the worker and pages (Safari's made it flood the browser); `runtime.getContexts`; an offscreen document's empty answer does not hold a reply | `shim-worker.js`, `shim-background.js`, `shim-messaging.js`, `ExtensionShims.swift` |
| Bitwarden, Proton Pass | The popup is a tab with no index, as Chrome has no current tab there | `shim-mends.js` |
| Proton Pass | `requestIdleCallback` restored (WebKit bug 287681); a Proxy over `chrome` is kept only if it still carries the APIs | `shim.js` |
| MetaMask (LavaMoat) | The shim keeps its own references to locked globals; `chrome` and `browser` become fixed accessors | `shim.js` |
| Vimium, iCloud Passwords | A framed extension page has the worker make privileged calls | `shim-messaging.js` |
| Tampermonkey, Violentmonkey | `chrome.userScripts` through registered content scripts; a missing imported script is refused at once | `shim-user-scripts.js`, `shim-worker.js`, `ExtensionShims.swift` |
| Raindrop | `chrome-extension://` origins with Chrome's ids | `Extensions.swift` |
| uBlock Origin Lite, Grammarly | Load after the window's first frame; shim preparation off the main thread | `Extensions.swift` |

### Extension speech

`chrome.tts` keeps `speak`, `stop`, `pause`, `resume`, `isSpeaking` and
`getVoices`, with `voiceName`, relative `rate` and `enqueue`, on
`AVSpeechSynthesizer` (`ExtensionSpeech.swift`). An unknown voice uses the
default; a rate outside 0.1–10 is refused. One lane serves all extensions, and
unloading one removes only its work. At most `capacity` utterances of
`textLimit` UTF-16 units are kept. `lang`, `pitch`, `volume`, SSML, events and
`ttsEngine` are unsupported. Covered by `extension_speech.py`.

## Known gaps

- **Older macOS.** The minimum is macOS 14; extensions need 15.4. No private
  name has been run there yet.
- **No automated observation:** the `_isPlayingAudio` and first-frame
  fallbacks, ⌥⌘J / ⌥⌘C, `isVisible`, `CGSSessionScreenIsLocked`, error 102 and
  `bench picture`. Adding one is a bench extension ([TESTING](TESTING.md)).
- **Extensions.** Only local fixtures in `Tests/Bench/fixtures/` are replayed.
  `compatibility.py` covers `bookmarks.getTree`, the history gate and
  `tabGroups.get`, `extension_messaging.py` messaging; other families are not
  covered. Set
  `ESCALE_EXTENSION_FIXTURE` to a copy outside Documents to avoid a macOS
  folder-access prompt.
- **Spaces.** `space_context.py` checks the local fixture in two Spaces and
  `shared_extensions.py` one set serving two, not arbitrary extensions or
  password managers. macOS passkeys have no
  Space-scoped storage, so the passkey path exists only in the first Space.
