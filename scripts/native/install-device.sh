#!/usr/bin/env bash
# Sign the device build with your own Apple account and install it on a connected iPhone or iPad.
#
# Use: scripts/native/install-device.sh [--device UDID] [--identity NAME] [--profile PATH]
#                                       [--app PATH] [--sign-only]
#
# Signing material comes from this Mac: the Apple Development certificate already in the login
# keychain and a provisioning profile Xcode has already downloaded. Nothing is uploaded, and no
# Apple account is contacted.
#
# The install is an in-place update whenever the bundle identifier and the signing team match the
# copy already on the device, so the app's container -- the imported disc image and the memory
# card -- is kept. A different team is not an update; iOS refuses it, and the way around that is to
# delete the app, which loses both. Export your memory card from inside the app before changing
# accounts.
#
# Build first:
#   scripts/native/build.sh --platform device

# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

APP="$(platform_build_dir device)/port/BallpadStrikers.app"
STAGING="${BUILD_ROOT}/device-signed"
FORWARD=()

while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP="$2"; shift 2 ;;
        --app=*) APP="${1#*=}"; shift ;;
        --staging) STAGING="$2"; shift 2 ;;
        --staging=*) STAGING="${1#*=}"; shift ;;
        --device|--identity|--profile) FORWARD+=("$1" "$2"); shift 2 ;;
        --device=*|--identity=*|--profile=*) FORWARD+=("$1"); shift ;;
        --sign-only) FORWARD+=("$1"); shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

require_cmd python3
require_cmd xcrun
require_cmd security
require_cmd codesign

[ -d "$APP" ] || die "no app bundle at ${APP}; run scripts/native/build.sh --platform device"

log "signing and installing $(basename "$APP")"
# The expansion is guarded because common.sh sets -u and the stock macOS bash treats an empty
# array's "${a[@]}" as unset, which is the ordinary case here: no options at all.
python3 "${BALLPAD_ROOT}/scripts/native/lib/install_device.py" \
    --app "$APP" --staging "$STAGING" ${FORWARD[@]+"${FORWARD[@]}"}
