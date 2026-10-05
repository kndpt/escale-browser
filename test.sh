#!/bin/zsh
# The Swift tests: `swift test`, and whatever it needs on this Mac to find
# Swift Testing.
#
# Xcode puts the framework where `swift test` looks. The Command Line Tools
# ship it too, but beside the toolchain rather than on its search paths, so
# with only those selected the tests don't compile (no module 'Testing') and
# then don't load (lib_TestingInterop.dylib). Their folder is named here, and
# nothing is downloaded. Tests keep a separate scratch directory: switching
# these flags on/off in the app's .build recompiles it at every build/test turn.
# Extra arguments go to `swift test`; an explicit --scratch-path takes priority.
set -euo pipefail
cd "$(dirname "$0")"

flags=()
scratch=(--scratch-path .build/tests)
for argument in "$@"; do
  case "$argument" in --scratch-path|--scratch-path=*) scratch=() ;; esac
done
developer=$(xcode-select -p 2>/dev/null || true)
if [[ "$developer" == */CommandLineTools ]]; then
  lib="$developer/Library/Developer"
  flags=(
    -Xswiftc -F -Xswiftc "$lib/Frameworks"
    -Xlinker -F -Xlinker "$lib/Frameworks"
    -Xlinker -rpath -Xlinker "$lib/Frameworks"
    -Xlinker -rpath -Xlinker "$lib/usr/lib"
  )
fi

exec swift test "${scratch[@]}" "${flags[@]}" "$@"
