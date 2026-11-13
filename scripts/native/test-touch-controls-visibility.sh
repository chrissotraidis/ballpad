#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
mkdir -p "$root/build/touch-visibility-tests"
xcrun clang++ -std=c++17 -I"$root/mobile/interface/sunpad" \
    "$root/tests/BallpadTouchControlsVisibilityTests.cpp" \
    -o "$root/build/touch-visibility-tests/tests"
"$root/build/touch-visibility-tests/tests"
