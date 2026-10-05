# Contributing

Thank you for helping with Escale. Here is how to build it, test it and send
a change.

## Efficiency first

It is the one principle to remember. Escale must stay light on the Mac it
runs on, so a contribution is judged on what it costs as much as on what it
does:

- the app uses as little CPU, memory, energy and network as it can;
- the change is the smallest one that solves the problem, with no extra
  options, abstractions, dead code or dependencies;
- comments, docs and pull request descriptions are short and plain.

A pull request that adds a feature by making Escale heavier, or that
rewrites more than it needs to, will be asked to shrink.

## Start with an issue

For a bug or an idea, open an [issue](https://github.com/kndpt/escale-browser/issues/new/choose)
first. For anything bigger than a small fix, agree on the approach there
before writing code. Security problems go through [SECURITY](SECURITY.md),
not public issues. The maintainer labels issues; `good first issue` is a good
place to start.

The [source map](docs/ARCHITECTURE.md#source-map) shows where things are.
Most features live in one domain folder under `Sources/Escale/`.

## Build and run

You need macOS 14 or later and Xcode 16.3 or later, or its Command Line Tools
(the macOS 15.4 SDK). Python 3, which ships with them, runs `verify`, `bench`
and `changelog`. There are no other dependencies and no Apple developer
account is needed.

```sh
swift build               # debug build; its binary always runs as a test run
./build.sh debug          # build/Escale.app from a debug build, for iterating
./build.sh                # the same from an optimised release build (slower)
./fresh.sh                # open a copy of it in an isolated test world
./fresh.sh stop           # quit it; ./fresh.sh wipe also removes its data
```

Never open `build/Escale.app` directly: it has the released app's identity and
would use an installed Escale's data. `./fresh.sh` runs a copy under a test
identity with its own files, settings, keychain and WebKit store. macOS may
ask you to approve the ad-hoc signed app in System Settings › Privacy &
Security.

## Tests

```sh
./verify run              # the checks that match your changed files
./verify run --quick      # a faster loop while iterating
./test.sh                 # every Swift test
./test.sh --filter Name   # one test or suite
```

A new rule needs a unit test. A change in how the app or a page behaves needs
the relevant app scenario ([bench](.agents/skills/escale-bench/SKILL.md)) or a
manual check described in the pull request; [TESTING](docs/TESTING.md) says
which. CI builds and runs the unit tests but never launches the app, so app
checks are yours to run. A documentation-only change skips them.

## Pull requests

Read [AGENTS](AGENTS.md) before writing code: it holds the rules for people
and coding agents alike.

- **One pull request, one topic.** Keep refactors, renames and formatting out
  of a feature or a fix.
- **Tests are required** for a change in behaviour, at the right layer.
- **Describe what you checked by hand**: the steps in a test world, and light
  and dark appearance for a visual change. The
  [template](.github/pull_request_template.md) has the sections.
- Commits are in English: `type(scope): subject`, for example
  `fix(tabs): keep the pinned order after a restore`.
- A change people will notice adds a one-paragraph note in
  [changelog.d](changelog.d/README.md). Tests, tooling and documentation need
  none.
- Link the issue: `Closes #N`, or `Refs #N` when it covers only part.

Pull requests written with a coding agent are welcome, as long as you have
read every line, run the tests and checked the behaviour yourself. You are the
author and answer the review.

## Contributor License Agreement

Before a first pull request can be merged, you sign the
[Contributor License Agreement](CLA.md): CLA Assistant comments on the pull
request with a link, and signing takes one click with your GitHub account.
You keep the copyright of your work; the agreement lets the maintainer
distribute it under the GPL and, if needed, other licenses.

## Reporting a bug

Use the bug form, or **Help › Send Feedback…** in Escale, which fills in the
version, build and macOS. Say what you did, what you expected and what
happened. If Escale crashed, a log may be at
`~/Library/Application Support/Escale/crash.log`; it stays on your Mac unless
you choose to attach it.
