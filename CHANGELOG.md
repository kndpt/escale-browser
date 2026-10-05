# Changelog

What changed from one version to the next, newest first. Changes not yet
released are in [changelog.d](changelog.d/README.md).

Escale starts from Search as it was on 24 September 2026
([driceroland/Search@b849335](https://github.com/driceroland/Search/tree/b849335)):
Search 1.0.1 and everything in its Unreleased section then. What changed in
Search before that is in
[its changelog](https://github.com/driceroland/Search/blob/b849335/CHANGELOG.md).

## Unreleased

## 0.7 — 2026-10-05

### Highlights

- **Escale is open source.** Anyone can now read, build and improve the browser's code.
- **Clearer transparency.** More of your desktop shows through the browser's own panels.

### What changed

- Escale's source is now public at github.com/kndpt/escale-browser, under the GPL-3.0-or-later; issues, feedback and pull requests live there.
- Clear transparency now lets much more of the background show through Escale's own surfaces, including Settings, with lighter glass and less tint. Text stays crisp, web pages stay opaque, and macOS Reduce Transparency still makes every surface solid.
- Password suggestions and filling now stay bound to the page that actually loaded when a navigation fails.
- The sidebar’s tab search button now sits to the right of the Space name, or at the top left when Spaces are disabled, instead of beside New tab.
- An extension update that would reach sites the installed version could not now asks first, as one that asks for new permissions does.
- A site on the local network with a certificate this Mac does not trust is now asked about once, like any other site; only servers on this Mac itself are still trusted without a question.
- Saved passwords are offered and saved only on pages that arrived over HTTPS, or on servers running on this Mac.
- Updates are installed only when Apple's Developer ID authority signed them for Escale's team, and only when the update feed gives their hash.

## 0.6.1 — 2026-10-03

### Highlights

- **Bearings' GitHub mode, private repositories included.** Press Shift–Command–K to find the pull requests and issues you have seen, with whether each is open, merged or closed; private repositories work too once added in Settings › GitHub.
- **Escale's own colours.** The browser can wear the warm sand and umber of Escale's website, in light and in dark.

### What changed

- A connected Space can now show the state of private repositories: Settings › GitHub lists the accounts and organizations that share repositories with Escale, with Change… and Add Private Repositories…, which open GitHub's page to choose them, and Bearings offers Add Repositories… at the foot of a list where GitHub refused one. A refused row keeps the state its open page showed, and is asked again once sharing changes or after five minutes, instead of staying unknown until Escale restarts.
- Saved passwords are now offered only on the host where they were saved (a leading www. still counts as the same host), preventing unrelated sites on shared hosting domains from receiving them.
- Settings › Appearance › Colours offers Escale beside Neutral, each shown as a small browser in its colours (cut light and dark when the theme follows the Mac): the sand, milk and brown-black ink of escalebrowser.com in light, its umber and cream in dark, with warm lines, shadows and selection, and a stained glass that keeps the warmth when Transparency lets the desktop through. Neutral stays the default.

## 0.6 — 2026-10-03

### Highlights

- **Find a pull request or issue in a keystroke.** Press Shift–Command–K to find a pull request or issue you have already seen or still have open, see at a glance whether it is open, merged or closed, and go back to its tab.
- **Live status with a GitHub connection.** Connect a Space to GitHub in Settings and the pull requests and issues on screen show their current status, without sending what you type.

### What changed

- Bearings has a GitHub mode, beside Tabs on ⌘K and New Tab on ⌘T, or directly on ⇧⌘K: it finds the pull requests and issues of the current Space in its history and its tabs, awake or asleep, with no account. Each item is one line, whatever sub-page you visited, with its title, repository, number and a state icon: open, draft, merged or closed. The state comes from a GitHub page already open in a tab, read once without waking or loading it; an older state stays visible, dimmed, with its age. Return goes back to the open tab, or opens the last address known. A state that arrives never moves the selection, and a private search sees only private tabs.
- A Space can be connected to GitHub from Settings › GitHub: Escale shows a code, opens github.com/login/device in a tab, then shows the account with Disconnect and Manage on GitHub. Once connected, only the lines on screen, six at most, are refreshed from GitHub, with a five-minute freshness; what you type, the repositories you have not visited and an idle browser ask nothing. The authorization stays in the Mac's keychain, one per Space, out of iCloud and exports.
- Each Space keeps the GitHub states it has seen in its own file, identities and states only, with no title or address, first read when Bearings’ GitHub mode or Settings › GitHub is opened. A private search writes nothing, forgetting history removes the items it forgets, deleting a Space removes its cache and authorization, a duplicated Space starts without either, and memory pressure frees the cache while keeping the file.
- Bearings pairs each of its searches with GitHub in a capsule at the end of its field, Tabs with GitHub on ⌘K and New Tab with GitHub on ⌘T, instead of GitHub reading as a separate place with a back button; the field also stays in place while results change below it; Tab switches between the two modes, and bookmark environments now take the left and right arrows.
- The extensions button and pinned extensions no longer vanish from the bar after moving between Spaces, and a Space without extensions no longer shows another Space's buttons.
- Welcome ends with a GitHub step: a live preview of Bearings' GitHub mode shows what it finds on this Mac and what a connection adds, then Connect GitHub shows the code and opens github.com in a tab, while Stay local starts browsing without an account. Settings › GitHub shows the same preview and controls.

## 0.5 — 2026-10-02

### Highlights

- **Shortcuts you can change.** Search, filter and reassign the browser's keyboard shortcuts in Settings, and switch Space with Option–Command–Up or Down.
- **Search tabs from the sidebar.** A magnifying glass beside New tab opens the tab switcher, so finding an open tab no longer needs the keyboard.
- **Quicker with the keyboard.** Opening, closing and switching tabs with a shortcut now moves three times faster, and you can turn that off.

### What changed

- Sidebar tabs and bookmarks give long titles more room and preserve both ends when truncated. Sleeping indicators are quieter, environment selectors are more compact, narrow bookmark rows use a compact environment picker, and hover actions keep their reserved space without squeezing titles twice.
- Link routing accepts pasted URLs with visible site, path and exact-address scopes. Unfinished rules stay available when you leave Settings to fetch a link. Tab and bookmark menus can open a prefilled rule, keeping any draft already in progress.
- Keyboard settings now offer a searchable catalogue of browser commands, with category and assignment filters, editable shortcuts, explicit conflict replacement and restore controls. Menus and hints follow your saved shortcuts. Standard formatting, Option character input and Control text-editing keys remain available to editors, including when loading older shortcut assignments. Previous and next Space use Option–Command–Up/Down by default, alongside configurable direct Space destinations. Editing and macOS gestures are grouped separately with explanations of who controls them.
- Search open tabs with the magnifying glass beside New tab, or beside the sidebar toggle when the sidebar is folded. The button opens the same focused tab switcher as ⌘K; search and New tab stay reachable below a scrolling sidebar list.
- Extensions that read text aloud now use macOS’s current speech engine, with pause, resume, voice selection and a bounded speech queue; disabling or removing an extension stops its pending reading.
- Tab selection, opening and closing, and switching between the sidebar and top tab bar now animate three times faster when triggered by a keyboard shortcut. Faster shortcut animations is on by default in Appearance settings, including for existing profiles; mouse actions keep their usual pace, and macOS Reduce Motion takes priority. Folding the sidebar or tab bar keeps its existing transition.

## 0.4 — 2026-10-02

### Highlights

- **Chrome imports without an export.** Escale finds Chrome on your Mac and brings over its bookmarks and history in a click.
- **Take Escale to another Mac.** Save all your Spaces in one protected file and open it in Escale on another Mac.
- **Link Routing has its own page.** Choosing which Space a site's links open in now has a clear page in Settings, with an example, a readable list and a box to try a link.

### What changed

- Import local profiles from Chromium, Edge, Brave, Vivaldi, Opera, Opera GX, Dia, Firefox, Zen and Orion. Supported Firefox and cleartext Chromium sessions can bring sleeping tabs, while Zen offers workspace folders, pins and essentials. Safari exports now use individual import actions. Unsupported formats and encrypted sessions report their limits; passwords continue to use CSV exports, and sign-ins are not transferred.
- With Reduce Motion on, a split's page tools, focus ring, resize grip, carried tab (and the fade of the row it leaves), group entry and split menus no longer animate, like the rest of the split.
- When macOS refuses Escale the folder of Chrome or another automatic browser, which it does without asking on recent versions, Import Data now opens the folder picker on that browser's folder with a short explanation, so one click on Open is enough, and says why if the picker is dismissed.
- Lists of sites (the bookmarks shelf and panel, passwords, History) no longer read each site's icon from disk while they are drawn: they show a letter and the icon follows once read in the background.
- The Localhost panel now says which visited servers are no longer listening, or date from before the Mac restarted, and the number on its door counts only the pages that may still load; nothing is deleted, and a server that comes back is listed as running again.
- Import Data detects Chrome and reads its profiles directly: bookmarks (including those saved to the Google account) and history import in one click per category, without exporting a file first. Passwords still come from a CSV exported from Google Password Manager. History read while Chrome is writing to it no longer risks importing unsaved changes.
- Command-clicking Back, Forward or Reload opens the destination in a new background tab while the current tab stays where it is, including in private browsing and another Space.
- Settings › Import › Export Escale… saves every Space, with its bookmarks, tabs, history, settings and, if you choose, saved passwords, in one file protected by a passphrase, and Import → Escale brings it into another Mac. Spaces arrive as new Spaces next to yours, nothing is replaced, opening the same file again adds nothing twice, and you sign in to sites again.
- Clicking into a sign-in box for a site with a saved account no longer freezes the window while macOS asks for permission to read the keychain: the accounts are read in the background and hang from the box when they arrive.
- A page that fails to load keeps the address it was sent to, with its reason, instead of the tab falling back to the page it was showing, and Retry loads that address again.
- Link Routing moves to its own page under Features at the top of Settings: each rule reads as site → Space, a new rule asks only for the site and its Space, precise matching waits under one fold, rules move up and down in place, and trying a link shows which rule wins as you type.
- Settings are drawn at the browser's own size: smaller text, rows and controls, in line with the tabs beside them, at every interface size.

## 0.3 — 2026-09-30

### Highlights

- **Bearings learns what you pick.** Type the same thing again and the page you chose last time comes up higher.
- **Updates you can see coming.** A new version shows up as a button at the foot of the sidebar; one click says what it brings and relaunches.
- **Browse, pause and search API calls.** Go from one request to the next with the arrow keys, pause recording without losing the list, and find a word inside any response.

### What changed

- The sidebar mini player keeps its previous, next, volume, Picture in Picture and dismiss buttons in view when VoiceOver or full keyboard access is on, so they can be reached without hovering the card.
- The selected tab's row in the sidebar no longer slips over the row beside it when a bookmarks folder is opened and shut in quick turns in a window just tall enough to hold the column: tab rows now fade in and out where they used to fade and scale, so they stay on their own slots while the column swaps between its plain and scrolling layouts.
- Bearings now remembers which result you took for what you typed: take the third result for `handlers`, and the next `handlers` shows it first among the results that match as well, a second choice lifting it past a slightly closer match, never past the words as typed. A new habit wins on its second choice and an old one fades over about ten weeks. Nothing is added to the list, the grey completion and a typed address still go where they say, private search learns nothing, each Space keeps its own, and Clear History forgets it. New Tab also orders the best six open tabs, bookmarks and pages together before keeping six, so a closer result is no longer cut because its source had already filled its share.
- The sidebar shows fewer actions at rest: the bin on the Tabs heading now appears when the pointer is anywhere on that heading, and each open tab or open bookmark gets a Copy button beside its cross that copies the address it is really at now. Every copy button (address bar, text selection menu, Network and the sidebar) is now the same one, with a quicker swap to the green check and a hold that restarts on each click.
- A new download now sends a small plane from the page to the download button instead of a file: its nose follows the curve, it is mirrored when the button is on the left, and it flies a little more slowly than the file did. With Reduce Motion it is skipped and the button simply appears.
- A Google Meet meeting now floats in a meeting window of its own: everyone in it along the top, with their picture, photo or initial and a muted microphone, the shared screen whole and at its own shape beneath them, and the meeting's microphone, camera, presenting, raised hand and hang-up along the bottom, each showing and changing the meeting's real state. The window stays while the meeting lasts, with every camera off and in another Space, instead of closing and leaving the call in a tab nobody sees. Hanging up leaves the call even when Meet asks its host whether to end it for everyone, and a meeting's card in the mini player has its microphone and goes when the meeting is left. A tab's speaker now sits at the start of its row, before the title. A floating video that sat in a corner with part of it cut off now fills its window.
- An update now shows itself behind a door at the foot of the rail, beneath Settings, from the moment it starts to arrive: a clock while it downloads, a check once it is in place. The door opens a panel with a boarding pass from this version to the next, the version's summary, the download's progress and Relaunch now, with Later and What changed beside it. After the relaunch the tabs come back as they were, and the first launch of the new version says once what it brought, from a note inside the app, with no network needed.
- In the Network tool, ↑ and ↓ go to the newer or older call without going back to the list, two arrows at the foot of an opened call do the same, and the list says it shows the newest first. Recording can be paused and resumed without losing the list, and Clear empties it in either state. The filter also finds a word in the responses of the calls listed, shows a short excerpt around it and opens the call on the place where it was found.

## 0.2 — 2026-09-30

- The Localhost door now shows how many local pages the Space remembers, and choosing one returns to the tab of the bookmark that owns it, switched to its local environment, instead of opening another tab.
- Select text on a page with the mouse and a round Copy button pops up where you let go, with Translate drawn out of it: Copy copies the text as ⌘C would, and Translate opens Apple's translation panel. Never over a field, gone with the next click, key or scroll, and it can be turned off in Settings › Web Pages.
- The search bar behind ⌘T, ⌘L and ⌘K now has a name, Bearings: its field reads "Bearings · Search or enter an address", and Settings › Keyboard lists the three keys under it, each with its job: go somewhere new, change this page's address, switch to an open tab. The menus keep New Tab and Open Address….
- Bearings finds open tabs, bookmarks and history by their words, whatever joins them: `orchestrator handlers` finds `iso--checkout--orchestrator-handlers`, `orchestrator_handlers`, a path `/orchestrator/handlers` or `OrchestratorHandlers.java`, ignoring case and extra spaces, with the last word still being typed. The words may be spread over a page's title and address, or a bookmark and its environments: `orchestrator handlers swa` finds a "Swagger UI" page on `reception-orchestrator-handlers…`, and `atlas dev` a bookmark "Project Atlas" with a DEV environment. Every word has to start a word of the place, and a match as typed still comes first; the web search keeps exactly what was typed.
- Back and Forward history menus show the page title with its domain and path, without query strings or fragments, still go to the exact address, and list the pages around the current position again after a jump.
- Environments that share one console address can now be told apart by the start of their path. In Associate Environments…, choose Domain + Path and click the segment that identifies each one, such as `cluster-prod`: its name then follows every page under that part of the address, while other routes, hosts and ports stay unlabelled. The most specific match wins, never the order of the rows, and existing associations keep recognising their whole domain.
- Opening or shutting a bookmark folder now moves the rows below it out of the way first and then fades the folder's rows in, and out before the rest closes up, in the sidebar and in the bookmarks list. Nothing is animated with Reduce Motion on.
- The sidebar's reading line now spans the page's frame from one rounded corner to the other instead of the whole window: it no longer runs over the Developer panel's tab, and its first millimetres no longer show inside the corner. The page and the Developer column keep their top edges aligned, and the line follows the page's width when the Developer column is dragged.
- The search card (⌘T, ⌘L, ⌘K) drops its footer of key hints and the action word repeated on every row. Only the selected row says what Return does — ↵ Open, or ↵ Switch to tab for an open page — and the ⇥ that steps between environments now ends the row of environment chips, on the selected result that has them. Keyboard behaviour is unchanged.
- History → Show History… opens at once with a full history: the panel builds only the lines in view instead of all of them. With 1,800 synthetic lines on an M1 it settled in about 15 ms instead of 2 s, closing in 10 ms instead of 450 and a search in 60 ms instead of a second; the look, search, removal and each Space's own history are unchanged.
- The Tabs heading in the sidebar ends with Clear, a bin icon in the place of a tab's cross that opens onto its word under the pointer, which closes every ordinary tab listed there for the current Space in one press, the one on screen included. Pins, bookmarks (open or not) and other Spaces are untouched; each tab closes as ⌘W closes it, so ⌘⇧T reopens them and history and site data stay. It lands on the tab last looked at among those that stay, or on a blank tab when none is awake, and is absent when nothing can be closed.
- The camera menu renames the viewport capture Visible Page (and the Page Tools item Capture Visible Page) and adds Select Area…: drag a rectangle over the visible page and it is captured the moment it is let go; Esc cancels. The image follows page zoom and screen scale, the page receives none of the gesture, and a tab change, Settings or navigation cancels the selection. A finished capture (any mode) now appears as a compact card in the page's lower right corner, image above and Copy and Save flush beneath it, in place of the large Page Capture panel and its context options (no more Copy Context); it stays until its cross, Escape or the next capture, and shows Copied or Saved for a moment. Capture size limits are unchanged.
- A Space's door in the rail wears a small mark at its lower right while something in that Space plays sound or a video or has the camera or the microphone on — the microphone first, then the camera, a video, sound — so you can tell where a meeting or a song is coming from after changing Space. A microphone or camera muted at WebKit's level, a pause or a silent page shows nothing; a meeting muted from its own button keeps the microphone mark while the capture stays open, as macOS's own indicator does.
- A meeting in the floating window has the same "return to mini player" button as a film, and the sidebar card shows the same Picture in Picture button for a meeting as for a video; either lifts or returns the meeting to the other, with the call running throughout.
- A Google Meet meeting can float in the small window when its tab or Space is left, showing the speaker or the shared screen with Return, Microphone and Hang up, and keeping the call, audio, camera and microphone running otherwise; it opens only once other people's video is playing and closes by itself when no one is left to show.
- Changing Space no longer pauses or cuts what a page plays, including a meeting, and needs no reload to hear it again; the sidebar player change removed the pause, and a scenario now guards meetings, songs and films across Space changes and the sleep rules.

## 0.1 — 2026-09-29

The first Escale. This is what 0.1 contains.

- **Spaces, one per project.** A rail of Space icons beside the sidebar. Each Space keeps its own tabs, pins, bookmarks, history, site data, downloads, saved passwords, site settings and extensions. Local rules in Settings › Tabs & Spaces send a link to its Space before it loads.
- **Sidebar and tabs.** Tabs in the sidebar with bookmarks above them and an address bar over the page, or a classic tab row. Pinned tabs, split groups of up to three pages, tabs and bookmarks carried between Spaces by holding them on a Space icon, and folders made by holding one bookmark over another. A tab opened from a link goes back to its page when closed.
- **Bookmark environments.** A bookmark keeps up to 20 named links (DEV, STAGING, PROD…), opened from a compact selector; the label follows the page on that host and port. Labels are reminders, not a guard against acting on production.
- **New Tab and the address field.** ⌘T searches over the current page and lists open tabs, bookmarks and their environments first; Tab and ⇧Tab move between environments. ⌘K switches tabs. History matches partial titles and paths.
- **Developer tools.** Developer mode's Network panel (⌥⌘N) lists a tab's API calls from WebKit's own Web Inspector collection, with headers, a JSON tree, copy as cURL and Copy for AI with credentials redacted. Site Data edits cookies and localStorage; JSON responses open as a searchable tree; visual inspection shows fonts and colours; page capture copies or saves a PNG. Web Inspector stays on ⌥⌘I and can be docked. A Localhost hub lists recent local servers, and local tools can post build and pull-request notifications, when turned on.
- **Import.** From Arc (a Space's pinned tabs with their folders, its Favorites and history), the Chromium family, Aside, Firefox-family profiles, Safari exports and lists of links, with a preview before anything is written and safe re-runs. Not every browser version is qualified yet.
- **Chrome extensions on WebKit.** Added from the Chrome Web Store or a folder, run by WebKit's extension engine, with the missing Chrome APIs filled in by Escale. macOS 15.4 or later.
- **Media.** A mini player in the sidebar for audio playing in the background, across Spaces, with Picture in Picture. Shared screens favour legible detail.
- **Downloads.** A top-bar indicator with progress while files transfer, and each Space's Downloads panel.
- **Appearance.** A translucent frame around an opaque, rounded page; Transparency (Solid, Subtle, Clear) and Increase Contrast; Compact, Standard and Large interface sizes; page zoom kept separate.
- **Pages in the background.** Tabs sleep when unused and show it; a tab with an unsent draft stays awake. Site icons, history and page snapshots are kept within fixed bounds.
- **Your data.** No account, no telemetry. Passwords stay in the macOS keychain. A site's data can be reset in one Space without touching the others.
- **Updates and feedback.** Once a day Escale reads escalebrowser.com for a newer build, checks its hash and signature, and swaps it in for the next launch; nothing restarts on its own. Help › Send Feedback… opens an issue on [kndpt/Escale-releases](https://github.com/kndpt/Escale-releases) with the version filled in.
- **Its own app.** Escale has its own name, icon and bundle id (`com.kndpt.escale`), and keeps its data apart from Search's, so both can run side by side. Built on Search 1.0.1 by Office Commun (MIT).
