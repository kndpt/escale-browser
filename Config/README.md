# Config

Local settings for building and publishing signed releases. Contributors do
not need anything here: `swift build`, `./test.sh` and `./build.sh` work
without it, and `./build.sh` signs the app ad hoc so it runs on your own Mac.

## Signing and release variables

`build.sh` and `publish.sh` read `Config/Signing.local.env` when it exists.
Git ignores that file; copy `Signing.local.env.example` to start one. The same
variables can also be set in the environment.

| Variable | Used by | Meaning |
|---|---|---|
| `ESCALE_SIGN_IDENTITY` | `build.sh` | Developer ID Application certificate in the login keychain. Unset: ad-hoc signature. `./build.sh release ship` stops without it. |
| `ESCALE_NOTARY_PROFILE` | `build.sh release ship` | `notarytool` keychain profile (default `escale`). Credentials stay in the keychain, never in a file. |
| `ESCALE_REPOSITORY` | `build.sh`, `publish.sh` | GitHub repository that hosts the releases. |
| `ESCALE_DOWNLOAD_URL` | `build.sh release dmg` | Folder the appcast points to for the ZIP and DMG (default: this version's release on `ESCALE_REPOSITORY`). |
| `ESCALE_GITHUB_CLIENT_ID`, `ESCALE_GITHUB_APP_SLUG` | `build.sh` | Override the public GitHub App identifiers in `GITHUB_CLIENT_ID` and `GITHUB_APP_SLUG`. |

Passkeys also need a Developer ID provisioning profile named
`Escale.provisionprofile` at the repository root (ignored by git) and the
Team ID in `Escale.passkeys.entitlements`.

`publish.sh` uses the GitHub CLI (`gh auth login`) with push access to
`ESCALE_REPOSITORY`.
