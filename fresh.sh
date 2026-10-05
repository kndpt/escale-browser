#!/bin/bash
# A first launch, without touching the browser you actually use.
#
#   ./fresh.sh          wipe the test world and open Escale as a newcomer
#   ./fresh.sh again    open the test world as it was left, no wipe
#   ./fresh.sh stop     stop the test world's app, if it is running
#   ./fresh.sh wipe     stop it and remove everything the world owns
#
#   ESCALE_PROBE=NAME ./fresh.sh …   the same for a named world, "Escale (NAME)"
#   ESCALE_MEASURE=1 ./fresh.sh …    opened to be measured (Store.measuring)
#   ESCALE_FEED=URL ./fresh.sh …     reading that update feed instead (Updater.feed)
#   ESCALE_BACKGROUND=1 ./fresh.sh …  opened behind the app in front, keyboard left with it
#   ESCALE_ASIDE_SOURCE=/absolute/path ./fresh.sh again
#   ESCALE_ARC_SOURCE=/absolute/path ./fresh.sh again
#   ESCALE_CHROME_SOURCE=/absolute/path ./fresh.sh again
#       explicitly read this source of an automatic browser (any
#       ESCALE_BRAND_SOURCE) in an interactive demo only; destination
#       storage stays isolated. Never set for automated tests.
#
# A test world runs as its own copy of build/Escale.app, in build/probe/NAME/,
# under a bundle id of its own: com.kndpt.escale.probe.NAME. The id keeps it
# apart where a flag can't — the app's standard defaults, which WebKit and
# AppKit write to by themselves, and WebKit's container of cookies, caches and
# extension storage — and Escale refuses a test run under any other id, the
# real one above all (see Store.admit). Beside those the world has its folder
# under Application Support, its settings suite com.kndpt.escale.test[.NAME]
# and its keychain items, labelled "Escale (NAME)". Wiping all of it is a
# fresh install; the real session, pins, history and logins are never in
# reach of this script.
#
# The copy is made afresh from build/Escale.app at each launch: ./build.sh
# first. The verification harness can supply ESCALE_TEST_APP, an attested
# snapshot kept identical across restart scenarios, instead of the mutable build.
# One process per world: opening a
# world that is already running stops here rather than start a second or pull
# its folder out from under it; `wipe` stops it first. `stop` is a SIGTERM, which skips the
# app's goodbye; quit from the app to have the session saved first.
set -euo pipefail

cd "$(dirname "$0")"

# The world, named the way Store.world names it.
WORLD=$(printf '%s' "${ESCALE_PROBE:-test}" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9-')
case "$WORLD" in ""|1) WORLD=test ;; esac
if [ "$WORLD" = test ]; then SUITE=com.kndpt.escale.test; else SUITE="com.kndpt.escale.test.$WORLD"; fi
ID="com.kndpt.escale.probe.$WORLD"                   # Store.probeBundle
COPY="$PWD/build/probe/$WORLD/Escale.app"
BINARY="$COPY/Contents/MacOS/Escale"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# The world's processes, known by the path of the copy's executable: nothing
# else runs from there, so nothing else is ever stopped.
running() {
  ps -axo pid=,comm= | while read -r pid comm; do
    [ "$comm" = "$BINARY" ] && echo "$pid"
  done || true
}

stop() {
  local pids
  pids=$(running)
  [ -n "$pids" ] || return 0
  kill $pids
  for _ in {1..50}; do
    [ -n "$(running)" ] || { echo "world \"$WORLD\" stopped"; return 0; }
    sleep 0.1
  done
  echo "world \"$WORLD\" is still running (pid $pids)" >&2
  exit 1
}

