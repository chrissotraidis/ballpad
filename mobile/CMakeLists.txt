cmake_minimum_required(VERSION 3.24)

# Ballpad's iOS application target.
#
# This is the superbuild that turns the native port into an iOS app. It consumes the
# Simulator or device dependencies that scripts/native/bootstrap.sh produced, points the port
# at them, and wraps the port's own executable in a .app bundle. It deliberately keeps the
# engine's build contract untouched: the port is added with add_subdirectory and every path it
# computes still resolves against its own source tree.

# OBJCXX in the language list is what lets the vendored SunPad interface (Objective-C++) join the
# application target. It is a top-level enable rather than a per-source property because CMake
# decides how to compile a .mm file from the enabled languages, not from the file's directory.
project(BallpadStrikers LANGUAGES C CXX OBJCXX)

set(BALLPAD_APP_NAME "BallpadStrikers" CACHE STRING "The application bundle and executable name")
set(BALLPAD_PROBE_NAME "BallpadProbe" CACHE STRING "The dependency link/launch probe bundle name")

if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
  message(FATAL_ERROR
    "mobile/ is the iOS application target and must be configured for iOS. Use "
    "scripts/native/build.sh --platform simulator|device, which supplies "
    "-DCMAKE_SYSTEM_NAME=iOS.")
endif()

foreach(_required PORT_DIR BALLPAD_SDL3_ROOT BALLPAD_FFMPEG_ROOT BALLPAD_ZSTD_ROOT BALLPAD_PLATFORM)
  if(NOT ${_required})
    message(FATAL_ERROR "${_required} is required; scripts/native/build.sh sets all of them.")
  endif()
endforeach()

# ── Host package isolation ────────────────────────────────────────────────────
# CMake's iOS platform module puts the sysroot on the compiler command line but leaves
# CMAKE_FIND_ROOT_PATH empty and the package/library/include search modes at their defaults, so a
# find_package() during this configure still reaches the host's prefixes. pkg-config is worse: it
# is not sysroot-aware unless it is told to be, so its database is the host's. Aurora consults
# both before it will build a dependency itself, which makes the leak concrete rather than
# theoretical -- its zstd lookup found /opt/homebrew/opt/zstd and the probe link died with
# "library 'zstd' not found", because no host library directory is a valid place to look for a
# Simulator library. A leak that resolved would be worse than one that fails: it would link a
# macOS archive into the app.
#
# CMAKE_IGNORE_PREFIX_PATH closes the find_package() half: with it set, a zstd config package
# under the Homebrew prefix is no longer reachable from this configure. The pkg-config half needs
# more care, because setting PKG_CONFIG_LIBDIR to the empty string does not narrow anything --
# CMake's set(ENV{...} "") unsets the variable instead of emptying it, and pkg-config then falls
# back to the search path it was compiled with, which on this host is the Homebrew prefix. That is
# why the empty string looked like isolation and behaved like none. Pointing both variables at an
# empty directory in the build tree is what actually leaves the database with nothing in it.
#
# What stays visible is exactly what bootstrap.sh prepared, which is the doc 33 rule that the
# Simulator and device artifacts link the pinned dependency set and nothing else. The three
# dependencies this project supplies are unaffected: SDL3, FFmpeg and zstd are all located by
# explicit path, and zstd does not depend on this isolation at all -- the target it needs is
# created from the pinned tree further down -- so what remains here is the guard against the next
# dependency whose resolution reaches for the host.
set(CMAKE_IGNORE_PREFIX_PATH "/opt/homebrew" "/usr/local")
set(BALLPAD_EMPTY_PKG_CONFIG_DIR "${CMAKE_BINARY_DIR}/ballpad-empty-pkgconfig")
file(MAKE_DIRECTORY "${BALLPAD_EMPTY_PKG_CONFIG_DIR}")
set(ENV{PKG_CONFIG_PATH} "${BALLPAD_EMPTY_PKG_CONFIG_DIR}")
set(ENV{PKG_CONFIG_LIBDIR} "${BALLPAD_EMPTY_PKG_CONFIG_DIR}")

