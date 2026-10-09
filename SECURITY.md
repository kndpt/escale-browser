# Security

## Reporting a vulnerability

Please do not open a public issue for a security problem.

Report it privately with GitHub's **Private vulnerability reporting**: open the
[Security tab](https://github.com/kndpt/escale-browser/security) of this
repository and choose **Report a vulnerability**, or go straight to
[the form](https://github.com/kndpt/escale-browser/security/advisories/new).
Only the maintainer can read the report.

Include, when you can:

- the Escale version and build (Settings › About) and the macOS version;
- what an attacker can do, and what they need first (a page they control, a
  local process, physical access…);
- steps or a small page that reproduces it.

You will get an answer as soon as the maintainer can look at it. Escale is
maintained by one person, so there is no guaranteed delay. Once a fix is
released, the advisory is published with credit to you, unless you prefer
otherwise.

## Supported versions

Only the latest release receives fixes. The app checks for updates every 2 hours
and installs a new version only after you choose to relaunch.

## Areas of particular interest

- the updater (`Sources/Escale/App/Updater.swift`): the feed, the download
  and the checks before an update is swapped in;
- saved passwords and passkeys (`Sources/Escale/Passwords/`);
- web extensions and the scripts Escale injects into pages;
- the local sockets used by `./notify` and the developer script bridge, which
  are off by default.
