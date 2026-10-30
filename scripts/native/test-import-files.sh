#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
mkdir -p "$root/build/import-file-tests"
xcrun clang++ -std=c++17 -fobjc-arc -framework Foundation \
    "$root/tests/BallpadImportFilesTests.mm" -o "$root/build/import-file-tests/tests"
"$root/build/import-file-tests/tests"
