# Threat model

What Escale protects, from whom, and where the trust boundaries are. Reviews
read this instead of guessing; [SECURITY](../SECURITY.md) says how to report.

## Assets

- **Saved passwords and passkeys**: keychain items owned by Escale
  (`Passwords/Vault.swift`, `Passwords/Passkeys.swift`).
- **GitHub authorisation**: a keychain item per connected space
  (`GitHub/GitHubSecrets.swift`).
- **The app bundle itself**: whatever the updater swaps in runs with the
  user's rights and opens the keychain items above.
- **Browsing data**: history, bookmarks, sessions and per-space WebKit stores,
  under `~/Library/Application Support/Escale/` (`Storage/Store.swift`).
- **Isolation between spaces**: one space's cookies, logins and history never
  reach another.

## Attackers

| Attacker | Can | Must not be able to |
|---|---|---|
| A web page, or a frame inside one | Run any JavaScript in its own world, post to every message handler Escale registers, lie about its URL, title and form fields | Read or fill a credential for another origin, reach the native side beyond what a handler offers, script Escale's own pages, read another space's data |
| An installed extension | What its manifest permissions grant, through WebKit | More than those permissions, through Escale's shims (`Extensions/ExtensionShims.swift`) |
| The network | Serve or tamper with any non-TLS response, redirect the update feed | Get a bundle installed that is not Developer ID–signed by Escale's team with the hash the feed names |
| A contributor's pull request | Change any code | Add a request, a dependency or a production data path unnoticed (see [AGENTS](../AGENTS.md)) |

Out of scope: a local process running as the same user (it can read the
user's files anyway), physical access to an unlocked Mac, and WebKit's own
bugs, which are Apple's.

## Trust boundaries

1. **Page → native.** Every `WKScriptMessageHandler` (`Tabs/Tab.swift`,
   `Page/`, `Passwords/`, `Extensions/StoreRelay.swift`, `Blocking/Curtain.swift`)
   receives untrusted input. The origin comes from `message.frameInfo`, never
   from the body. Credential messages are accepted only from the main frame of
   the committed page, with a matching origin (`Tab.acceptsFormMessage`).
   Passkey client data carries the origin WebKit reports, not one the page
   states.
2. **Injected scripts.** `Scripts/*.js` run inside pages; anything they read
   from the DOM is the page's word. Scripts in the page world can be
   observed and patched by the page; secrets do not pass through them except
   the fill a user asked for.
3. **Update feed → bundle** (`App/Updater.swift`). HTTPS only (except a test
   feed set by `ESCALE_FEED`), SHA-256 of the ZIP checked against the feed,
   then the bundle id and a Developer ID requirement for the same team, before
   the swap. The updater never touches user data or the keychain.
4. **Local sockets** (`Bench/Bench.swift`, `App/DeveloperAlerts.swift`). Off by
   default, created `0600` in Escale's own folder, peer uid checked; the bench
   can run JavaScript in its own tabs, so it must never accept a peer from
   another user or open while off.
5. **Extensions and the Chrome Web Store** (`Extensions/`). Packages come from
   `clients2.google.com`; what Escale adds to WebKit's extension API widens
   what an extension can do and is reviewed as such.
6. **Spaces.** Each space has its own WebKit data store and keychain tag; code
   that looks up a login, cookie or history entry is given the space.

## What a review should flag

- A handler that trusts a URL, origin or host taken from the message body.
- A credential filled into, or saved from, a frame whose origin differs from
  the login's, or before the navigation committed.
- An update path that skips the hash, the signature requirement or HTTPS.
- A socket, port or listener that is on by default, world-readable or
  reachable from another user or the network.
- A request not listed in the README's [Privacy](../README.md#privacy) table.
- Data read or written outside `Store` or `Vault`, or across spaces.
- A force-unwrap on network, file or keychain data (a crash on hostile input).
