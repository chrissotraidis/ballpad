#!/usr/bin/env bash
# Shared configuration and helpers for the native Strikers build surface.
#
# Source this file; do not execute it. Every scripts/native/*.sh entry point
# sources it so pins, paths and platform rules live in exactly one place.

set -euo pipefail

BALLPAD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly BALLPAD_ROOT

# Maintained source pin. Bootstrap and provenance checks consume this exact commit.
readonly ENGINE_URL="https://github.com/pedroea0/strikers.git"
readonly ENGINE_PIN="9e1a9a9d0121363efb2f4a9343ffd232416dd403"
readonly ENGINE_SOURCE_TREE="a0e22501e34186e18947c9d0f341afb01d585c17"
readonly UPSTREAM_URL="https://github.com/new-coke/strikers.git"
readonly UPSTREAM_PIN="4ba5dce1b927c3712a7b0e76100c1b2fe448fc00"
readonly ENGINE_BRANCH="ballpad-ios-rebase"
readonly ENGINE_DIR="${BALLPAD_ROOT}/work/native/strikers"
readonly PORT_DIR="${ENGINE_DIR}/smstrikers-port"

readonly BUILD_ROOT="${BALLPAD_ROOT}/build/native"
readonly LOG_DIR="${BUILD_ROOT}/logs"
readonly DEPS_ROOT="${BUILD_ROOT}/deps"
readonly PROOF_ROOT="${BALLPAD_ROOT}/build/proofs/native-strikers"
readonly MANIFEST="${BALLPAD_ROOT}/docs/native-strikers-dependency-manifest.json"
readonly ASSET_DIR="${BALLPAD_ROOT}/.local-assets"
readonly GAME_IMAGE="${ASSET_DIR}/Super Mario Strikers.iso"
# The one known candidate image: USA raw disc revision 0 (G4QE01). Declared here so
# bootstrap's identity check and every proof bundle name the same value; the image itself
# is never redistributed, committed or written to.
readonly GAME_IMAGE_SHA256="da80883ba45619ce3854536d582e6af23cba461fba6383daa652138e869bfb6a"

# Matches the existing Ballpad app target so the ported app keeps the project identity.
readonly IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-17.0}"
readonly IOS_BUNDLE_ID="com.ballpad.strikers"

# Dependency pins mirrored from the manifest and Aurora's own version file.
readonly DAWN_REF="1155e0ed531126f33a1279afa029349651ca1c93"
readonly DAWN_VERSION="v20260807.225922"
readonly DAWN_URL="https://github.com/encounter/dawn/archive/${DAWN_REF}.tar.gz"
# Dawn is the one dependency with no iOS Simulator prebuilt slice: the Aurora
# provider's regex resolves an ios-arm64 configure -- Simulator and device alike
# -- onto the device archive. So the pinned ref is fetched once here and built
# from source per platform; see docs/native-strikers-dependency-manifest.json.
readonly DAWN_SRC="${DEPS_ROOT}/src/dawn"
# Dawn cache settings that every platform's configure passes through.
#
# Dawn builds protobuf by default and Tint's IR binary format defaults to that
# same switch, but neither reaches anything the app links. No file under
# dawn/src/dawn/ references protobuf at all, and the only consumers are Tint's
# tint_lang_core_ir_binary encode/decode pair (a .ir.bin round-trip format used
# by tests and fuzzers), the protobuf message library that pair needs, and the
# libprotobuf-mutator fuzzers. Turning the two switches off together is the
# combination Dawn itself insists on -- src/tint/CMakeLists.txt rejects IR
# binary without protobuf -- so nothing is left half-configured.
#
# It is also the difference between an iOS configure succeeding and failing.
# third_party/protobuf.cmake refuses to configure without a host protoc
# whenever CMAKE_CROSSCOMPILING is set, and -DCMAKE_SYSTEM_NAME=iOS always sets
# it, Simulator included -- the Simulator slice runs natively here, but CMake's
# cross-compiling model does not care. Building a host protoc to generate
# sources that nothing links is the worse trade.
#
# Both flags are pinned rather than left to default because a build directory
# that once configured with protobuf on keeps TINT_BUILD_IR_BINARY=ON in its
# cache, which reproduces this same failure on the next configure. The macOS
# build gets these too; it resolves the prebuilt Dawn package, where Dawn's own
# CMakeLists never runs, so they are inert there rather than divergent.
DAWN_CACHE_ARGS=(
    "-DDAWN_BUILD_PROTOBUF=OFF"
    "-DTINT_BUILD_IR_BINARY=OFF"
)
readonly SDL3_TAG="release-3.4.10"
readonly FFMPEG_VERSION="9.0.1"
readonly FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
readonly FFMPEG_SHA256="cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635"

