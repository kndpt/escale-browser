# Direction

Escale is a native browser for developers on Mac, built in Swift on WebKit.
Its priorities are a small resource footprint and a daily workflow organised
around projects.

[DESIGN](DESIGN.md) defines the visual direction: window composition,
materials and equal attention to light and dark.

## Who it serves

Developers who keep documentation, pull requests and several environments open
alongside an IDE, containers or simulators. Escale makes those pages easy to
find while leaving resources available for their tools.

## The workflow

Return to a project, find its pages and recognise the environment before acting.

- **Shipped:** Spaces with their own bookmarks, history and sign-ins; pinned
  tabs and session restore; bookmarks holding named environments; Bearings
  (`⌘T`, `⌘K`, `⌘L`), which also finds visited GitHub pull requests and
  issues (`⇧⌘K`); the localhost list; link routing to a Space; the API Calls
  panel; import from other browsers and transfer of every Space to another Mac.
  Environment labels are reminders, not protection against production mistakes.
- **Later, if useful:** local JWT decoding and other tools suggested by
  observed workflows. These are candidates, not commitments.

## Product rules

- Mac only. Swift and SwiftUI for the app, WebKit for pages. No new dependencies.
- Keep frequent actions quick and reachable from the keyboard.
- Avoid background work for features the user is not using.
- Keep data local. No telemetry or accounts required.
- WebKit's inspector and extension support define compatibility; document
  tested limits. Escale does not replace a full set of developer tools: the
  API Calls panel reads what WebKit's own inspector records, for the common
  question of what a page sent and received, and Web Inspector stays one
  shortcut away.

## Prove the promise

Native code and WebKit are design choices, not proof of superior performance.
Measure launch time, total memory including WebKit processes, idle CPU and
energy use on identical workloads on the same Mac, as [PERFORMANCE](PERFORMANCE.md)
describes. Energy and absolute budgets are not measured yet. Publish
reproducible results before claiming Escale is faster or uses less memory than
another browser.

The name stays **Escale**.
