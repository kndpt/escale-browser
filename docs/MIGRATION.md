# Browser migration

How Escale imports another browser's data, and how one Escale moves to another
Mac. An import is an explicit, repeatable copy into one Escale Space, never a
background or two-way synchronisation. The code is in `Sources/Escale/Migration/`
and `Sources/Escale/Transfer/`. "Automatic" names a route, not a promise that
every release of that browser works.

## Supported sources

Data homes are under `~/Library/Application Support/`.

| Browser | Bundle id | Data home | Route | Imported | Deliberately not |
|---|---|---|---|---|---|
| Chrome | `com.google.Chrome` | `Google/Chrome` | Automatic | Bookmarks and `AccountBookmarks`, history, cleartext saved tabs; HTML bookmark export as fallback | Encrypted sessions, tab groups, icons, `Login Data` |
| Chromium | `org.chromium.Chromium` | `Chromium` | Automatic | Bookmarks, history, cleartext saved tabs | As Chrome |
| Edge | `com.microsoft.edgemac` | `Microsoft Edge` | Automatic | As Chromium | Collections |
| Brave | `com.brave.Browser` | `BraveSoftware/Brave-Browser` | Automatic | As Chromium | Wallets, Rewards, Brave-specific data |
| Vivaldi | `com.vivaldi.Vivaldi` | `Vivaldi` | Automatic | As Chromium; Speed Dial folders stay folders | Workspaces, stacks, notes; unknown roots such as trash |
| Opera, Opera GX | `com.operasoftware.Opera`, `…OperaGX` | Same as the bundle id | Automatic | As Chromium; a profile may sit at the root | Speed Dial UI, workspaces, GX data |
| Dia | `company.thebrowser.dia` | `Dia` | Automatic | As Chromium | Chats, skills, Dia organisation |
| Aside | `at.studio.AsideBrowser` | `Aside` | Automatic | Bookmarks, history; HTML export as fallback | Vault, cloud, tabs, workspaces, chats |
| Arc | `company.thebrowser.Browser` | `Arc` (`StorableSidebar.json`) | Automatic | Per Arc Space: pinned tree as bookmarks after a Favorites folder, its profile's history; Copy All Links as text or Markdown as fallback | Today tabs, Easels, Boosts, split views, non-web links |
| Firefox, ESR, Beta, Developer, Nightly | `org.mozilla.firefox`, `…firefoxdeveloperedition`, `org.mozilla.nightly` | `Firefox` (`profiles.ini`) | Automatic | Places bookmarks and history, sleeping tabs; HTML and CSV | Containers, groups, extension state, NSS passwords |
| Zen | `app.zen-browser.zen` | `Zen` | Automatic | Places per profile; per workspace its folders, essentials, pins and tabs | Split views, live folders, icons, containers |
| Orion | `com.kagi.kagimacOS` | `Orion` | Automatic | Ordered favourites, history | Named windows, pins, reading lists |
| Safari, Technology Preview | — | — | Export | From Safari's ZIP export: bookmarks, passwords CSV, each profile's history | Tabs, groups, pins; Safari's home is never read |
| Another browser | — | — | Export | Bookmarks HTML, passwords CSV, a plain list of links | Anything not in the file |
| Escale | — | — | Escale file | See [the transfer file](#escale-transfer-file) | — |

For every source, passwords come only from a CSV the user exports, and
cookies, sign-ins, extensions and passkeys never transfer. Chrome Beta, Dev,
Canary and Chrome for Testing keep their own identity and folder: they are not
suggested and are read by choosing their folder. Firefox's channels share one
`profiles.ini`; no edition is guessed from a folder name.

## How an import works

1. The person chooses a destination Space, a browser, then one profile or
   export. Nothing is preselected. Suggestions come from local app
   registrations only; no profile is read.
2. Choosing a browser starts discovery in its home, never at launch or in a
   view. If macOS refuses the folder, the person chooses it once in the file
   picker. Any profile folder can be chosen by hand.
3. Chromium discovery serves every Chromium brand: names from `Local State` (a
   malformed one is refused), `Default` and `Profile N`, custom folders in
   `info_cache`, a profile at the root, no `System Profile` or `Guest Profile`,
   and no link leaving the chosen folder. Gecko reads `profiles.ini` entries and
   removes duplicate paths.
4. Each category (bookmarks, history, tabs, passwords) has one **Import**
   action that reads, validates and applies without a second confirmation.
5. Each owner acknowledges its write through its `Writer` before the category
   counts as done. The receipt holds fingerprints and counts, never passwords,
   names, URLs or exported data.

Merging is conservative and safe to repeat:

- The plan is a snapshot applied to the captured Space. A missing destination
  or changed bookmarks stop it; that Space cannot be deleted meanwhile. Leaving
  the import cancels outstanding work.
- Existing bookmark identities, edits and moves are kept; new ones are added;
  same-named folders never replace each other. Exports have no native IDs, so
  identity comes from folder names, URL and position. A deleted imported item
  may return on a later import.
- History reads 2,001 recent candidates at most and keeps 2,000 valid entries,
  then the Space's own 2,000-place bound applies. Counts take the maximum, so
  replay is safe but not an exact union.
- Passwords use an add-only keychain operation. An Escale-owned duplicate is
  kept without reading its secret; a foreign keychain item in the way is a
  reported failure. Notes and one-time-code fields are reported as lost.
- Cancelling before applying changes nothing. During application, acknowledged
  categories and added passwords stay. There is no transaction across files and
  the keychain; resuming means choosing the source again and replaying.

## Bounds and safety

- Text, JSON and ZIP input (`MigrationLimits`): 32 MiB, 50,000 records, folder
  depth 32, 32 KiB per field. An oversized bookmark input fails as a whole.
- Chromium discovery: at most 2,000 directory entries and 200 profiles; links
  outside the root are ignored; labels and file presence only, no secrets.
- Arc: the same caps and at most 200 Spaces. Keyed arrays must alternate an id
  and its object; cycles and missing children are skipped and counted. An
  unknown sidebar shape is refused. History must resolve inside the Arc folder.
- SQLite: main file, WAL and rollback journal together at most
  `MigrationSQLite.byteLimit` (256 MiB), ordinary files only. They are copied in
  1 MiB chunks, checked by inode, size, mtime and SHA-256, then read through
  SQLite backup on the private copy. A hot `History-journal` is copied too, so a
  half-done write rolls back on the copy. SQLite never opens the source; a
  source that changes during the copy fails with guidance to close it.
- One SQLite acquisition at a time, 5-second deadlines, a 2 MiB page cache.
  Temporary copies go at every exit, abandoned ones on the next acquisition;
  together they can use roughly 512 MiB.
- A profile's files are not read as one transaction. Close the source browser,
  or use an export, for a point-in-time view.
- ZIP: at most 128 entries and 32 MiB expanded, stored or deflated, with length
  and CRC checks through macOS zlib; nothing is extracted. ZIP64, encryption,
  symlinks, unsafe or duplicate paths and bad headers are refused.
- A reader opens no URL, fetches no icon, installs no extension, asks for no
  key and adds no recurring task. None reads `Login Data`, `key4.db`, cookies,
  passkeys or cloud sync.

## Session and tab formats

`MigrationTabs` adds tabs to the captured Space and keeps its selection and
tabs; new pins join the pinned prefix. At most 2,000 tabs per selection, with
URL, title and pin. No web view is built or loaded. `Session.Entry.migration`
and `Tab.migration` keep provenance, so the person's edits win on replay.
Private and closed windows, POST entries, form state and window or group
appearance are left out with a notice. Importing 2,000 tabs costs roughly
600 MiB and about 5 s although no page is built.

- **Chromium SNSS.** Versions 1 and 3; version 3 needs its initial-state
  marker. Commands replay order, navigation, pruning, pins, GUIDs and closures;
  an unknown command fails the category. At most 200,000 commands, 50,000
  navigations, 2,000 tabs and 200 windows. The newest session file is read and
  a corrupt one does not fall back. Encrypted sessions and versions 2, 4 and 5
  refuse tabs only.
- **Firefox.** The newer of `sessionstore.jsonlz4` and
  `sessionstore-backups/recovery.jsonlz4`; the `mozLz40\0` header and length
  are checked before Apple's raw LZ4, with 32 MiB caps. Without tab IDs,
  position plus URL keeps replay stable; a moved tab may come back.
- **Zen.** The shared sidebar `zen-sessions.jsonlz4`, accepted by its checked
  shape, or the legacy envelope with `zen_workspaces` in Places. Workspaces are
  chosen by UUID and never become Escale Spaces. Pins and folders become
  bookmarks; shared essentials join each workspace.
- **Orion.** Its own adapter: profile plist, `favourites.plist` parent links and
  `history_items` SQLite. Every node ID, parent, type, index, depth and URL is
  checked; cycles fail.

## Escale transfer file

**Settings › Import › Export Escale…** saves every Space in one file,
`Escale-YYYY-MM-DD.escale`; **Import → Escale** brings it into another Escale.
It holds the state at export time and involves no account or network.

**Format.** Big endian: `ESCLXFER`, format version (2 bytes), PBKDF2-HMAC-SHA256
rounds (4), salt (16), then an AES-GCM box whose associated data is the header.
The key comes from the NFC-normalised passphrase (8 characters at least) with
`TransferFile.rounds`, accepted within `roundsRange`. The payload is JSON
(`TransferPayload`). The passphrase is never stored or logged. A wrong
passphrase and an altered file give the same answer. A newer format or schema
is refused before decoding; the file is read once, 64 MiB at most.

**What travels.** Each Space becomes a new Space with its own identity, WebKit
store and keychain partition, never merged by name. With it: bookmarks,
folders, environments and Domain rules (http and https only), tabs as
addresses, pins, split groups, history, what Bearings learned, hidden elements,
per-site zoom, blocker pauses, "never save" sites and link rules (at most
`LinkRule.limit`). Preferences in `TransferPreferences` are offered, on by
default only for an untouched Escale. Extensions join a "to reinstall" list.
Passwords travel only with **Include saved passwords**.

**What does not.** Cookies, sign-ins, site storage, passkeys, macOS
permissions, tokens, extension grants, capture decisions, downloads, local
endpoints, private browsing, caches and any path on the source Mac.

**Validation.** `TransferPayload.checked` runs before anything is written.
Bounds (`TransferLimits`), repeated identities, a dangling reference, an
incomplete split or a non-http(s) split tab refuse the whole file. What is
only not portable is dropped and counted. A Space's files are written and
flushed, then the Space list, and only then is the Space published; a failure
erases what was written. Passwords come last.

**Replay.** New identities derive from the file's transfer id, so opening the
same file again adds nothing twice and keeps local edits; what was not
acknowledged the first time is added. Saving snapshots every owner in one turn
of the main actor and writes atomically, so a failed save keeps the earlier
export.

## For contributors

- A test run reads each automatic brand from its own test root,
  `Store.file("migration-<slug>")`, the slug being the lowercase alphanumeric
  brand name (`chrome`, `operagx`). It never falls back to the real home.
- `ESCALE_<SLUG>_SOURCE=/absolute/path` points a brand at another source in a
  test run only (`MigrationFlow.init`); the destination stays in the test
  world. Automated tests never set it.
- No personal profile is a fixture; tests generate theirs in temporary folders.
- Unit tests: `MigrationTests`, `MigrationReadersTests`, `MigrationFamilyTests`,
  `MigrationChromeTests`, `MigrationAsideTests`, `MigrationArcTests`,
  `MigrationBrowserTests`, `TransferTests`.
- Scenarios in `Tests/Bench/`: `migration.py`, `migration_keychain.py`,
  `migration_aside.py`, `migration_arc.py`, `migration_chrome.py`,
  `migration_browsers.py`, `transfer.py`; resources in
  `migration_resources.py`, `migration_session_resources.py` and
  `transfer_resources.py`.
  `bench transfer … fail STEPS` fails a named write as a full disk would.

## Not qualified

- Installed browser releases: readers are checked against synthetic fixtures
  and published formats only.
- macOS 14 and 15 at run time, real permission sheets, VoiceOver.
- A real Mac-to-Mac transfer. Two Escale worlds on one Mac must not import the
  same transfer, since a keychain item is unique by site, account and path.

## Format references

These describe shapes, not stability promises.

- Chromium: [profile directories](https://chromium.googlesource.com/chromium/src/+/HEAD/docs/user_data_dir.md);
  sessions 154.0.8037.58 [storage](https://github.com/chromium/chromium/blob/154.0.8037.58/components/sessions/core/command_storage_backend.cc),
  [commands](https://github.com/chromium/chromium/blob/154.0.8037.58/components/sessions/core/session_service_commands.cc),
  [navigation](https://github.com/chromium/chromium/blob/154.0.8037.58/components/sessions/core/serialized_navigation_entry.cc).
- [SQLite backup](https://sqlite.org/backup.html).
- Firefox: [profile contents](https://support.mozilla.org/en-US/kb/profiles-where-firefox-stores-user-data),
  [SessionStore](https://github.com/mozilla-firefox/firefox/blob/073470574580ca3c5d05feddc3fd7b98408e80fc/browser/components/sessionstore/SessionStore.sys.mjs).
- Zen 1.22.3b: [sidebar](https://github.com/zen-browser/desktop/blob/1.22.3b/src/zen/sessionstore/ZenSessionManager.sys.mjs),
  [tab metadata](https://github.com/zen-browser/desktop/blob/1.22.3b/src/browser/components/sessionstore/TabState-sys-mjs.patch),
  [folders](https://github.com/zen-browser/desktop/blob/1.22.3b/src/zen/folders/ZenFolders.mjs);
  1.17.15b [legacy metadata](https://github.com/zen-browser/desktop/blob/1.17.15b/src/browser/components/sessionstore/TabState-sys-mjs.patch);
  [session recovery](https://docs.zen-browser.app/user-manual/window-sync).
- [Safari export format](https://developer.apple.com/documentation/safariservices/importing-data-exported-from-safari).
- [Arc link export](https://resources.arc.net/hc/en-us/articles/25583851606039-How-Do-I-Export-my-Pinned-and-Favorite-Tabs-in-Arc-to-Another-Browser).
- Orion: [technical information](https://help.kagi.com/orion/misc/technical.html);
  a public reader's [profiles](https://github.com/raycast/extensions/blob/3d7aa375114b13713f4deeba392ce2f5d1c88c0f/extensions/orion/src/hooks/useProfiles.ts),
  [bookmarks](https://github.com/raycast/extensions/blob/3d7aa375114b13713f4deeba392ce2f5d1c88c0f/extensions/orion/src/types.ts),
  [history](https://github.com/raycast/extensions/blob/3d7aa375114b13713f4deeba392ce2f5d1c88c0f/extensions/orion/src/hooks/useHistorySearch.ts).
