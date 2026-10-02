#!/usr/bin/env bash
# Reproducible engine/app builds.
#
# Use: scripts/native/build.sh --platform macos|simulator|device [--configuration Release]
#
#   macos      the port's own Aurora-enabled desktop executable (N1 baseline)
#   simulator  the iOS Simulator app bundle, linked against Simulator libraries
#   device     the same app linked against device libraries, left unsigned
#
# Platform metadata is asserted after every mobile build, because an iOS device
# archive and an iOS Simulator library are both arm64 and a host dylib can slip
# in unnoticed.

# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

PLATFORM=""
CONFIGURATION="Release"
TARGET=""
NO_BOOTSTRAP=0

while [ $# -gt 0 ]; do
    case "$1" in
        --platform) PLATFORM="$2"; shift 2 ;;
        --platform=*) PLATFORM="${1#*=}"; shift ;;
        --configuration|-c) CONFIGURATION="$2"; shift 2 ;;
        --configuration=*) CONFIGURATION="${1#*=}"; shift ;;
        --target) TARGET="$2"; shift 2 ;;
        --no-bootstrap) NO_BOOTSTRAP=1; shift ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ -n "$PLATFORM" ] || die "--platform is required (macos|simulator|device)"

case "$PLATFORM" in
    macos|simulator|device) JOBS="$(build_jobs)" ;;
    *) die "unknown platform: $PLATFORM" ;;
esac

require_toolchain
[ -d "${PORT_DIR}" ] || die "engine not checked out; run scripts/native/bootstrap.sh first"

BUILD_DIR="$(platform_build_dir "$PLATFORM")"
LOG="${LOG_DIR}/build-${PLATFORM}-${CONFIGURATION}.log"
log_new "$LOG"

if [ "$NO_BOOTSTRAP" = "0" ] && [ "$PLATFORM" != "macos" ]; then
    "${BALLPAD_ROOT}/scripts/native/bootstrap.sh" --platform "$PLATFORM"
fi

# --no-bootstrap skips dependency preparation, never source identity checks.
"${BALLPAD_ROOT}/scripts/native/verify-clean.sh" --scope source

configure_macos() {
    run_logged "$LOG" cmake -G Ninja -S "${PORT_DIR}" -B "${BUILD_DIR}" \
        -DCMAKE_BUILD_TYPE="${CONFIGURATION}" \
        "${DAWN_CACHE_ARGS[@]}"
}

configure_mobile() {
    local sysroot
    case "$PLATFORM" in
        simulator) sysroot=iphonesimulator ;;
        device)    sysroot=iphoneos ;;
    esac
    local sdl3="${DEPS_ROOT}/sdl3/${PLATFORM}"
    local ffmpeg="${DEPS_ROOT}/ffmpeg/${PLATFORM}"
    [ -d "$sdl3" ]   || die "missing SDL3 for $PLATFORM at $sdl3; run bootstrap.sh"
    [ -d "$ffmpeg" ] || die "missing FFmpeg for $PLATFORM at $ffmpeg; run bootstrap.sh"
    [ -f "${DAWN_SRC}/CMakeLists.txt" ] \
        || die "missing Dawn source at $DAWN_SRC; run bootstrap.sh"
    [ -f "${ZSTD_SRC}/build/cmake/CMakeLists.txt" ] \
        || die "missing zstd source at $ZSTD_SRC; run bootstrap.sh"

    run_logged "$LOG" cmake -G Ninja -S "${BALLPAD_ROOT}/mobile" -B "${BUILD_DIR}" \
        -DCMAKE_BUILD_TYPE="${CONFIGURATION}" \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="$sysroot" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET}" \
        -DPORT_DIR="${PORT_DIR}" \
        -DBALLPAD_SDL3_ROOT="$sdl3" \
        -DBALLPAD_FFMPEG_ROOT="$ffmpeg" \
        -DBALLPAD_ZSTD_ROOT="${ZSTD_SRC}" \
        -DBALLPAD_PLATFORM="$PLATFORM" \
        -DAURORA_DAWN_PROVIDER=vendor \
        -DAURORA_SDL3_PROVIDER=system \
        -DFETCHCONTENT_SOURCE_DIR_DAWN="${DAWN_SRC}" \
        "${DAWN_CACHE_ARGS[@]}"
}

case "$PLATFORM" in
    macos) configure_macos ;;
    *)     configure_mobile ;;
esac

build_args=(--build "${BUILD_DIR}" -j "$JOBS")
[ -n "$TARGET" ] && build_args+=(--target "$TARGET")
run_logged "$LOG" cmake "${build_args[@]}"

case "$PLATFORM" in
    macos)
        assert_macho_platform "${BUILD_DIR}/strikers" macos
        log "macOS engine: ${BUILD_DIR}/strikers"
        ;;
    *)
        # The app target belongs to the port's own add_subdirectory(), so its bundle lands in the
        # port's binary directory and not at the top of the build tree. mobile/CMakeLists.txt
        # publishes the authoritative path at configure time; the plain location and a bounded
        # search are fallbacks for a build directory that predates that file. Guessing wrong here
        # is not cosmetic: this assertion is what catches a device-archive/Simulator mix-up, and a
        # path that silently missed the bundle would turn it into a build failure instead.
        APP=""
        if [ -f "${BUILD_DIR}/ballpad-bundles.txt" ]; then
            APP="$(awk -F= '$1 == "strikers" { print substr($0, index($0, "=") + 1); exit }' \
                   "${BUILD_DIR}/ballpad-bundles.txt")"
        fi
        if [ -z "$APP" ] || [ ! -d "$APP" ]; then
            APP="${BUILD_DIR}/BallpadStrikers.app"
        fi
        if [ ! -d "$APP" ]; then
            APP="$(find "${BUILD_DIR}" -maxdepth 3 -type d -name 'BallpadStrikers.app' -print -quit)"
        fi
        [ -n "$APP" ] && [ -d "$APP" ] || die "app bundle was not produced under ${BUILD_DIR}"
        BINNAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist" 2>/dev/null \
                   || basename "$APP" .app)"
        assert_macho_platform "$APP/$BINNAME" "$([ "$PLATFORM" = device ] && echo ios || echo iossimulator)"
        log "iOS app bundle: $APP"
        ;;
esac

log "build complete: $PLATFORM/$CONFIGURATION -> ${BUILD_DIR}"
