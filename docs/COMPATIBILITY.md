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
| `_inspector`, then `show`, `close`, `webView`, `setDelegate:`; delegate `inspectorFrontendLoaded:`, `_webView:willCloseLocalInspector:`; class `WKInspectorWKWebView`; `InspectorFrontendHost.supportsDockSide` / `requestSetDockSide` | `Inspector.swift`, `Stage.swift` | ⌥⌘I, a right-docked Web Inspector that follows the tab | Selectors checked; frontend lookup and dock request are bounded; failure closes the panel | `compatibility.py`, `inspector_layout.py` |
| `showConsole`, `toggleElementSelection` | `Inspector.swift` | ⌥⌘J, ⌥⌘C | As above; a missing one does nothing | — |
| `isVisible` on `_WKInspector` | `Inspector.swift` | A page too narrow to dock keeps WebKit's separate inspector window | `responds(to:)`; otherwise the panel closes | — |
| `connect`, `hide`, `isConnected`, `inspectorWebView` on `_WKInspector` | `Inspector.swift`, `Calls.swift` | API Calls reads WebKit's network collection with the inspector loaded but unseen, at most `Calls.limit` at once | Checked with `close` and `setDelegate:`; a missing one stops the panel, names it and offers Web Inspector. A leftover connected session is closed first | `compatibility.py`, `network_calls.py` |
| Readiness query `WI.networkManager`, `WI.mainTarget` | `Inspector.swift` (`settle`) | A frontend WebKit reuses is not always announced again | Asked four times a second for at most 10 s, then the collection fails with its reason | `network_calls.py` |
| Frontend model: `WI.Frame`, `WI.Target`, `WI.Resource` events, `WI.networkManager`, `NetworkAgent.getResponseBody` | `Page/Scripts/calls.js` (frontend page only) | API Calls rows, headers, bodies and search, without instrumenting the page | Checks the classes and counts its six listeners; fewer stops the panel. Bodies with no `NetworkAgent` are named unavailable; a read times out after 10 s | `network_calls.py`, `network_calls_browse.py` |
| `_isPlayingAudio` (KVO on `WKWebView`) | `Tab.swift` (`AudioWatch`), `Tabs/Media.swift` | Tab audio indicator; activates the media reader | `responds(to:)`; without it, no indicator and one public `requestMediaPlaybackState` on leaving a page. `_playingAudio` crashed and is not used | `media_player.py` |
| `_setObservedRenderingProgressEvents:`, delegate `_webView:renderingProgressDidChange:` | `Tab.swift` (`PageView`), `Browser.swift` | First-frame reveal; sleep and process-recovery handoff | `responds(to:)`; without it a view shows at once and a return waits for `didFinish` | `wake_transition.py` |
| Delegate `_webView:navigationDidFinishDocumentLoad:` | `ExtensionPopup.swift` | Size a popup at DOMContentLoaded, as Chrome does | `didFinish` measures too; measured at 3 s and shown at 5 s regardless | `compatibility.py` |
| `_CFHostIsDomainTopLevel` (CFNetwork, `dlsym`) | `Passkeys.swift` (`publicSuffix`) | A passkey's relying party may be a parent domain that is not a public suffix | Symbol missing: only the page's own host | `PasskeysTests` |
| `CGSSessionScreenIsLocked` in `CGSessionCopyCurrentDictionary()` | `ExtensionShims.swift` (`idle.queryState`) | `chrome.idle` reports `locked` | Key absent: `idle` or `active` from the time since the last input event | — |
| `WebKitErrorDomain` code 102 | `Browser.swift` | A navigation that became a download is not shown as a failed load | Any other code shows the failure page | — |
| `WebAutomatic*` standard defaults | `Prefs.swift` | Spelling correction, smart quotes and dashes stay off in page code fields | Set before WebKit reads them; test bundles have their own domain | `page_scripts.py` (launch defaults) |
| `libproc` socket table (`proc_listpids`, `proc_pidinfo`, `proc_pidfdinfo`); `sysctl kern.boottime` | `Listening.swift`, `Localhost.swift` | Which visited local endpoints still listen; a visit before the last boot is not counted | Read once per panel opening, off the main thread; a failed read calls nothing stopped. Other users' processes are invisible, so a `sudo` server reads as not listening. Would fail under an App Store sandbox | `LocalhostTests`, `localhost_hub.py` |
| Shared `WKProcessPool` (public, deprecated) | `Tab.swift` (`Web.pool`) | A new tab's web process is ready in advance | Ignored: each view gets its own pool, slower, same behaviour | — |
| Safari's version in the user agent, read from `Safari.app` | `Tab.swift` (`Web.userAgentName`) | Pages send code this WebKit can run | Unreadable: the Safari this macOS shipped with | `compatibility.py` |
| Back/Forward menu identity follows the current `WKBackForwardListItem` (public API) | `HistoryDoor.swift` | A reopened Back menu kept stale rows after a jump | Ordinary Back/Forward still work | `navigation_controls.py` |
| `WKWebExtension` (public, macOS 15.4+) | `Extensions*.swift` | Chrome extensions | `@available(macOS 15.4, *)`; below it, no extensions | `compatibility.py` |

