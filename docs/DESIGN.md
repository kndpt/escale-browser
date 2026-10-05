# Design

This document sets Escale's visual direction. Read it before you design,
change or review an interface; [DIRECTION](DIRECTION.md) owns product scope.

The values live in code: `Palette`, `Metrics` and `Motion` in `Design.swift`,
`ChromeMetrics` in `ChromeScale.swift`, the materials in `Glass.swift` and the
floating panel in `Plate.swift` (all in `Sources/Escale/Design/`). This page
gives the rules and names the constants. When the two disagree, the code wins.

## Principles

> A calm, precise interface whose character comes from material, proportion
> and light. The content stays in front.

- Minimal is not empty or low-contrast: keep precise alignment, regular
  spacing, little decoration and a readable hierarchy.
- Light and dark are designed together. Light has its own milky material; it
  is not dark inverted.
- New surfaces use `.glass(role, in:)` and `Palette` roles, never an opaque
  fill or an ad hoc colour. No effect justifies a dependency.

References, for intent only (not their brands, colours or features):
[Raycast 2026 redesign](https://www.raycast.com/blog/the-new-raycast) for the
material (one family of surfaces, fine edges, depth by role);
[Unpeel](https://unpeel.com/mac) for the window's balance (rounded content set
in, the sidebar filling the rest); [Zen](https://zen-browser.app/) for a
simple browser organisation.

## Window composition

1. **One envelope.** The window's ground carries the sidebar, tab row and
   address bar as one material, with no background or separator of their own.
2. **A distinct page.** The web view has an opaque, rounded frame (`Page` in
   `Stage.swift`), set in by `Metrics.pageInset` with `Metrics.pageRadius`, a
   fine edge outside and a light shadow. No inset beside the column or under a
   bar; no frame while a page is immersed in a video.
3. **An integrated sidebar.** The column fills the rest of the window; it is
   not a second card.

The sidebar is a space rail (`Metrics.spaceRail`) and a column
(`Metrics.side`, between `sideMin` and `sideMax`) sharing one edge, with no
gap or rule. The column folds with its door or ⌘S, never on hover. Folded, the
rail stays and the door moves to the head of the line above the page; the
traffic lights stay put. Folding uses `Motion.fade`, and the column's content
leaves before its footprint does, so it never lingers over the page.

## Material and transparency

Glass is for Escale's chrome only. Each surface has a role (`Glass.Role`):

| Role | Use | Material |
|---|---|---|
| `.envelope` | the window's ground | system blur behind the window |
| `.panel` | plates, menus, suggestions, the field | SwiftUI material in the window |
| `.chip` | one line over a page: a notice, find | denser SwiftUI material |

**The page is never touched.** Escale does not blur, tint or restyle a site;
its frame is opaque. Controls laid over a page are Escale's UI and use glass.

- Fine edges, diffuse shadows, restrained highlights. No heavy frames, needless
  nested cards or animated shine. A card in a panel is `Palette.raised`.
- Popovers keep macOS's material; `.popoverGround()` fills them at Solid.
- Settings take the page's place in its frame, with no card (`SettingsGround`).

**Transparency** (`Depth`): Solid, Subtle (default, also for unknown values)
or Clear. It changes each role's tint opacity (`Depth.tint`), never the ink.
Solid draws no blur; the Mac's Reduce Transparency forces it. **Increase
Contrast**, Escale's or the Mac's, strengthens edges and secondary text.

## Colour

Every colour is a light/dark pair in `Palette`; no other code checks the
appearance. Use roles, not greys: `ground`, `envelope`, `panel`, `ink`,
`inverse`, `muted`, `faint`, `edge`, `hairline`, `selection`, `hover`, `wash`,
`raised`, `scrim`, `shadow`, `danger`.

- Edges, separators, hover and wash are ink at low alpha, so they read the
  same on glass and on the page.
- `muted` is secondary text and symbols. `faint` is quieter but legible on
  glass: disabled ink, a Switch's off track, unselected sizes, step dots, a
  field's clear button, a loading status.
- `Chosen` (`Glass.swift`) is the one selection surface: tab, pin, open
  bookmark, space, Settings page, segment, mode.
- There is no accent. **Tone** (Settings › Appearance › Colours) is Neutral
  (default) or Escale's warm colours, in light and dark alike. Glass takes a
  richer stain (`envelopeTint`, `panelTint`) so the warmth survives a thin
  tint. Swatch, space and GitHub colours never change with tone.
- **State colours** always come with a non-colour cue (a word, code, symbol or
  accessible name): `danger`, `safe`/`unsafe`, `githubOpen`/`githubFinished`,
  and the softer code tints `codeKey`, `codeString`, `codeNumber`.
- Check contrast in both themes on a whole page, not one isolated row.

**User colours** use `Swatch` and `SwatchPicker` (`Design/Swatch.swift`).
Data stores the stable names (`rose`, `peach`, `amber`, `mint`, `blue`,
`violet`), never an index or RGB; no value means Neutral. `Palette.swatch` is
the dot, `Palette.swatchInk` the text variant. The picker edits a draft its
owner saves. A user colour carries no meaning such as safety.

## Sizes and motion

**Interface size** (`InterfaceSize`): Compact, Standard (default) or Large.
`Metrics` lengths are reference points (the code calls them compact points),
not the size drawn at Compact. `ChromeMetrics.length` scales them by
`InterfaceSize.factor` and rounds to half points: `Metrics.spaceRail` is 48
reference points, 54 pt at Standard. Say which unit you mean, or name the
constant.

- New code resolves every `Metrics` length through `ChromeMetrics`
  (`@Environment(\.chromeMetrics)`); some older views still use raw values.
- Resize with lengths, never `scaleEffect`. The web view keeps its own zoom.
- A surface in the page frame stays at or below the chrome around it:
  Settings row text (`Metrics.settingsRowText`) not above the column's 12.5 pt
  titles, rows not taller than tabs. A shared component takes a density
  (`CardDensity.panel`, `.settings`) instead of changing for everyone.
- Radii: `pageRadius`, `plateRadius` (panels), `fieldRadius` (field and
  suggestions), `cardRadius`. Rail tools use `spaceRailGlyph`, space icons the
  optically matched `spaceIconGlyph`, both Medium, in doors of one size.

**Motion** lives in `Motion`. Reuse its curves (`glide`, `settle`, `arrival`
for steps and disclosures, `quick` for hover) before adding one.

- Decorative animation never runs at rest. Reduce Motion removes movement,
  not information.
- **Faster shortcut animations** (Appearance, on by default) runs tab
  selection, opening, closing, new-tab search and the ⇧⌘S layout switch at
  `Motion.shortcutMultiplier` when triggered from the keyboard
  (`ShortcutMotion.swift`). Clicks, hover, drag and the ⌘S fold keep their
  pace. Reduce Motion wins.

## Controls drawn by Escale

Escale's surfaces show no macOS-styled controls (bordered button, `Picker`,
checkbox, `DisclosureGroup`, `ProgressView`), and never mix native and drawn
controls. The system keeps the file picker, context menus, hover help, the
popover itself and the traffic lights; what a popover contains is drawn.

Reuse or extend a component before creating one:

| Need | Component |
|---|---|
| Primary, alternative, back or exit action | `MigrationButton` `.primary` / `.secondary` / `.quiet` (`MigrationPanel.swift`) |
| Small action in a settings row | `Pill` (`Settings.swift`) |
| Copy a value | `CopyButton` (`Design/CopyButton.swift`) |
| 2–4 short options in a dense row | `Segmented` (`Settings.swift`) |
| The modes of one surface | `Modes` (`Design/Modes.swift`) |
| 2–4 visual options with room | `ArrivalChoice` (`Welcome.swift`) |
| Yes or no | `Switch` (`Settings.swift`) |
| Long or dynamic list | `MigrationField` (`MigrationChoices.swift`) |
| Source and destination of an import | `MigrationPassage` (`MigrationPassage.swift`) |
| Explanation of a control | `InfoTip` (`Design/InfoTip.swift`) |
| Progress | `MigrationBar`, `MigrationSpinner` |
| Search field in a panel | `Hunt` (`Plate.swift`) |
| Colour | `SwatchPicker` (`Design/Swatch.swift`) |

- **Hierarchy.** One ink primary per screen or step, first on the left under
  the content; the secondary beside it; back and exit quiet.
- **Target and states.** The whole row, card or label acts. Each control has
  hover, press and disabled (opacity 0.4); the chosen item uses `Chosen`.
- **Hover-revealed actions** keep their reserved space, so nothing moves when
  they appear, and stay reachable by keyboard and accessibility.
- **Info icons** always use `InfoTip`, whose explanation opens by the icon.
- **Search fields** never change height; placeholder text truncates.
- **Recommended option.** Preselected only on a first arrival, with a discreet
  badge and a short reason; defaults and existing profiles don't change.
- **Window overlays** start from the window's top (`ignoresSafeArea`) and
  place their content with `ChromeMetrics`.

## Multi-step flows

- **Order.** First choices whose effect shows at once and undoes for free;
  then what is optional or long, with a visible exit and where to redo it.
  Never hide a setting at the bottom of an unrelated step, and don't show a
  step that cannot be filled yet.
- **One step, one subject.** A short new title, a subtitle saying what changes,
  a discreet step indicator.
- **Same composition.** Every step and state keeps the first screen's column,
  centring and controls. The column is centred, vertically too while it fits.

## Surface notes

- **Space rail.** `+` follows the last space in a door of the same size; the
  foot holds the space tools, then Settings. A door wears one `DoorMark` when
  its space uses the microphone, camera, video or sound, in that priority.
- **Sleep marker.** A `zzz` in `Palette.sleeping` takes Close's place at rest
  and steps left on hover; its space stays reserved. It has no action.
- **Reading line.** Neutral ink (`readingBody`, `readingTip`),
  `ReadingLine.height` thick, just above the page, between its corners.
- **Split groups.** Each page keeps its own rounded frame, `pageInset` apart.
  The focused page has a thin ink ring (`Metrics.panelRing`) outside it. No
  divider at rest, a grip on hover. A page's hover actions affect that page
  only. The drop slot glides on `Motion.settle`, with no help text.
- **Bearings modes.** The `Modes` capsule ends the field
  (`Address/Omnibox.swift`) at the width of its longest name. The field's top
  is fixed at `Metrics.searchTop` of the page's height; results grow down.
- **Developer mode.** A glass column (`.glass(.panel, lifted: false,
  edgeOutside: true)`) beside the page, `pageInset` apart, with the page's
  radius; the page shrinks, nothing covers it. An unavailable body says why.
- **Mini player.** At the column's foot, on `chip` glass, with `Motion.arrival`.
- **Update door.** The last rail door, its symbol in `ink` among `muted` doors.
  It opens a `Plate` (`Metrics.gateWidth`); the plane lands once
  (`Motion.gateFlight`), never with Reduce Motion.
- **Download flight.** A plane flies from the page to the download door for
  `Motion.downloadFlightDuration`, one at a time; none with Reduce Motion.

## Visual review

Check the touched surfaces in their relevant states and record the result and
its limits in the PR. Attach captures only when they help judge the change;
then give macOS version, window size, theme, desktop and Transparency.

- Light and dark, with a white and a dark page, on light, dark and contrasted
  desktops.
- Envelope, sidebar and page balance and corners, at the affected sizes and
  layouts, with long titles and full lists.
- Rest, hover, selection, keyboard focus and inactive window.
- No macOS-styled control outside the exceptions; every flow state matches
  its first screen. Compare text size with a nearby native app.
- For material changes: default and extremes, Reduce Transparency, Increase
  Contrast. Animated changes with Reduce Motion.

Say what was not tested. Functional checks follow [TESTING](TESTING.md); app
runs use the [bench](../.agents/skills/escale-bench/SKILL.md) in an isolated
world. Blur, composition and animation costs follow
[PERFORMANCE](PERFORMANCE.md). A documentation-only change needs link checks,
not an app run.
