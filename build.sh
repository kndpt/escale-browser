#!/bin/bash
# Assembles a double-clickable .app around the SwiftPM binary — and, when
# asked, the disk image people install it from and the ZIP the updater
# fetches.
#
#   ./build.sh                 debug-free release build, signed with the
#                                Developer ID ESCALE_SIGN_IDENTITY names, ad
#                                hoc without one: runs here
#   ./build.sh debug           the same app from a debug build: quicker to
#                                build while iterating, symbols kept, no dSYM
#   ./build.sh release dmg     + build/Escale.dmg, build/Escale.zip and
#                                build/appcast.json
#   ./build.sh release ship    + both notarised, the DMG stapled
#
# Same shape as the one next door: SwiftPM builds the executable, and a macOS
# app bundle is just a folder with a plist and the binary in the right place.
#
# The three files keep the same names from release to release, so a link to
# the latest release's DMG never changes and the updater reads one address
# forever. ./publish.sh attaches them to a GitHub release of Escale's public
# repository (ESCALE_REPOSITORY, default below).
#
# "dmg" lays the disk image's window out with dmgbuild, installed into .build
# on first use (Python 3 and a network, once).
#
# What "ship" needs, once:
#   - a Developer ID Application certificate in the login keychain
#     (ESCALE_SIGN_IDENTITY names it; nothing is picked from the keychain)
#   - a notarytool profile: xcrun notarytool store-credentials "escale"
#     (ESCALE_NOTARY_PROFILE names it; default "escale")
#   - ESCALE_DOWNLOAD_URL, the https folder the ZIP and the DMG are served
#     from, for the appcast. Default this version's release on
#     ESCALE_REPOSITORY. Updater.feed reaches the appcast itself through
#     escalebrowser.com, which redirects to the latest release there.
#
# Those variables can live in Config/Signing.local.env, which this script
# reads when it exists and git ignores (Config/README.md). Without it, and
# without ESCALE_SIGN_IDENTITY, the app is signed ad hoc: it runs on the Mac
# that built it, and nothing about anyone's Apple account is needed.
#
# GITHUB_CLIENT_ID, next to this script, is the public client ID of the GitHub
# App Bearings connects with (github.com/apps/escale-browser), kept in
# Info.plist (GitHubSpaces.swift). It is not a secret: every app shows it.
# ESCALE_GITHUB_CLIENT_ID overrides it, the development app's for instance;
# set empty, the build has no GitHub App and Bearings' GitHub mode stays local.
# GITHUB_APP_SLUG is that app's name in its address, for the page where people
# share private repositories with it; ESCALE_GITHUB_APP_SLUG overrides it.
#
# NOTES.md, next to this script, is what's new: newest release first, one
# paragraph each. The first paragraph goes into the appcast, and from there
# under the version line in Settings.
set -euo pipefail

cd "$(dirname "$0")"
# Local signing and release settings, kept out of git.
if [ -f Config/Signing.local.env ]; then
  # shellcheck disable=SC1091
  . Config/Signing.local.env
fi
ESCALE_REPOSITORY="${ESCALE_REPOSITORY:-kndpt/escale-browser}"
CONFIG="${1:-release}"
STEP="${2:-app}"
APP="build/Escale.app"
NAME="Escale"
VERSION="$(tr -d '[:space:]' < VERSION)"
# A build number that only ever goes up, so the updater can tell newer from
# older without parsing version strings.
BUILD="$(date +%Y%m%d%H%M)"
# The oldest macOS this runs on — in the plist, and in the appcast so an
# older Mac is not handed a build it can't open.
MINIMUM="14.0"
# The commit the app was built from, "-dirty" when the files differed from
# it: publish.sh releases a build only from the commit it names.
SOURCE="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
[ -z "$(git status --porcelain 2>/dev/null)" ] || SOURCE="$SOURCE-dirty"

swift build -c "$CONFIG"
BINARY=".build/$CONFIG/Escale"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$NAME"
# The JavaScript the app injects (Scripts/ in a domain's folder), in the
# bundle SwiftPM gathers it into. Bundled.swift looks for it here first, so
# a copy of the app finds its scripts wherever it is put.
cp -R ".build/$CONFIG/Escale_Escale.bundle" "$APP/Contents/Resources/"

# Symbols stay out of the app. The linker leaves every function's name and a
# map back to the source in the binary — 15,000 entries, more than half of
# what the app weighed (6.5 MB of binary, 2.7 without them), and nothing the
# app reads while it runs. They are kept beside the build instead, as a dSYM
# that turns the addresses in a crash report back into names (Console, or
# atos -o build/Escale.app.dSYM/Contents/Resources/DWARF/Escale).
if [ "$CONFIG" = "release" ]; then
  rm -rf "$APP.dSYM"
  dsymutil "$BINARY" -o "$APP.dSYM" 2>/dev/null || echo "no dSYM this time" >&2
  strip -x "$APP/Contents/MacOS/$NAME"
