# Resource contract

The promise is to leave resources available for the developer's other tools.
Swift, WebKit and zero dependencies help, but costs are measured, not assumed.
No absolute budget is validated yet; energy and physical scanout are not
measured. [TESTING.md](TESTING.md) separates functional assertions, including
bounded object counts, from the measurements described here.

## Rules for new work

- An unused or disabled feature adds no recurring timer, polling, network
  request, per-page observer or document script of its own. Static metadata is
  acceptable within a declared bound. Shared essential work needs a named reason.
- No page or process is created to compute chrome, count tabs, draw a menu,
  label an environment or check whether a sleeping tab exists.
- Every cache, queue and retained collection declares a count or size limit,
  an eviction policy and its behaviour under memory pressure. A disk cap is not
  a memory cap. Bookmarks are user data, not a cache: scale their loading and
  rendering without deleting them.
- Bound concurrency for downloads, decoding and snapshots. Limit response bytes
  while receiving, not after buffering everything. Cancel obsolete work and
  bound retries in count and time.
- Use events first. A necessary timer has an owner, a tolerance, an activation
  and an invalidation path. Every-frame work needs a visible interaction and a
  stop path.
- A feature adds no unbounded synchronous work to launch, typing, tab selection
  or navigation. Disk, keychain and DOM work is measured on the real user path,
  including slow and failing cases.
- Report the browser process, attributable WebKit and extension processes, and
  the aggregate separately. The browser's RSS is not total memory.
- A performance-sensitive change records raw before/after samples on the same
  workload. A functional bench run is not performance evidence.

## Baseline protocol

Measure an optimised, ad-hoc signed build of a recorded commit. Record the
macOS build, Mac, power source, window size, visibility, cache and history
size, Spaces, extensions and blocking settings. Run nothing else during timed
collection, and never seed a test world with personal browsing data.

Launch the app through `fresh.sh`, in a world unique to the task
(`AGENTS.md` has the isolation rules):

```sh
./build.sh                                    # the build under test
ESCALE_PROBE=perf-baseline ./fresh.sh wipe    # nothing left from an earlier run
defaults write com.kndpt.escale.test.perf-baseline bench -bool YES
ESCALE_PROBE=perf-baseline ESCALE_MEASURE=1 ./fresh.sh again
./bench --world perf-baseline probe
# … scenario or measurement …
ESCALE_PROBE=perf-baseline ./fresh.sh wipe    # stops it and removes everything it owns
```

`ESCALE_MEASURE=1` (`Store.measuring`) keeps what the shipped browser does
where test runs otherwise differ: WebKit slows hidden pages and App Nap stays
available. Drop it for functional runs. Three caveats:

- `fresh.sh stop` is a SIGTERM, which skips the session save. A restart
  scenario quits from the app (`./bench --world NAME press 12 q cmd`).
- A binary run from `.build/` is a test run, but its platform defaults and
  WebKit container are shared by every world run that way. Use it for the
  development loop, not for measurements or isolation evidence.
- `bench open` makes a bench tab that never sleeps and may sit in an
  off-screen window. Use ordinary tabs (`bookmark URL new`, UI actions or
  session fixtures) to measure tab memory or sleep. In `space`, `pages` counts
  views, not WebKit processes.

| Scenario | Fixed workload | What to establish |
|---|---|---|
| Launch | Empty; then 20 and 100 restored tabs, one selected | First visible frame, usable address field, peak and settled memory; only the selected page built. |
| Typing | Histories of 2k and 20k entries, common and rare prefixes | `field TEXT type` timings, main-thread trace, median and p95. |
| Navigation | Local static page, dynamic DOM fixture, redirects | Responsiveness and first content, network time apart. |
| Daily work | 20 tabs in 3 Spaces: docs, local app, PR-like DOM | Selection and Space changes, CPU, memory, sleep eligibility. |
| Churn | 100 open/close cycles, in 3 blocks | Objects, subscriptions and views settle to a plateau. |
| Sleep | 20 eligible pages; draft, media, call and download exceptions | Resources released, correct wake, bounded peak during discard. |
| Idle | Blank, static and dynamic fixtures, foreground and background | At least 120 s of CPU and wakeups with no bench traffic. |
| Features | Off, on, dismissed; 0, 1 then 3 extensions | Incremental cost and no residual work after disable. |
| Persistence | Rapid edits, quit during queued writes, parked navigation | Latest state wins, every Space flushed, no UI stall. |

Use local fixtures for repeatability; report a real-project workload
separately. Use at least 10 launches for launch figures and 100 samples across
alternating runs for an interaction p95; report the spread, and call a result
inconclusive when variability hides the effect. Use Instruments (Time
Profiler, SwiftUI, Allocations, System Trace) or `footprint`; `ps` RSS is a
diagnostic proxy. WebKit services are not reliably found by parent PID, so
check attribution and avoid double-counting shared processes.

## Review gates

These are provisional engineering thresholds, not measured claims or product
budgets. A metric not measured is reported as unmeasured, never as passed.

| Gate | Rule |
|---|---|
| Disabled feature | Zero recurring work and no live page or worker of its own. |
| Restored session | 100 restored tabs build only the selected page before interaction. |
| UI work | p95 ≤ 16.7 ms from input to run-loop rest for typing and selection on local fixtures; inspect main-thread work above 8 ms. |
| Latency regression | Review a repeated regression above both 5% and 2 ms in the median or p95. |
| Memory regression | Review a settled increase above both 5% and 5 MiB in the browser, or 5% and 20 MiB in the aggregate; also inspect peak and retained objects. |
| Idle regression | Review an increase above 0.5 point of one-core CPU over 120 s, or new recurring wakeups. |
| Lifecycle | No revival after close, no lost draft, ordered flush, bounded retained resources. A functional failure blocks the change. |

Compare against the PR's base and a fixed release baseline; small increases
accumulate. Crossing a gate needs a written trade-off with a measured benefit
or an offset.

## What a PR records

```text
Workload / commit / build / Mac / OS / power / visibility:
Feature activation, limits, cleanup and shared essential work:
Before and after: sample count, median, p95 where supported, spread:
Browser / attributable WebKit / extension / aggregate memory:
Idle CPU / wakeups / energy, or why unaffected or unmeasured:
Bench commands and raw result path:
Regression, uncertainty, trade-off and baseline used:
```

Apple's references on
[SwiftUI performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance),
[memory footprint](https://developer.apple.com/library/archive/technotes/tn2434/_index.html)
and [timer efficiency](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html)
support these rules; the numerical gates are Escale's own.