# ── Shared vs static libraries ───────────────────────────────────────────────
# Aurora's vendored dependencies pick between a shared and a static library
# from whether BUILD_SHARED_LIBS is defined *at all*: undefined means shared
# (extern/aurora/extern/CMakeLists.txt:6-10). On macOS that never mattered,
# because its find_package() reached the Homebrew prefix and the app linked the
# host's own libpng. It matters here, because the isolation above removes that
# answer and makes Aurora build libpng from the pinned source -- and the shared
# result is a dylib that lives in this build tree, resolved at run time through
# an absolute build-tree rpath and never copied into the bundle. That is why it
# works in the Simulator and cannot work on a device.
#
# This is a fresh-directory defect. Aurora makes that choice before its own
# dependency blocks run, and it is the xxhash block that leaves BUILD_SHARED_LIBS
# in the cache at all, so on the first configure of a new build directory the
# variable is still undefined when the choice is made and libpng is built
# shared. A second configure of the same directory happens to correct it, which
# is what made this look intermittent. Declaring it here, in the directory that
# always runs first, is what makes a fresh Simulator *or device* directory
# deterministic. Upstream's own tools/configure.sh passes
# -DBUILD_SHARED_LIBS=OFF for the same reason, and FORCE is what keeps a stale
# cache entry from outvoting this file.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)

# ── SDL3 ──────────────────────────────────────────────────────────────────────
# SDL3 is a bootstrap dependency, not something Aurora fetches again here: one pinned tree per
# platform is what makes the Simulator and device builds reproducible, and it is also what keeps
# a Homebrew SDL3 from being picked up by a find_package() whose search path reaches the host.
set(_sdl3_cmake_dir "${BALLPAD_SDL3_ROOT}/lib/cmake/SDL3")
if(NOT EXISTS "${_sdl3_cmake_dir}/SDL3Config.cmake")
  message(FATAL_ERROR
    "No SDL3 package under ${BALLPAD_SDL3_ROOT}. Expected "
    "${_sdl3_cmake_dir}/SDL3Config.cmake; run scripts/native/bootstrap.sh --platform "
    "${BALLPAD_PLATFORM}.")
endif()
set(SDL3_DIR "${_sdl3_cmake_dir}" CACHE PATH "SDL3 package location for ${BALLPAD_PLATFORM}" FORCE)
set(CMAKE_FIND_PACKAGE_TARGETS_GLOBAL ON)
find_package(SDL3 CONFIG REQUIRED PATHS "${_sdl3_cmake_dir}" NO_DEFAULT_PATH NO_CMAKE_FIND_ROOT_PATH)
set(CMAKE_FIND_PACKAGE_TARGETS_GLOBAL OFF)

# Aurora resolves its own providers; both of these are set before add_subdirectory() below.
#
# SDL3 is forced rather than defaulted. A bare -DAURORA_SDL3_PROVIDER=vendor on the command
# line would otherwise survive, and Aurora would fetch and build a second, unpinned SDL3 during
# configure instead of using the tree this project just validated -- the opposite of the
# reproducible single-pinned-tree rule in doc 33.
if(AURORA_SDL3_PROVIDER AND NOT AURORA_SDL3_PROVIDER STREQUAL "system")
  message(FATAL_ERROR
    "AURORA_SDL3_PROVIDER=${AURORA_SDL3_PROVIDER} conflicts with the pinned SDL3 tree at "
    "${BALLPAD_SDL3_ROOT}. This project always configures -DAURORA_SDL3_PROVIDER=system.")
endif()
set(AURORA_SDL3_PROVIDER "system" CACHE STRING "Pinned SDL3 from scripts/native/bootstrap.sh" FORCE)
if(NOT AURORA_DAWN_PROVIDER)
  set(AURORA_DAWN_PROVIDER "vendor" CACHE STRING "" FORCE)
endif()

# Aurora's "auto" resolves Dawn to the prebuilt *package* on any ios-arm64 target, and the only
# published package is the device slice: a Simulator configure would fetch a library that cannot
# link. Build Dawn from the pinned source instead, which is what doc 33 requires when no package
# matches the SDK.
if(AURORA_DAWN_PROVIDER STREQUAL "auto" OR AURORA_DAWN_PROVIDER STREQUAL "package")
  message(FATAL_ERROR
    "AURORA_DAWN_PROVIDER=${AURORA_DAWN_PROVIDER} would resolve to the prebuilt ios-arm64 "
    "(device) Dawn package. An iOS build that is not the device SDK must use "
    "-DAURORA_DAWN_PROVIDER=vendor.")