# zstd is the one Aurora dependency a host package manager will satisfy first.
# Aurora tries find_package(zstd CONFIG) and then pkg-config before it fetches its
# own copy, and a Homebrew libzstd satisfies that pkg-config lookup even for an iOS
# configure, because pkg-config has no notion of the target sysroot. The result was
# a bare -lzstd with no valid search path and a link failure, and had the path
# resolved it would have linked a host archive into a Simulator binary.
#
# So the pinned source is fetched here and handed to Aurora through
# -DFETCHCONTENT_SOURCE_DIR_ZSTD, which keeps the dependency in the same declared
# cache as Dawn, SDL3 and FFmpeg. URL and hash are Aurora's own for 1.5.7, so this
# pin and Aurora's fallback fetch describe the same tree.
readonly ZSTD_VERSION="1.5.7"
readonly ZSTD_URL="https://github.com/facebook/zstd/releases/download/v${ZSTD_VERSION}/zstd-${ZSTD_VERSION}.tar.gz"
readonly ZSTD_SHA256="eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3"
readonly ZSTD_SRC="${DEPS_ROOT}/src/zstd"

readonly RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

# Run a command with its output both shown and appended to a phase log, so a
# proof bundle and the terminal agree.
run_logged() {
    local logfile="$1"; shift
    mkdir -p "$(dirname "$logfile")"
    log "$*"
    { printf '\n$ %s\n' "$*"; "$@" 2>&1; } | tee -a "$logfile"
}

# Start a phase log fresh. run_logged() appends so that one run's configure and build land in
# the same file, but nothing reset that file between runs, and a log holding several runs at once
# makes the current one unreadable: output from an earlier run that took a different code path is
# indistinguishable from this run's. A phase log is per-run evidence, so each script opens its own
# with this before its first run_logged().
log_new() {
    mkdir -p "$(dirname "$1")"
    : > "$1"
}

require_toolchain() {
    require_cmd git
    require_cmd cmake
    require_cmd ninja
    require_cmd xcrun
    require_cmd xcodebuild
    xcodebuild -version >/dev/null 2>&1 || die "xcodebuild is not usable (license or selection)"
}

# The SDK to build a platform against; also used to validate that dependency
# outputs really belong to that SDK.
platform_sysroot() {
    case "$1" in
        macos)     xcrun --sdk macosx --show-sdk-path ;;
        simulator) xcrun --sdk iphonesimulator --show-sdk-path ;;
        device)    xcrun --sdk iphoneos --show-sdk-path ;;
        *) die "unknown platform: $1" ;;
    esac
}

platform_build_dir() {
    case "$1" in
        macos)     echo "${BUILD_ROOT}/macos-release" ;;
        simulator) echo "${BUILD_ROOT}/simulator-release" ;;
        device)    echo "${BUILD_ROOT}/device-release" ;;
        *) die "unknown platform: $1" ;;
    esac
}

# Mach-O platform check. Architecture alone is not proof: the paired iOS
# Simulator and iOS device slices are both arm64, and only the LC_BUILD_VERSION
# platform value distinguishes them.
assert_macho_platform() {
    local file="$1" want="$2"
    [ -e "$file" ] || die "assert_macho_platform: missing $file"
    local plat
    plat="$(otool -l "$file" 2>/dev/null | awk '/LC_BUILD_VERSION/{f=1} f&&/platform/{print $2; exit}')"
    local got
    case "${plat:-}" in
        1) got=macos ;;
        2) got=ios ;;
        7) got=iossimulator ;;
        *) got="unknown(${plat:-none})" ;;
    esac
    if [ "$got" != "$want" ]; then
        die "$file is platform $got, expected $want (LC_BUILD_VERSION platform ${plat:-none})"
    fi
    log "platform metadata ok: $file -> $got"
}

sha256_of() {
    # openssl is an order of magnitude faster than the perl shasum on a
    # multi-gigabyte disc image, which bootstrap hashes on every run.
    if command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$1" | awk '{print $NF}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# Task-owned Simulator lock. It only ever touches devices this task owns,
# because scripts/sim_mutex.sh's global "simctl shutdown all" would kill another
# task's booted device.
readonly SIM_LOCK_DIR="${BUILD_ROOT}/sim-lock"
sim_lock_acquire() {
    mkdir -p "${SIM_LOCK_DIR}"
    local waited=0
    while ! mkdir "${SIM_LOCK_DIR}/held" 2>/dev/null; do
        if [ "$waited" -ge 900 ]; then
            die "timed out waiting for the task Simulator lock"
        fi
        sleep 3; waited=$((waited + 3))
    done
    echo "$$" > "${SIM_LOCK_DIR}/held/owner"
    trap 'rm -rf "${SIM_LOCK_DIR}/held"' EXIT
}
