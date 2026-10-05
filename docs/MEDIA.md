# Media and calls

How sound, films and calls stay reachable after their tab is left: the mini
player in the sidebar, the floating window, and Google Meet's own window.

## Mini player and floating window

- The mini player sits at the bottom of the tab column and offers only the
  commands its source has. With VoiceOver or Full Keyboard Access on, it stays
  expanded, since neither hovers.
- Dismissing it hides the controls, not the sound; a new audible session shows
  it again. Several sources get an explicit chooser, and a command always
  addresses the source on show. Returning to a source finds its tab among
  current and parked tabs, switches to its Space and selects it.
- Picture in Picture moves the page itself into the floating window; no page or
  stream is duplicated. "Return to mini player" hands it back to the sidebar.
- Changing Space pauses, mutes and reloads nothing, and never resumes a pause.
  A tab with sound, a camera or a microphone stays awake; a silent one sleeps.
- In the vertical layout a Space's door wears one mark: microphone, else
  camera, else playing video, else sound. Muted or paused wears nothing. The
  rail reads open tabs as it draws (`Presence.swift`), with no timer.
- Private tabs use the same controls and persist no media data.

## Google Meet

`Players.isCall` treats a `meet.google.com` meeting path as a call, which
floats in its own window (`Meeting.swift`, `Page/Scripts/meeting.js`):

- **Content.** The page draws the window in a shadow root, with the streams
  its tiles already play: people along the top, the shared screen whole below,
  else people fill the window. A picture is mirrored only where the page
  mirrors it.
- **Commands.** Microphone, camera, presenting, raise hand and hang up press
  the page's own buttons and show the page's state; a missing button is not
  offered. Presenting works because WebKit treats `evaluateJavaScript` as a
  user action.
- **Hanging up.** Asked by Meet to leave or end the call for everyone, the
  window answers leave. Still in the meeting four seconds later, the tab comes
  forward.
- **Lifetime.** It opens once there is a meeting and lasts as long as the
  meeting, cameras off and across Spaces. There is no close button; going back
  to the tab, or ⇧⌘P, puts the page home with the call running.
- **Zoom.** The floating page is zoomed to `Meeting.zoom` (0.4), so Meet lays
  out an ordinary window and keeps receiving everyone. Landing restores it.

### Reading a Meet page

Every name lives in `hints` in `meeting.js`. They come from Meet's markup as
remembered, not from a qualified page; `call_float.py` uses them on a synthetic
call.

| Read | How |
|---|---|
| A meeting | A way to leave, or a track WebKit labels `remote audio` / `remote video` |
| People | Tiles marked `data-participant-id`; without any, every remote video |
| Name | `[data-self-name]`, else the tile's first text outside buttons, menus and icons |
| Photo | The tile's largest loaded image of at least 24 px, drawn once into a canvas |
| Muted microphone | An icon reading `mic_off`, or a label saying the microphone is off |
| Large picture | A tile named like a presentation (`pr[eé]sent`, `präsent`, `presentaci`, `apresenta`), a captured screen (`displaySurface`), else a picture twice any other |
| Commands | Accessible labels in a few languages, then `jsname="BOHaEe"` (microphone) and `jsname="CQylAd"` (leave); state from `data-is-muted` and `aria-pressed` |
| Host's question | A `dialog` / `alertdialog` button labelled like leave |

The window redraws every 250 ms and reads the page's state twice a second; the
mini player card asks once a second while shown. Who is speaking and Meet's own
dialogs are not read. A synthetic canvas does not prove Meet screen sharing:
test the real capture API, and judge sent picture and received audio apart.

## Capability boundary

| Source | Commands offered |
|---|---|
| One accessible main-document audio or video element | Pause/resume and volume; title from Media Session, else the tab |
| YouTube, Spotify | Also previous/next through the site's visible, enabled controls |
| Spotify without an HTML media element | Its enabled transport buttons; volume needs a visible range input |
| Several elements, cross-origin frame, closed shadow tree, Web Audio | Return to source, and WebKit's tab-wide pause only while it reports playing |
| No private audibility observation | One public playback-state request on leaving the page |

Every command checks its result before it reports success; resume and track
changes are given two seconds.
WebKit's public media methods are no track controller, and Media Session has no
API to invoke a page's handlers, so the YouTube and Spotify adapters are narrow
and may lose commands when a site changes. Authenticated Spotify and protected
media are not qualified; that needs a dedicated test account, never a personal
one.

## Ownership, bounds and cleanup

- `Tab.media` owns one `MediaState`, one handler and at most one pending
  command. `Playback`, per window, holds only tabs with a media state. Nothing
  is written to disk.
- The `_isPlayingAudio` observation activates the reader. Only an audible page
  receives `Tabs/Scripts/media.js`, which looks at 32 elements at most, keeps
  one, truncates the title to 256 characters and loads no artwork.
- Events coalesce into a snapshot after 150 ms. There is no `timeupdate`
  listener, animation loop or permanent polling.
- Generation tokens reject replies from obsolete documents. Closing, navigation,
  sleep, process replacement and dismissal remove listeners and the handler.
  Stopping a load keeps the session, since WebKit may still play.

Scenarios and resource measurements are in [TESTING](TESTING.md).