fi

# The icon, drawn fresh each time — it is thirty lines of Swift, not an asset
# to keep in step with anything.
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
swift Icon/icon.swift "$ICONSET" > /dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# The licences travel with every copy: Escale's GPL, and in NOTICE the MIT
# notice of Search, which Escale started from and which that licence asks to
# keep in every copy.
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp NOTICE "$APP/Contents/Resources/NOTICE"
cp notify "$APP/Contents/Resources/notify"
# What this version brings, for the panel its first launch shows (Gate.swift):
# the first paragraph of NOTES.md, the words the appcast carries, read from
# the bundle so a copy that has just updated needs no network to say it.
if [ -f NOTES.md ]; then
  awk 'NF { printf "%s%s", (n++ ? " " : ""), $0; next } n { exit }' NOTES.md > "$APP/Contents/Resources/NOTES.txt"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>com.kndpt.escale</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>EscaleSourceCommit</key><string>$SOURCE</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>$MINIMUM</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>© Kelvin Dupont · GPL-3.0-or-later · Escale started from Search © Office Commun (MIT)</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- Owning http and https is what sends a link clicked in Mail here.
       Appearing in Desktop & Dock → Default web browser also needs the
       XHTML document type below. -->
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Web address</string>
      <key>CFBundleURLSchemes</key>
      <array><string>http</string><string>https</string></array>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Web page</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key>
      <array><string>public.html</string><string>com.apple.web-internet-location</string></array>
    </dict>
    <!-- macOS only lists an app under Desktop & Dock → Default web browser
         when it claims public.xhtml as well as public.html. http and https
         alone, which the app already had, are not enough. -->
    <dict>
      <key>CFBundleTypeName</key><string>XHTML page</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key>
      <array><string>public.xhtml</string></array>
    </dict>
  </array>
  <!-- A browser goes wherever it is pointed, including at http sites and at
       whatever is running on localhost. -->
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <!-- A browser is asked for these by the pages it shows, not by itself. macOS
       still wants a sentence to put in its own prompt, and touching the APIs
       without one is a crash rather than a refusal. -->
  <key>NSCameraUsageDescription</key>
  <string>Websites you visit can ask to use your camera. Escale asks you first, every time, for each site.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Websites you visit can ask to use your microphone. Escale asks you first, every time, for each site.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>Files you download are saved to your Downloads folder.</string>
</dict>
</plist>
PLIST
ESCALE_GITHUB_CLIENT_ID="${ESCALE_GITHUB_CLIENT_ID-$(cat GITHUB_CLIENT_ID 2>/dev/null || true)}"
if [ -n "$ESCALE_GITHUB_CLIENT_ID" ]; then
  [[ "$ESCALE_GITHUB_CLIENT_ID" =~ ^[A-Za-z0-9._]{1,128}$ ]] || { echo "ESCALE_GITHUB_CLIENT_ID is not a client ID" >&2; exit 1; }
  /usr/libexec/PlistBuddy -c "Add :EscaleGitHubClientID string $ESCALE_GITHUB_CLIENT_ID" "$APP/Contents/Info.plist"
fi
ESCALE_GITHUB_APP_SLUG="${ESCALE_GITHUB_APP_SLUG-$(cat GITHUB_APP_SLUG 2>/dev/null || true)}"
if [ -n "$ESCALE_GITHUB_APP_SLUG" ]; then
  [[ "$ESCALE_GITHUB_APP_SLUG" =~ ^[a-z0-9-]{1,100}$ ]] || { echo "ESCALE_GITHUB_APP_SLUG is not an app name" >&2; exit 1; }
  /usr/libexec/PlistBuddy -c "Add :EscaleGitHubAppSlug string $ESCALE_GITHUB_APP_SLUG" "$APP/Contents/Info.plist"
fi

# Signing. The Developer ID certificate ESCALE_SIGN_IDENTITY names, with the
# hardened runtime Gatekeeper insists on for anything notarised; otherwise
# ad-hoc, which is enough for the app to run on the machine that built it —
# and which the updater refuses to swap anything in under. The identity is
# never guessed from the keychain, so a contributor's own certificate is not
# used without being asked for.
IDENTITY="${ESCALE_SIGN_IDENTITY:-}"
# Passkeys need an entitlement Apple grants to browsers on request, and a
# Developer ID provisioning profile that carries it. With the profile next to
# this script, both go in; without it, the app is signed as before, because
# a restricted entitlement with no profile behind it is an app that won't open.
ENTITLEMENTS="Escale.entitlements"
if [ -f "Escale.provisionprofile" ]; then
  cp "Escale.provisionprofile" "$APP/Contents/embedded.provisionprofile"
  ENTITLEMENTS="Escale.passkeys.entitlements"
  echo "passkeys: profile embedded"