wipe() {
  # The list still names the secondary keychain labels before its file goes.
  local spaces_file="$HOME/Library/Application Support/Escale ($WORLD)/spaces.json"
  if [ -f "$spaces_file" ]; then
    while IFS= read -r space_id; do
      while security delete-internet-password -l "Escale ($WORLD) · $space_id" >/dev/null 2>&1; do :; done
      github_secrets "$space_id"
    done < <(python3 -c 'import json,sys,uuid
try:
    rows=json.load(open(sys.argv[1]))
    for row in rows:
        value=str(uuid.UUID(row["id"])).upper()
        if value!="00000000-0000-0000-0000-000000000001": print(value)
except (OSError,ValueError,KeyError,TypeError): pass' "$spaces_file")
  fi
  rm -rf "$HOME/Library/Application Support/Escale ($WORLD)"
  # defaults empties a domain and leaves its file behind; the file goes after.
  for domain in "$SUITE" "$ID"; do
    defaults delete "$domain" 2>/dev/null || true
    rm -f "$HOME/Library/Preferences/$domain.plist"
  done
  for place in WebKit HTTPStorages Caches; do rm -rf "$HOME/Library/$place/$ID"; done
  rm -f "$HOME/Library/HTTPStorages/$ID.binarycookies"
  rm -rf "$HOME/Library/Saved Application State/$ID.savedState"
  # Vault's items carry the world's label; one goes per call.
  while security delete-internet-password -l "Escale ($WORLD)" >/dev/null 2>&1; do :; done
  github_secrets 00000000-0000-0000-0000-000000000001
  echo "world \"$WORLD\" wiped"
}

# A Space's GitHub authorization is a generic password, not an Internet one,
# under a service named after the world and the Space (GitHubSecrets.swift).
github_secrets() {
  while security delete-generic-password -s "com.kndpt.escale.github.test-$WORLD.$1.github.com" >/dev/null 2>&1; do :; done
}

# build/Escale.app under the world's id, signed again ad hoc for it, as
# ./build.sh signs without a Developer ID. A passkeys profile names the real
# id, so it stays out, and its restricted entitlement with it.
copy() {
  local source="${ESCALE_TEST_APP:-$PWD/build/Escale.app}"
  # An explicitly supplied snapshot must exist; never silently rebuild or
  # substitute a different app in the middle of an attested campaign.
  if [ ! -d "$source" ]; then
    [ -z "${ESCALE_TEST_APP:-}" ] || { echo "test app snapshot missing: $source" >&2; exit 1; }
    ./build.sh release
  fi
  rm -rf "$COPY"
  mkdir -p "$(dirname "$COPY")"
  ditto "$source" "$COPY"
  rm -f "$COPY/Contents/embedded.provisionprofile"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" "$COPY/Contents/Info.plist"
  codesign --force --deep --sign - "$COPY" 2>/dev/null
}

launch() {
  if [ -n "$(running)" ]; then
    echo "world \"$WORLD\" is already running (pid $(running)) — ./fresh.sh stop first" >&2
    exit 1
  fi
  copy
  # open hands the app a fresh environment: what makes it a test run, or a
  # measured one, has to be passed on by name.
  local env=(--env "ESCALE_PROBE=$WORLD")
  [ -n "${ESCALE_MEASURE:-}" ] && env+=(--env "ESCALE_MEASURE=$ESCALE_MEASURE")
  [ -n "${ESCALE_FEED:-}" ] && env+=(--env "ESCALE_FEED=$ESCALE_FEED")
  # The development GitHub App a test world connects with (GitHubSpaces).
  [ -n "${ESCALE_GITHUB_CLIENT_ID:-}" ] && env+=(--env "ESCALE_GITHUB_CLIENT_ID=$ESCALE_GITHUB_CLIENT_ID")
  [ -n "${ESCALE_GITHUB_APP_SLUG:-}" ] && env+=(--env "ESCALE_GITHUB_APP_SLUG=$ESCALE_GITHUB_APP_SLUG")
  # Every automatic brand reads ESCALE_BRAND_SOURCE (MigrationFlow), so a
  # brand made automatic needs no line here.
  local source
  for source in $(compgen -v | grep -E '^ESCALE_[A-Z0-9]+_SOURCE$'); do
    [ -n "${!source}" ] && env+=(--env "$source=${!source}")
  done
  # A socket left by a run that was stopped would answer for this one.
  local socket="$HOME/Library/Application Support/Escale ($WORLD)/bench.sock"
  rm -f "$socket"
  # ESCALE_BACKGROUND=1: opened behind whatever is in front, without taking
  # the keyboard from it — for scenarios run beside others or beside you.
  local behind=()
  [ -n "${ESCALE_BACKGROUND:-}" ] && behind=(-g)
  open -n ${behind[@]+"${behind[@]}"} "${env[@]}" "$COPY"
  # Up, and still up a second later: a run Escale refuses exits at once.
  # Refusal comes before the bench listens, so its socket says it sooner.
  for _ in {1..100}; do
    [ -n "$(running)" ] && break
    sleep 0.1
  done
  for _ in {1..10}; do
    [ -S "$socket" ] && break
    sleep 0.1
  done
  if [ -z "$(running)" ]; then
    echo "world \"$WORLD\" did not start — Console has why, under \"Escale:\"" >&2
    exit 1
  fi
  echo "world \"$WORLD\" running as $ID (pid $(running))"
}

case "${1:-}" in
  "")
    if [ -n "$(running)" ]; then
      echo "world \"$WORLD\" is running (pid $(running)) — ./fresh.sh stop first" >&2
      exit 1
    fi
    wipe
    launch ;;
  again) launch ;;
  stop) stop ;;
  wipe)
    stop
    wipe
    [ -d "$COPY" ] && "$LSREGISTER" -u "$COPY" 2>/dev/null || true
    rm -rf "$(dirname "$COPY")" ;;
  *) echo "usage: [ESCALE_PROBE=NAME] [ESCALE_MEASURE=1] ./fresh.sh [again|stop|wipe]" >&2; exit 2 ;;
esac
