#!/usr/bin/env bash
# Verify the toolchain and pins, acquire the maintained engine into the ignored
# source checkout at its pinned commit, and prepare platform
# dependencies for macOS, the iOS Simulator and/or iOS device.
#
# Use: scripts/native/bootstrap.sh [--platform macos|simulator|device|all] [--fetch-only] [--skip-deps]
#
# No step downloads game data, touches another task's Simulator, or writes
# secrets. Everything lands under build/ or work/, both ignored.

# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

PLATFORMS="macos"
FETCH_ONLY=0
SKIP_DEPS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --platform) PLATFORMS="$2"; shift 2 ;;
        --platform=*) PLATFORMS="${1#*=}"; shift ;;
        --fetch-only) FETCH_ONLY=1; shift ;;
        --skip-deps) SKIP_DEPS=1; shift ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

if [ "$PLATFORMS" = "all" ]; then
    PLATFORMS="macos simulator device"
fi

JOBS="$(build_jobs)"
log "Ballpad native bootstrap"
require_toolchain
printf '    cmake   %s\n' "$(cmake --version | head -1)"
printf '    ninja   %s\n' "$(ninja --version)"
printf '    clang   %s\n' "$(clang --version | head -1)"
printf '    xcode   %s\n' "$(xcodebuild -version | tr '\n' ' ')"

mkdir -p "$LOG_DIR" "$DEPS_ROOT"

# ── 1. Engine checkout ────────────────────────────────────────────────────────
fetch_engine() {
    if [ -d "${ENGINE_DIR}/.git" ]; then
        [ -z "$(git -C "${ENGINE_DIR}" status --porcelain)" ] \
            || die "engine checkout has local edits; commit and publish them in the maintained source fork before updating the pin"
    else
        log "cloning maintained source ${ENGINE_URL}"
        mkdir -p "$(dirname "${ENGINE_DIR}")"
        git clone --quiet "${ENGINE_URL}" "${ENGINE_DIR}"
        git -C "${ENGINE_DIR}" checkout --quiet --detach "${ENGINE_PIN}"
    fi

    if ! git -C "${ENGINE_DIR}" cat-file -e "${ENGINE_PIN}^{commit}" 2>/dev/null; then
        git -C "${ENGINE_DIR}" fetch --quiet "${ENGINE_URL}" "${ENGINE_PIN}"
    fi
    [ "$(git -C "${ENGINE_DIR}" rev-parse HEAD)" = "${ENGINE_PIN}" ] \
        || die "engine HEAD differs from the maintained pin ${ENGINE_PIN}; inspect and explicitly checkout the pin (bootstrap preserves existing work)"
    [ "$(git -C "${ENGINE_DIR}" rev-parse 'HEAD^{tree}')" = "${ENGINE_SOURCE_TREE}" ] \
        || die "engine source tree differs from the maintained pin"
    log "maintained engine ${ENGINE_PIN}, tree ${ENGINE_SOURCE_TREE}"
}

# ── 3. Local asset identity (never redistributed, never written) ──────────────
verify_asset() {
    if [ ! -f "${GAME_IMAGE}" ]; then
        warn "no candidate image at ${GAME_IMAGE}; independent build work continues"
        return 0
    fi
    local want="${GAME_IMAGE_SHA256}"
    local got
    got="$(sha256_of "${GAME_IMAGE}")"
    if [ "$got" = "$want" ]; then
        log "game image identity ok (G4QE01 rev 0, sha256 $got)"
    else
        warn "game image sha256 $got does not match the recorded baseline $want"
        warn "treat gameplay evidence from this image as unattributed"
    fi
}

# ── 4. Platform dependencies ─────────────────────────────────────────────────
sdl3_src() {
    local dest="${DEPS_ROOT}/src/SDL3"
    if [ ! -d "$dest" ]; then
        mkdir -p "$(dirname "$dest")"
        local tgz="${DEPS_ROOT}/src/SDL3-${SDL3_TAG}.tar.gz"
        curl -fsSL --retry 3 -o "$tgz" \
            "https://github.com/libsdl-org/SDL/archive/refs/tags/${SDL3_TAG}.tar.gz"
        tar -xzf "$tgz" -C "${DEPS_ROOT}/src"
        mv "${DEPS_ROOT}/src/SDL-${SDL3_TAG}" "$dest"
    fi
    echo "$dest"
}

