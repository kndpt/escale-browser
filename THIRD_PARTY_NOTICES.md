# Third-party notices

Escale's own code is under the GPL-3.0-or-later ([LICENSE](LICENSE)). It has
no package dependencies and no vendored code: it is built only with Apple's
frameworks and toolchain. This page lists everything else that the
repository contains or that a build uses.

## Code Escale started from

| What | License | Where |
|---|---|---|
| [Search](https://github.com/driceroland/Search), © Office Commun | MIT | The notice is kept in [NOTICE](NOTICE) and copied into every app `build.sh` makes. |

## Shipped in the app

| What | Where | Terms |
|---|---|---|
| GitHub Invertocat mark | `Sources/Escale/GitHub/Assets/github-invertocat.pdf` | Unchanged from <https://brand.github.com/GitHub_Logos.zip>. GITHUB and the Invertocat logo are trademarks of GitHub, Inc., used to identify the GitHub integration under GitHub's [logo guidelines](https://brand.github.com/foundations/logo). Not covered by Escale's license and implies no endorsement. |
| SF Symbols | Referenced by name in the interface | Provided by macOS at run time, under Apple's license; no symbol artwork is stored in this repository. |

The content blocker's list (`Sources/Escale/Blocking/Shield.swift`) is a short
list of domains and CSS selectors written for Escale; it is not derived from
EasyList or another filter list. The app icon and the Escale mark are drawn
from Escale's own path data (`Icon/icon.swift`, `Design.swift`).

## Used to build or test, not shipped

| What | License | Use |
|---|---|---|
| [dmgbuild](https://pypi.org/project/dmgbuild/) 1.6.7, with ds_store and mac_alias | MIT | Installed by `build.sh release dmg` into `.build/` to lay out the disk image window. |
| [actions/checkout](https://github.com/actions/checkout) | MIT | Checks out the code in CI. |

The Python tools (`verify`, `bench`, `Tests/`) use only Python's standard
library.

## Documents

| What | License |
|---|---|
| [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md): Contributor Covenant 2.1 | CC BY 4.0, attribution in the file |
| [CLA.md](CLA.md): adapted from the Apache Software Foundation Individual Contributor License Agreement v2.2 | Attribution in the file |
| [LICENSE](LICENSE): GNU GPL v3 text | © Free Software Foundation; verbatim copying permitted |

Screenshots in `docs/` are of Escale, mostly showing local test pages. Design
notes link to third-party interfaces by address instead of including their
pictures.
