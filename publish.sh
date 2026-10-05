#!/bin/bash
# Puts the three files build.sh made on a GitHub release of Escale: the disk
# image for people, the ZIP for the updater, and the appcast that names them
# both. The release is tagged vX.Y from VERSION, on Escale's public
# repository (ESCALE_REPOSITORY, from the environment or
# Config/Signing.local.env).
#
#   ./publish.sh
#
# ./build.sh release ship makes the files first. Nothing goes out unless the
# three agree with each other and with the notes: the DMG notarised and
# stapled, the appcast naming this VERSION, the ZIP holding that version and
# build and hashing to what the appcast says, CHANGELOG.md holding a
# section for this version, and the checkout clean, pushed and the very
# commit the app was built from, which the tag then names. Its notes are the first paragraph of NOTES.md —
# the line Settings shows — then that section's Highlights, when it has any,
# and its list of what changed.
#
# The names never change, so releases/latest/download/<name> always points at
# the newest one. escalebrowser.com redirects /appcast.json and /download
# there (_redirects in the landing page), and that is the address
# Updater.feed reads. Once the release is up, the appcast and the DMG are
# fetched the way a Mac with no GitHub account would, and compared with what
# was sent. GitHub moves `latest` a little after the release exists (about two
# minutes for 0.2) and keeps naming the previous appcast until then, so the
# feed is asked again every 15 seconds for up to 5 minutes before it counts as
# wrong, each request cut off after 30 seconds so a silent server cannot stall
# the wait. Needs the GitHub CLI signed in with push access to that
# repository.
set -euo pipefail

cd "$(dirname "$0")"
if [ -f Config/Signing.local.env ]; then
  # shellcheck disable=SC1091
  . Config/Signing.local.env
fi
VERSION="$(tr -d '[:space:]' < VERSION)"
REPO="${ESCALE_REPOSITORY:-kndpt/escale-browser}"
FEED="https://escalebrowser.com/appcast.json"
FILES=(build/Escale.dmg build/Escale.zip build/appcast.json)

fail() { echo "$1" >&2; exit 1; }

for FILE in "${FILES[@]}"; do
  [ -f "$FILE" ] || fail "$FILE is missing — ./build.sh release ship makes it"
done
xcrun stapler validate -q build/Escale.dmg >/dev/null 2>&1 \
  || fail "build/Escale.dmg is not notarised — ./build.sh release ship does that"

# plutil reads JSON as well as plists, so no other tool is needed to check it.
field() { plutil -extract "$1" raw -o - "$2"; }
[ "$(field version build/appcast.json)" = "$VERSION" ] \
  || fail "build/appcast.json is for $(field version build/appcast.json), VERSION says $VERSION"
BUILD="$(field build build/appcast.json)"
SHA="$(field sha256 build/appcast.json)"
[ "$(shasum -a 256 build/Escale.zip | cut -d' ' -f1)" = "$SHA" ] \
  || fail "build/Escale.zip does not hash to the appcast's sha256 — rebuild both together"
PLIST="$(mktemp)"
trap 'rm -f "$PLIST"' EXIT
unzip -p build/Escale.zip Escale.app/Contents/Info.plist > "$PLIST"
[ "$(field CFBundleShortVersionString "$PLIST")" = "$VERSION" ] && [ "$(field CFBundleVersion "$PLIST")" = "$BUILD" ] \
  || fail "the app in build/Escale.zip is not $VERSION build $BUILD"

# The release's text: NOTES.md's first paragraph (the line Settings shows),
# then the "## X.Y" section of CHANGELOG.md — `./changelog body` fails when
# that section is missing.
NOTES="$(mktemp)"
trap 'rm -f "$PLIST" "$NOTES"' EXIT
./changelog body "$VERSION" > "$NOTES" || fail "no release text for $VERSION"

# The tag must name the sources the binaries came from: a clean checkout,
# already on the repository, which the app says it was built from.
SOURCE="$(field EscaleSourceCommit "$PLIST" 2>/dev/null || true)"
HEAD="$(git rev-parse HEAD)"
[ -z "$(git status --porcelain)" ] || fail "the checkout has changes — commit them and rebuild"
[ "$SOURCE" = "$HEAD" ] || fail "the app was built from ${SOURCE:-an unknown commit}, not HEAD ($HEAD) — rebuild"
git fetch --quiet origin && git branch -r --contains "$HEAD" | grep -q . \
  || fail "$HEAD is not on the repository yet — push it first"

gh release create "v$VERSION" "${FILES[@]}" --repo "$REPO" --target "$HEAD" --title "Escale $VERSION" --notes-file "$NOTES"
echo "published: Escale $VERSION on $REPO"

# As a Mac that has never signed in to GitHub sees it: through Escale's own
# address, redirects followed, no credentials.
PUBLIC="$(mktemp)"
trap 'rm -f "$PLIST" "$NOTES" "$PUBLIC"' EXIT
began=$SECONDS
while :; do
  if ! curl -fsSL --connect-timeout 10 --max-time 30 -o "$PUBLIC" "$FEED"; then
    why="$FEED does not answer — is the landing page's _redirects deployed?"
  elif [ "$(field build "$PUBLIC" 2>/dev/null)" = "$BUILD" ] && [ "$(field sha256 "$PUBLIC" 2>/dev/null)" = "$SHA" ]; then
    break
  else
    why="$FEED serves another appcast (build $(field build "$PUBLIC" 2>/dev/null || echo "?")) than the one just published"
  fi
  waited=$((SECONDS - began))
  [ "$waited" -lt 300 ] || fail "$why, still after ${waited}s"
  [ -n "${told:-}" ] || { echo "waiting for $FEED to name build $BUILD (GitHub updates latest a little late)..."; told=1; }
  sleep 15
done
DMG_URL="$(field dmg "$PUBLIC")"
curl -fsSL -r 0-0 -o /dev/null "$DMG_URL" || fail "$DMG_URL does not answer"
curl -fsSL -r 0-0 -o /dev/null "$(field url "$PUBLIC")" || fail "the ZIP the appcast names does not answer"
echo "checked: $FEED names build $BUILD, and its DMG and ZIP download"
echo "next: the site — its changelog entry for $VERSION and a rebuild"