prepare_sdl3() {
    local platform="$1"
    local out="${DEPS_ROOT}/sdl3/${platform}"
    if [ -f "${out}/lib/libSDL3.a" ]; then
        log "SDL3 already built for $platform"
        return 0
    fi
    local src; src="$(sdl3_src)"
    local args=(
        -G Ninja -S "$src" -B "${out}"
        -DCMAKE_BUILD_TYPE=Release
        -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_FRAMEWORK=OFF
        -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF -DSDL_INSTALL=ON
        -DCMAKE_INSTALL_PREFIX="${out}"
        -DCMAKE_OSX_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET}"
        -DCMAKE_OSX_ARCHITECTURES=arm64
    )
    case "$platform" in
        macos)     args+=(-DCMAKE_OSX_SYSROOT=macosx) ;;
        simulator) args+=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphonesimulator) ;;
        device)    args+=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos) ;;
        *) die "prepare_sdl3: unknown platform $platform" ;;
    esac
    log_new "${LOG_DIR}/bootstrap-sdl3-${platform}.log"
    run_logged "${LOG_DIR}/bootstrap-sdl3-${platform}.log" cmake "${args[@]}"
    run_logged "${LOG_DIR}/bootstrap-sdl3-${platform}.log" \
        cmake --build "${out}" --target install
    [ -f "${out}/lib/libSDL3.a" ] || die "SDL3 static library was not produced for $platform"
}

# Static, THP-only FFmpeg. The port's own THP demuxer and DSP-ADPCM audio
# decoder mean libavcodec only has to supply AV_CODEC_ID_THP video.
prepare_ffmpeg() {
    local platform="$1"
    local out="${DEPS_ROOT}/ffmpeg/${platform}"
    local stamp="${out}/.ballpad-ffmpeg"
    if [ -f "${out}/lib/libavcodec.a" ] && [ -f "$stamp" ] \
       && [ "$(cat "$stamp")" = "${FFMPEG_SHA256}" ]; then
        log "FFmpeg already built for $platform"
        return 0
    fi

    local work; work="$(mktemp -d)"
    local tgz="${work}/ffmpeg.tar.xz"
    log "fetching ${FFMPEG_URL}"
    curl -fsSL --retry 3 -o "$tgz" "${FFMPEG_URL}"
    [ "$(sha256_of "$tgz")" = "${FFMPEG_SHA256}" ] \
        || die "ffmpeg tarball sha256 mismatch"
    tar -xJf "$tgz" -C "$work"

    local sdk arch target_min sysroot
    sysroot="$(platform_sysroot "$platform")"
    arch=arm64
    case "$platform" in
        macos)     target_min=(-mmacosx-version-min="${IOS_DEPLOYMENT_TARGET}") ;;
        simulator) target_min=(-target arm64-apple-ios"${IOS_DEPLOYMENT_TARGET}"-simulator) ;;
        device)    target_min=(-target arm64-apple-ios"${IOS_DEPLOYMENT_TARGET}") ;;
    esac

    local cflags=(-arch "$arch" -isysroot "$sysroot" -O2 -fPIC "${target_min[@]}")
    ( cd "${work}/ffmpeg-${FFMPEG_VERSION}" && ./configure \
        --prefix="${out}" --cc="$(xcrun --find clang)" \
        --enable-cross-compile --target-os=darwin --arch="$arch" \
        --enable-static --disable-shared --enable-pic --disable-asm \
        --disable-autodetect --disable-programs --disable-doc --disable-network \
        --disable-avformat --disable-avfilter --disable-avdevice \
        --disable-swscale --disable-swresample \
        --disable-everything --enable-decoder=thp \
        --extra-cflags="${cflags[*]}" --extra-ldflags="${cflags[*]}" \
        > "${work}/configure.log" 2>&1 ) || {
        tail -n 30 "${work}/configure.log" >&2
        die "ffmpeg configure failed for $platform"
    }
    ( cd "${work}/ffmpeg-${FFMPEG_VERSION}" && make -j"$JOBS" \
        > "${work}/make.log" 2>&1 ) || {
        tail -n 30 "${work}/make.log" >&2
        die "ffmpeg make failed for $platform"
    }
    rm -rf "$out"
    ( cd "${work}/ffmpeg-${FFMPEG_VERSION}" && make install > /dev/null )
    printf '%s' "${FFMPEG_SHA256}" > "$stamp"
    rm -rf "$work"
    log "FFmpeg (thp decoder only) -> ${out}"
}