endif()

# ── FFmpeg (THP video only) ───────────────────────────────────────────────────
set(STRIKERS_FFMPEG ON CACHE BOOL "" FORCE)
set(STRIKERS_FFMPEG_ROOT "${BALLPAD_FFMPEG_ROOT}" CACHE PATH "" FORCE)

# ── zstd (Aurora WebGPU cache compression) ────────────────────────────────────
# Aurora resolves this dependency itself, but only as a last resort: it asks find_package()
# first, then pkg-config, and on a host that has a libzstd one of the two answers with the
# host's library -- an archive that either cannot link into an iOS target or, worse, can. The
# way out is to define Aurora's own target name from the pinned tree before the port is added,
# because Aurora looks at nothing at all once that target exists.
#
# Doing it in the build graph rather than by narrowing the environment is what makes the result
# survive a re-configure. The environment can be narrowed correctly and still let a host library
# through: an older configure of this same directory that ran before the isolation above existed
# cached ZSTD_FOUND and its -L flags, and FindPkgConfig only ever sets that flag on success -- it
# unsets it at the start of a lookup, but it does not clear a value left in the cache by a
# previous run. A target that this file creates cannot be inherited that way: it either comes
# from the tree bootstrap.sh prepared or the build stops here.
#
# The static library is the only thing the application links, which is also what Aurora's own
# fallback selects. The command-line tool and the test suite are turned off because they are
# extra targets rather than extra coverage.
if(NOT EXISTS "${BALLPAD_ZSTD_ROOT}/build/cmake/CMakeLists.txt")
  message(FATAL_ERROR
    "No zstd source under ${BALLPAD_ZSTD_ROOT}. Expected "
    "${BALLPAD_ZSTD_ROOT}/build/cmake/CMakeLists.txt; run scripts/native/bootstrap.sh "
    "--platform ${BALLPAD_PLATFORM}.")
endif()
set(ZSTD_BUILD_STATIC ON CACHE BOOL "" FORCE)
set(ZSTD_BUILD_SHARED OFF CACHE BOOL "" FORCE)
set(ZSTD_BUILD_PROGRAMS OFF CACHE BOOL "" FORCE)
set(ZSTD_BUILD_TESTS OFF CACHE BOOL "" FORCE)
add_subdirectory("${BALLPAD_ZSTD_ROOT}/build/cmake" "${CMAKE_CURRENT_BINARY_DIR}/zstd"
                 EXCLUDE_FROM_ALL)
if(NOT TARGET libzstd_static)
  message(FATAL_ERROR
    "The pinned zstd tree at ${BALLPAD_ZSTD_ROOT} did not define its libzstd_static target.")
endif()
add_library(zstd::libzstd ALIAS libzstd_static)
# FetchContent is unreachable now, so pointing it at the same tree is a no-network guarantee
# rather than the mechanism: if a future Aurora reordered its resolution, this is what would keep
# a second, downloaded copy of zstd out of the build.
set(FETCHCONTENT_SOURCE_DIR_ZSTD "${BALLPAD_ZSTD_ROOT}" CACHE PATH
    "Pinned zstd source from scripts/native/bootstrap.sh" FORCE)
message(STATUS "ballpad: zstd from ${BALLPAD_ZSTD_ROOT} (libzstd_static, ${BALLPAD_PLATFORM})")
# ── The port ──────────────────────────────────────────────────────────────────
add_subdirectory("${PORT_DIR}" port)
if(NOT TARGET strikers)
  message(FATAL_ERROR "The port at ${PORT_DIR} did not define its `strikers` target.")
endif()