### Used only by the bench

- `_webProcessIdentifier`: `bench crash` and `bench calls pids`.
- `_inspector` and `inspectorWebView` in `CallsBench.swift`: name the inspector
  frontend's process for measurements.
- `_developerExtrasEnabled` and `_isPlayingAudio` reads: `bench probe`.
- `_setWindowOcclusionDetectionEnabled:`: `bench picture`.
- `_setMockCaptureDevicesEnabled:` (`Web.mockCapture`, test runs only): WebKit's
  synthetic camera and microphone for `space_media.py` and `call_float.py`.
  Without it those scenarios fail rather than skip.

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
  `escale-shim.js` first in the background, content scripts and every shipped
  page, adds `nativeMessaging` (and `scripting` for `userScripts`), and records
  the additions in `.escale-added`. Its `run` switch answers native calls.
- **`Extensions/Scripts/shim.js`** defines the APIs in JavaScript and holds
  most engine workarounds.
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

**Gated by the manifest's permission**, optional grants included: bookmarks,
history, downloads, sessions, top sites, browsing data, reading list.
`tabs.describe` needs `tabs`.

**Refused:** `downloads.pause`, `resume`, `cancel`, `removeFile`, `getFileIcon`;
`management.setEnabled`, `uninstallSelf`; reading-list writes; `tabGroups.get`,
`update`, `move`; `identity.getAuthToken`; any other name.

Popups follow Chrome's auto-size between 25 × 25 and 800 × 600 points
(`popup-preferred.js`, then `popup-reach.js` as the page changes).

### Per-extension workarounds

No scenario replays these; the extension is the one the code comment names.

| Extension | Workaround | Where |
|---|---|---|
| 1Password | The browser opens a worker's WebSocket (it froze the extension); tab messages also reach the extension's frames; a website tab sent to an extension page is rebuilt; passkeys go to the claiming extension | `ExtensionSocket.swift`, `shim.js`, `Extensions.swift`, `Browser.swift`, `Passkeys.swift`, `Forms.swift` |
| Bitwarden | Chrome's user agent in the worker and pages (Safari's made it flood the browser); `runtime.getContexts`; an offscreen document's empty answer does not hold a reply | `shim.js`, `ExtensionShims.swift` |
| Bitwarden, Proton Pass | The popup is a tab with no index, as Chrome has no current tab there | `shim.js` |
| Proton Pass | `requestIdleCallback` restored (WebKit bug 287681); a Proxy over `chrome` is kept only if it still carries the APIs | `shim.js` |
| MetaMask (LavaMoat) | The shim keeps its own references to locked globals; `chrome` and `browser` become fixed accessors | `shim.js` |
| Vimium, iCloud Passwords | A framed extension page has the worker make privileged calls | `shim.js` |
| Tampermonkey, Violentmonkey | `chrome.userScripts` through registered content scripts; a missing imported script is refused at once | `shim.js`, `ExtensionShims.swift` |
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
  `tabGroups.get`; other families are not covered. Set
  `ESCALE_EXTENSION_FIXTURE` to a copy outside Documents to avoid a macOS
  folder-access prompt.
- **Spaces.** `space_context.py` checks the local fixture in two Spaces, not
  arbitrary extensions or password managers. macOS passkeys have no
  Space-scoped storage, so the passkey path exists only in the first Space.