# Dawn, from the pinned source ref, prepared once per checkout rather than per
# platform: the source tree is shared, and only the build output differs by
# platform. Dawn is the one dependency with no iOS Simulator prebuilt slice
# upstream -- Aurora's provider regex resolves an arm64 iOS configure, Simulator
# and device alike, onto the device archive -- so it is built from source here.
# The tarball is extracted into a staging directory and moved into place only
# after tar succeeds, so an interrupted run cannot leave a half-populated tree
# that a later run would mistake for complete.
prepare_dawn() {
    local staged="${DAWN_SRC}.staging.$$"
    if [ -d "${DAWN_SRC}/src" ] && [ -f "${DAWN_SRC}/CMakeLists.txt" ]; then
        log "Dawn source already present at ${DAWN_SRC}"
        return 0
    fi
    local src_parent
    src_parent="$(dirname "${DAWN_SRC}")"
    mkdir -p "$src_parent"
    local tgz="${src_parent}/dawn-${DAWN_REF}.tar.gz"
    if [ ! -f "$tgz" ]; then
        log "fetching ${DAWN_URL}"
        curl -fsSL --retry 3 -o "$tgz" "${DAWN_URL}"
    fi
    log "extracting Dawn ${DAWN_VERSION} (${DAWN_REF})"
    rm -rf "$staged"
    mkdir -p "$staged"
    tar -xzf "$tgz" -C "$staged"
    local extracted="${staged}/dawn-${DAWN_REF}"
    [ -f "${extracted}/CMakeLists.txt" ] \
        || die "Dawn archive did not contain the expected tree at ${extracted}"
    rm -rf "${DAWN_SRC}.partial"
    if [ -d "${DAWN_SRC}" ]; then
        mv "${DAWN_SRC}" "${DAWN_SRC}.partial"
    fi
    mv "$extracted" "${DAWN_SRC}"
    rm -rf "$staged" "${DAWN_SRC}.partial"
    log "Dawn source ready: ${DAWN_SRC}"
}

# The pinned zstd source, prepared once per checkout like Dawn, because the source
# tree is shared and only Aurora's build output differs by platform. pkg-config on
# the host would otherwise satisfy Aurora's zstd lookup with a Homebrew library that
# cannot link into a Simulator or device binary; see the pin's comment in common.sh.
# The tarball is hash-checked and extracted through a staging directory for the same
# reason Dawn is: an interrupted run must not leave a plausible-looking partial tree.
prepare_zstd() {
    local staged="${ZSTD_SRC}.staging.$$"
    if [ -f "${ZSTD_SRC}/build/cmake/CMakeLists.txt" ]; then
        log "zstd source already present at ${ZSTD_SRC}"
        return 0
    fi
    local src_parent
    src_parent="$(dirname "${ZSTD_SRC}")"
    mkdir -p "$src_parent"
    local tgz="${src_parent}/zstd-${ZSTD_VERSION}.tar.gz"
    if [ ! -f "$tgz" ]; then
        log "fetching ${ZSTD_URL}"
        curl -fsSL --retry 3 -o "$tgz" "${ZSTD_URL}"
    fi
    [ "$(sha256_of "$tgz")" = "${ZSTD_SHA256}" ] \
        || die "zstd tarball sha256 mismatch"
    log "extracting zstd ${ZSTD_VERSION}"
    rm -rf "$staged"
    mkdir -p "$staged"
    tar -xzf "$tgz" -C "$staged"
    local extracted="${staged}/zstd-${ZSTD_VERSION}"
    [ -f "${extracted}/build/cmake/CMakeLists.txt" ] \
        || die "zstd archive did not contain build/cmake at ${extracted}"
    rm -rf "${ZSTD_SRC}.partial"
    if [ -d "${ZSTD_SRC}" ]; then
        mv "${ZSTD_SRC}" "${ZSTD_SRC}.partial"
    fi
    mv "$extracted" "${ZSTD_SRC}"
    rm -rf "$staged" "${ZSTD_SRC}.partial"
    log "zstd source ready: ${ZSTD_SRC}"
}

prepare_deps() {
    local platform="$1"
    prepare_sdl3 "$platform"
    prepare_ffmpeg "$platform"
    prepare_dawn
    prepare_zstd
}

fetch_engine
verify_asset

if [ "$FETCH_ONLY" = "1" ]; then
    log "fetch-only: stopping after maintained source verification"
    exit 0
fi

if [ "$SKIP_DEPS" = "1" ]; then
    log "skip-deps: no platform dependencies prepared"
    exit 0
fi

for p in $PLATFORMS; do
    log "preparing dependencies for $p"
    prepare_deps "$p"
done

log "bootstrap complete (run id ${RUN_ID})"