# ── SunPad's interface, vendored ──────────────────────────────────────────────
# `mobile/interface/sunpad/` is a byte-identical copy of SunPad's iOS touch interface, kept that
# way on purpose: doc 36 requirement R1 asks for its controls and three-dot menu "exactly as they
# are", and a copy that can be diffed against the sibling project is the only version of that
# claim a reader can check. See interface/sunpad/README.md for provenance and hashes.
#
# It is its own static library rather than a handful of sources added to `strikers` because the
# two have incompatible compile contracts. The port compiles with `port_flags`, which force
# `-fshort-wchar`, `-include port/prelude.h` and `-Werror=pointer-to-int-cast`; none of those are
# true of UIKit code, and the prelude in particular would be injected into every Objective-C++
# translation unit. A separate target keeps the vendored files compiling under the same ARC and
# the same warnings as the project they came from.
add_library(ballpad_interface STATIC
  interface/sunpad/SunPadGameOverlay.mm
  interface/sunpad/SunPadInputMixer.mm
  interface/sunpad/SunPadControllerMapping.mm
  interface/sunpad/SunPadSettings.mm
  interface/sunpad/SunPadDiagnostics.mm)
set_target_properties(ballpad_interface PROPERTIES
  CXX_STANDARD 17
  OBJCXX_STANDARD 17
  POSITION_INDEPENDENT_CODE ON)