fi
if [ -n "$IDENTITY" ]; then
  codesign --force --deep --timestamp --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$IDENTITY" "$APP"
  echo "signed as: $IDENTITY"
else
  codesign --force --deep --sign - "$APP" 2>/dev/null || true
  [ "$STEP" != "app" ] && echo "no ESCALE_SIGN_IDENTITY — the DMG will only open on this Mac" >&2
fi

echo "built: $APP ($VERSION, build $BUILD)"
[ "$STEP" = "app" ] && exit 0

# The disk image: the app beside a shortcut to Applications, on a white
# window with an arrow between them — drawn by Installer/background.swift and
# laid out by Installer/dmg.py through dmgbuild, which writes the Finder's
# layout file itself, so no Finder is scripted and no window opens mid-build.
# dmgbuild is installed into .build the first time, and needs Python 3 and a
# network then; without it the image is the plain one it always was.
DMG="build/$NAME.dmg"
ART="build/installer"
rm -rf "$ART" "$DMG"
DMGBUILD=".build/dmgbuild/bin/dmgbuild"
if [ ! -x "$DMGBUILD" ]; then
  { python3 -m venv .build/dmgbuild && .build/dmgbuild/bin/pip install --quiet "dmgbuild==1.6.7"; } >/dev/null 2>&1 || true
fi
if [ -x "$DMGBUILD" ] \
  && swift Installer/background.swift "$ART" >/dev/null \
  && tiffutil -cathidpicheck "$ART/background.png" "$ART/background@2x.png" -out "$ART/background.tiff" >/dev/null 2>&1
then
  "$DMGBUILD" -s Installer/dmg.py \
    -D app="$APP" -D background="$ART/background.tiff" -D icon="$APP/Contents/Resources/AppIcon.icns" \
    "$NAME" "$DMG" >/dev/null
else
  echo "note: no dmgbuild — a plain disk image, without its window laid out" >&2
  STAGE="build/dmg"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
  rm -rf "$STAGE"
fi
rm -rf "$ART"
[ -n "$IDENTITY" ] && codesign --force --timestamp --sign "$IDENTITY" "$DMG"
echo "packed: $DMG"

# The ZIP is what the updater fetches, and its hash is what the updater
# checks before opening it.
ZIP="build/$NAME.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo "packed: $ZIP"

# What the updater reads. The first paragraph of NOTES.md, with the two
# characters JSON minds escaped, is the line under the version in Settings.
# The links name this version's release rather than the latest one, so an
# appcast read just before the next release lands still fetches the ZIP its
# hash was taken from.
BASE="${ESCALE_DOWNLOAD_URL:-https://github.com/$ESCALE_REPOSITORY/releases/download/v$VERSION}"
BASE="${BASE%/}"
NOTES=""
if [ -f NOTES.md ]; then
  NOTES="$(awk 'NF { printf "%s%s", (n++ ? " " : ""), $0; next } n { exit }' NOTES.md \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
fi
cat > build/appcast.json <<JSON
{
  "version": "$VERSION",
  "build": $BUILD,
  "url": "$BASE/$NAME.zip",
  "dmg": "$BASE/$NAME.dmg",
  "sha256": "$SHA",
  "notes": "$NOTES",
  "minimumSystemVersion": "$MINIMUM"
}
JSON
echo "wrote: build/appcast.json ($VERSION, build $BUILD)"
[ "$STEP" = "dmg" ] && exit 0

# Notarisation: Apple looks both over. The ticket is stapled to the image,
# so it opens on a Mac that has never seen this app and is offline; the ZIP
# is fetched by an app that already trusts it, and is left as hashed.
[ -z "$IDENTITY" ] && { echo "can't ship without a Developer ID certificate (ESCALE_SIGN_IDENTITY)" >&2; exit 1; }
for FILE in "$DMG" "$ZIP"; do
  xcrun notarytool submit "$FILE" --keychain-profile "${ESCALE_NOTARY_PROFILE:-escale}" --wait
done
xcrun stapler staple "$DMG"
echo "shipped: $DMG, $ZIP and build/appcast.json — ./publish.sh puts them on a GitHub release"
