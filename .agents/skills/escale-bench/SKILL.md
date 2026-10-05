---
name: escale-bench
description: Drive Escale with ./bench to verify app, WebKit or UI behaviour, or extend the bench when an action is missing. Not for pure rule tests.
metadata:
  short-description: Drive Escale with ./bench
---

# Escale bench

`./bench` drives a running Escale from the repository root; `./bench help` is
the command reference. Use it when the assertion needs the app, WebKit or the
UI, never on the browser a person has open.
[TESTING](../../../docs/TESTING.md#run-the-checks) owns which checks to run and
when to add a scenario or command. Report the scenario, expected and observed
result, and limits: a command that succeeds is not a passed test.

## Which process

Every command goes to one world. Pass the same flag on every call.

| Flag | Whose browser | Socket folder |
|---|---|---|
| `--world NAME` | World `NAME` (lowercase letters, digits, hyphens) | `~/Library/Application Support/Escale (NAME)/` |
| `--test` | World `test` | `~/Library/Application Support/Escale (test)/` |
| none | The installed browser the person uses | `~/Library/Application Support/Escale/` |

Verify in a unique named world launched with `ESCALE_PROBE=NAME ./fresh.sh`: a
copy of the app under its own bundle id, `com.kndpt.escale.probe.NAME`. Read the
[launch procedure](../../../docs/PERFORMANCE.md#baseline-protocol) first. A
binary under `.build/` is world `test`, but shares platform defaults with other
`.build/` runs, so it is no evidence of isolation. Never test on the installed
browser.

Commands the help marks as test run, test world or test-only refuse the
installed browser. There, and only when asked, use `tabs`, `probe` and page
commands on bench tabs.

## Get a test world listening

One process per world. Reuse only a world this task owns. `fresh.sh stop` and
`wipe` signal only the process running from that world's copy
(`build/probe/NAME/`). Never use `killall`, quit by app name or a broad
`osascript` quit. Leave `/Applications/Escale.app` alone.

1. `./build.sh debug` if the source changed: the world copies
   `build/Escale.app`. Then `ESCALE_PROBE=NAME ./fresh.sh wipe`.
2. `defaults write com.kndpt.escale.test.NAME bench -bool YES`, then
   `ESCALE_PROBE=NAME ./fresh.sh again`. `ESCALE_MEASURE=1` opens it for
   measurement. `ESCALE_BACKGROUND=1` opens it behind the app in front: keys,
   taps and the field still reach it, but `live`, `pointer` and a page's own
   key handling need it in front.
3. Check `./bench --world NAME tabs` with a deadline and a few retries. If the
   switch was off, `fresh.sh stop` and open it again; never a second process.
4. At the end, `ESCALE_PROBE=NAME ./fresh.sh wipe` stops it and removes its
   folder, settings, defaults, WebKit storage, keychain items and copy.

`fresh.sh` with no argument wipes first, the bench switch included. Do not wipe
to reconnect or to restart a scenario that checks restoration: `stop` is a
SIGTERM that skips the session save, so quit from the app
(`./bench --world NAME press 12 q cmd`) and reopen with `again`.

If the installed browser is not listening, ask the person to turn on
**Settings › Developer › Let a script drive Escale**. Never write defaults for
the installed app.

## Tabs

`./bench tabs` prints one row per tab: `⚗` a bench tab, `●` the tab on screen,
a trailing `…` still loading, `z` asleep.

- `open` prints the new bench tab's id; ids match by prefix. Close the ids you
  opened, also after a failure (`close all` closes other scripts' tabs too).
- Bench tabs are never selected, saved in the session or written to history,
  and never sleep automatically. An unselected bench page is laid out off
  screen at 1280×800; that is what `shot` captures.
- For history, session or sleep assertions, use ordinary tabs:
  `bookmark URL new`, UI actions or a synthetic session. The session keeps only
  web addresses, so serve test pages on loopback, not as `data:` URLs.
- Send one call at a time to a world, inside a subprocess deadline: the client
  socket has no timeout if the app stalls.

## Pages

```bash
# In a prepared isolated world; a driving example, not a test runner.
id=$(./bench --world my-check open 'data:text/html,<h1>Escale</h1>')
./bench --world my-check wait "$id" 20
./bench --world my-check text "$id"
./bench --world my-check shot "$id" /tmp/escale-bench.png
./bench --world my-check close "$id"
```

- `open` and `go` take an address, not a search. A host without a scheme gets
  `https://`, except `localhost`, `*.localhost` and LAN addresses (`http://`).
- `wait` prints JSON. A load succeeded only with `loading: false`, no
  `timeout` and no `failure`; then assert the URL or content.
- `text` is `document.body.innerText`, cut at 120,000 characters. If empty,
  `eval` `document.readyState` and `location.href` before calling it blank.
- `click`, `type` and `submit` act through JavaScript and prove no real input.
  For keyboard, focus or pointer behaviour use `key`, `press`, `tap` or `hit`.
- `shot` captures the web view only. `probe` reports the chrome as JSON:
  panels, address field, windows, frames, appearance.

## Real input

- An answer to `press`, `hit … click`, `pointer` or `resize` means the app has
  handled the input, not that the page or an animation has. Poll for the
  resulting state with a deadline (`wait_for` in a scenario), never a pause.
- Hover comes from the window server, and moving the cursor sends no event.
  Move the pointer onto a target (`pointer move X Y`) before hovering or
  clicking it: a control revealed on hover receives no click while hidden.
- `hit … click live` and `drag … live` route every event, the press included,
  through `NSApp.sendEvent`, as SwiftUI gestures need. Without `live`, the
  event goes straight to the view and starts no SwiftUI gesture.
- When a SwiftUI button still does not respond, press it through accessibility
  in the test copy and read the result with `probe`.
- A test world with the bench on ignores keys typed outside its process
  (`probe.foreignKeys` counts them). Drive it with `press` and `key`.
- `picture` draws the page over the chrome, which hides a panel above a loaded
  page. The socket request takes `"page": false` to leave the page out.
- For window captures, use `screencapture -l` on the window alone and check
  each image: a region capture includes other apps passing in front.

## Extensions

macOS 15.4 or later, in a test world. IDs here are extension ids from
`./bench extensions`, not tab ids.

Regressions install a local fixture with `ext-folder PATH --yes`; `ext-add`
takes a Chrome Web Store link or id for an explicit compatibility check, whose
macOS and extension versions you record. Both answer `{"started": true}`
before the install ends: poll `extensions` until `busy` is `""`, then assert
`loaded`, `errors` and `reported`.

## Failures

The script exits non-zero and prints `error: …`. Trust that string.

- `isn't listening`: the process is down or the switch is off.
- `no tab`: a stale id. Run `tabs`.
- `not a bench tab`: `close` was aimed at a tab the bench did not open.
- `only works on a --test run` or `only in a test run`: a test-only command
  was aimed at the installed browser.
- `unknown command`: run `./bench help`; the script is ahead of this file.
- A deadline expires in a world that reads a file under `~/Documents`: macOS
  may be showing a privacy prompt to the new app identity. `sample PID` before
  calling it a regression, and rerun from a checkout outside protected
  folders.