# SunPad builds this code with ARC on (CLANG_ENABLE_OBJC_ARC = YES in its Xcode project), so the
# copy has to be built the same way or its ownership semantics change under it.
target_compile_options(ballpad_interface PRIVATE "-fobjc-arc")
target_include_directories(ballpad_interface PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/interface/sunpad")
target_link_libraries(ballpad_interface PUBLIC
  "-framework UIKit" "-framework Foundation" "-framework GameController" "-framework QuartzCore")

# ── Ballpad's side of the host-UI seam ────────────────────────────────────────
# BallpadHostUI.mm is deliberately not a member of ballpad_interface above, even though both are
# Objective-C++ built with ARC. That target is the vendored copy and nothing else, which is what
# keeps the R1 fidelity claim diffable; this file is the adaptation layer the vendored README asks
# for. They also need different include paths: this one is the only place that reaches into the
# port's headers (`port/hostui.h`), so the port's include directory belongs here, on the adapter,
# rather than widened onto the vendored copy. It needs SDL3 too, for the two calls that turn the
# port's SDL window back into the UIWindow that holds the render surface.
#
# ballpad_interface is linked PUBLIC rather than PRIVATE because the vendored headers are this
# file's direct includes; that also means the vendored static archive is on the app's link line
# once, through a target that names it, instead of twice.
add_library(ballpad_hostui STATIC
  interface/BallpadHostUI.mm
  interface/BallpadGameData.mm
  interface/BallpadLog.mm
  interface/BallpadCredits.mm
  interface/BallpadPhysicalControllers.mm
  interface/BallpadControllerMapping.mm)
set_target_properties(ballpad_hostui PROPERTIES
  CXX_STANDARD 17
  OBJCXX_STANDARD 17
  POSITION_INDEPENDENT_CODE ON)
target_compile_options(ballpad_hostui PRIVATE "-fobjc-arc")
target_include_directories(ballpad_hostui PRIVATE
  "${PORT_DIR}/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/interface")
target_link_libraries(ballpad_hostui PUBLIC ballpad_interface)
# UniformTypeIdentifiers is only for the Files picker's content-type filter, which lives in the
# adapter rather than in the vendored interface: SunPad's own picker asks for iso/gcm the same way,
# but its target does not share this file's link line.
target_link_libraries(ballpad_hostui PRIVATE SDL3::SDL3 "-framework UniformTypeIdentifiers")
# Whole-archive, and this is load-bearing rather than belt-and-braces.
#
# The port ships weak no-op versions of these four hooks (src/platform/hostui.c) so that it still
# links as a desktop executable and in its own test suite, where there is no app to implement them.
# A weak definition is not an undefined symbol, though, so the ordinary archive rule -- pull a
# member only to resolve an undefined reference -- resolves every hook to the port's own no-op and
# never looks in this adapter at all. Asking for the symbol by name does not help either, because
# the weak definition in the port's object file satisfies it before any archive is searched. Only
# an unconditional pull of the adapter's member puts the strong definitions on the link line, and
# a weak definition loses to a strong one when both are present.
#
# The failure mode this avoids is quiet: without it the app links, launches and presents the same
# frame it always did, with no touch controls, and the only symptom is a symbol that stayed weak.
target_link_libraries(strikers PRIVATE "$<LINK_LIBRARY:WHOLE_ARCHIVE,ballpad_hostui>")

# ── Application bundles ───────────────────────────────────────────────────────
# Info.plist is generated here rather than left to CMake's default template: the iOS keys
# (device families, launch screen, landscape-only orientation, document sharing) have no
# equivalent there, and generating it means the values are visible where they are set. The
# template is configured with @ONLY, so the leftover ${...} that CMake's bundle step would look
# for is absent and the file it copies is exactly the file written here.
set(BALLPAD_VERSION "1.0")
set(BALLPAD_BUILD_VERSION "3")
set(BALLPAD_MIN_OS "${CMAKE_OSX_DEPLOYMENT_TARGET}")
set(BALLPAD_COPYRIGHT
    "Unofficial project. Not affiliated with or endorsed by Nintendo or Next Level Games. "
    "See the bundled third-party notices for engine and dependency attribution.")

function(ballpad_ios_bundle target bundle_name bundle_id display_name)
  # An iOS executable is an application bundle, and CFBundleExecutable has to agree with the
  # file inside it, so the executable name is one variable driving both.
  set(BALLPAD_EXECUTABLE "${bundle_name}")
  set(BALLPAD_BUNDLE_ID "${bundle_id}")
  set(BALLPAD_DISPLAY_NAME "${display_name}")
  set(_plist "${CMAKE_CURRENT_BINARY_DIR}/${target}-Info.plist")
  configure_file("${CMAKE_CURRENT_SOURCE_DIR}/ios/Info.plist.in" "${_plist}" @ONLY)
  set_target_properties(${target} PROPERTIES
    OUTPUT_NAME "${bundle_name}"
    MACOSX_BUNDLE TRUE
    MACOSX_BUNDLE_INFO_PLIST "${_plist}"
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "${bundle_id}")
endfunction()

# --- Third-party notices inside the built bundle ---------------------------------
# Doc 35 requires the shipped app to carry the notice texts offline, together with a
# resource list generated from what was actually placed. Putting that step in the
# build is what makes `verify-notices.sh --require-bundle` mean something: the bundle
# either carries the files or the build fails. The repository root is derived from
# this file rather than passed in, so a direct cmake invocation gets the same wiring
# as scripts/native/build.sh.
get_filename_component(BALLPAD_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)
set(BALLPAD_NOTICE_MANIFEST
    "${BALLPAD_ROOT}/docs/native-strikers-dependency-manifest.json"
    CACHE FILEPATH "Dependency inventory shipped to the app for offline About/Credits")
set(BALLPAD_NOTICE_SCRIPT "${BALLPAD_ROOT}/scripts/native/lib/notice_resources.py")

# python3 is a host tool, so its search must ignore the iOS root path; finding a
# target-platform interpreter here would be nonsense. /usr/bin/python3 is the
# fallback because it is the interpreter every macOS with developer tools has.
find_program(BALLPAD_PYTHON3 NAMES python3 NO_CMAKE_FIND_ROOT_PATH)
if(NOT BALLPAD_PYTHON3)
  set(BALLPAD_PYTHON3 "/usr/bin/python3")
endif()

function(ballpad_bundle_notices target)
  if(NOT EXISTS "${BALLPAD_NOTICE_SCRIPT}")
    message(FATAL_ERROR "the notices assembler is missing: ${BALLPAD_NOTICE_SCRIPT}")
  endif()
  if(NOT EXISTS "${BALLPAD_NOTICE_MANIFEST}")
    message(FATAL_ERROR "the dependency manifest is missing: ${BALLPAD_NOTICE_MANIFEST}")
  endif()
  # add_custom_command(TARGET ...) only accepts a target created in the same directory,
  # and this app's `strikers` target belongs to the port's own add_subdirectory(). A
  # custom target ordered after it is the supported equivalent here, and it is the better
  # fit anyway: a custom target is rebuilt on every build, so a relinked bundle can never
  # end up without its notices, whereas a stamp file would go stale.
  add_custom_target("${target}_notices" ALL
    COMMAND "${BALLPAD_PYTHON3}" "${BALLPAD_NOTICE_SCRIPT}"
            --repo-root "${BALLPAD_ROOT}"
            --manifest "${BALLPAD_NOTICE_MANIFEST}"
            --bundle "$<TARGET_BUNDLE_DIR:${target}>"
            --platform "${BALLPAD_PLATFORM}"
    COMMENT "ballpad: placing third-party notices in the ${target} bundle"
    VERBATIM)
  add_dependencies("${target}_notices" "${target}")
endfunction()

# The bundle identifier is the one the existing Ballpad target already uses, so the ported app
# keeps the project identity.
# The display name is the product's name and nothing more: the operator's product is BallPad, and
# "BallPad Strikers" was a port-era label that showed up on the home screen, in the menu header, in
# the About surface and in this app's folder in Files. It is spelled the way the interface already
# spells it -- every string the player reads in the port (`Import from BallPad Folder`, `BallPad's
# map`, `BallPad's frame rate limit`) uses this one form, so the name on the home screen does too.
# The bundle and executable names stay as they are -- they are what the build scripts, the Simulator
# runner and the acceptance suite address.
ballpad_ios_bundle(strikers "${BALLPAD_APP_NAME}" "com.ballpad.strikers" "BallPad")
ballpad_bundle_notices(strikers)

add_custom_target(strikers_icon ALL
  COMMAND "${BALLPAD_PYTHON3}" "${BALLPAD_ROOT}/scripts/native/lib/app_icon.py"
          --assets "${CMAKE_CURRENT_SOURCE_DIR}/ios/Assets.xcassets"
          --bundle "$<TARGET_BUNDLE_DIR:strikers>"
          --platform "${BALLPAD_PLATFORM}"
          --minimum-os "${BALLPAD_MIN_OS}"
  COMMENT "ballpad: compiling the iPhone and iPad app icon"
  VERBATIM)
add_dependencies(strikers_icon strikers)

# ── The dependency probe ──────────────────────────────────────────────────────
# BallpadProbe is the cheap half of the N2 gate: it brings up SDL3, Dawn/Metal and a presentable
# swapchain and exits, so a broken Simulator dependency is diagnosed in seconds instead of
# through a full game boot. It links the same Aurora targets as the game and uses the same
# entry point, so what it proves about the entry path is what the game uses.
add_executable(ballpad_probe "${CMAKE_CURRENT_SOURCE_DIR}/probe/main.c")
target_link_libraries(ballpad_probe PRIVATE
  aurora::core aurora::gx aurora::gd aurora::vi aurora::pad aurora::si aurora::card aurora::main)
ballpad_ios_bundle(ballpad_probe "${BALLPAD_PROBE_NAME}" "com.ballpad.strikers.probe" "Ballpad Probe")

# ── Where the bundles ended up ────────────────────────────────────────────────
# The `strikers` target is created by the port's own add_subdirectory(), so CMake places its
# bundle in the port's binary directory rather than at the top of the build tree. Two consumers
# outside CMake need that path -- scripts/native/build.sh, which asserts the Mach-O platform
# after every build, and lib/test_runner.py, which installs the bundle into a Simulator -- so the
# configure step publishes it here instead of each of them guessing at an output layout. A
# generated file is the right home because the value is only known after generation, and
# TARGET_BUNDLE_DIR is the same expression the notices step above already relies on.
file(GENERATE OUTPUT "${CMAKE_BINARY_DIR}/ballpad-bundles.txt" CONTENT
"strikers=$<TARGET_BUNDLE_DIR:strikers>
probe=$<TARGET_BUNDLE_DIR:ballpad_probe>
")

message(STATUS "ballpad: iOS app ${BALLPAD_APP_NAME}.app for ${BALLPAD_PLATFORM}")
message(STATUS "ballpad: SDL3 ${BALLPAD_SDL3_ROOT}")
message(STATUS "ballpad: FFmpeg ${BALLPAD_FFMPEG_ROOT}")
message(STATUS "ballpad: Dawn provider ${AURORA_DAWN_PROVIDER} (ref ${AURORA_DAWN_REF})")
