#!/usr/bin/env python3
"""Sign the device build with a local Apple account and install it on a connected device.

Nothing here talks to Apple. It uses the signing identity already in the login keychain and a
provisioning profile Xcode has already downloaded, which is what "sign with your own Apple account"
means on a machine that has opened Xcode once. Game data is never touched: the app's container --
the imported disc and the memory card -- survives an in-place update, and an in-place update is what
this does as long as the bundle identifier and the signing team match the copy already installed.
"""

import argparse
import json
import plistlib
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

PROFILE_DIRS = [
    Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles',
    Path.home() / 'Library/MobileDevice/Provisioning Profiles',
]


def die(message):
    print('error: ' + message, file=sys.stderr)
    raise SystemExit(1)


def run(*command, **kwargs):
    return subprocess.run(command, capture_output=True, text=True, **kwargs)


def physical_devices():
    """Every paired, physical device devicectl can see, newest connection first."""
    result = run('xcrun', 'devicectl', 'list', 'devices', '--json-output', '/dev/stdout', '--quiet')
    if result.returncode != 0:
        die('devicectl could not list devices:\n' + (result.stderr or result.stdout))
    # --quiet still prints a human table before the JSON on some Xcode versions; take the object.
    start = result.stdout.find('{')
    if start < 0:
        die('devicectl produced no JSON')
    try:
        payload = json.loads(result.stdout[start:])
    except json.JSONDecodeError as error:
        die('devicectl JSON could not be read: %s' % error)
    found = []
    for device in payload.get('result', {}).get('devices', []):
        hardware = device.get('hardwareProperties', {})
        properties = device.get('deviceProperties', {})
        connection = device.get('connectionProperties', {})
        if hardware.get('reality') != 'physical':
            continue
        if connection.get('pairingState') != 'paired':
            continue
        found.append({
            'udid': hardware.get('udid') or device.get('identifier'),
            'name': properties.get('name', 'unknown'),
            'model': hardware.get('marketingName', hardware.get('productType', 'unknown')),
            'os': properties.get('osVersionNumber', '?'),
            'developer_mode': properties.get('developerModeStatus', 'unknown'),
        })
    return found


def resolve_device(requested):
    devices = physical_devices()
    if requested:
        for device in devices:
            if device['udid'] == requested:
                return device
        die('no paired physical device with UDID %s; devicectl sees %s'
            % (requested, ', '.join(d['udid'] for d in devices) or 'none'))
    if not devices:
        die('no paired physical device is connected. Plug the iPhone or iPad in, unlock it, and '
            'trust this Mac.')
    if len(devices) > 1:
        die('more than one device is connected; pass --device with one of:\n  '
            + '\n  '.join('%s  %s (%s)' % (d['udid'], d['name'], d['model']) for d in devices))
    return devices[0]


def signing_identities():
    result = run('security', 'find-identity', '-v', '-p', 'codesigning')
    rows = []
    for line in result.stdout.splitlines():
        match = re.match(r'\s*\d+\)\s+([0-9A-F]{40})\s+"(.+)"\s*$', line)
        if match:
            rows.append((match.group(1), match.group(2)))
    return rows


def resolve_identity(requested):
    rows = signing_identities()
    if not rows:
        die('no code-signing identity in the keychain. Open Xcode > Settings > Accounts, add your '
            'Apple ID, and let it create an Apple Development certificate.')
    if requested:
        for sha1, name in rows:
            if requested in (sha1, name):
                return sha1, name
        die('no signing identity matching %r; the keychain has:\n  %s'
            % (requested, '\n  '.join('%s  %s' % row for row in rows)))
    development = [row for row in rows if row[1].startswith('Apple Development')]
    pool = development or rows
    if len(pool) > 1:
        die('more than one signing identity; pass --identity with one of:\n  '
            + '\n  '.join('%s  %s' % row for row in pool))
    return pool[0]


def read_profile(path):
    decoded = run('security', 'cms', '-D', '-i', str(path))
    if decoded.returncode != 0 or not decoded.stdout:
        return None
    try:
        return plistlib.loads(decoded.stdout.encode('utf-8', 'surrogateescape'))
    except Exception:
        return None


def profile_covers(profile, bundle_id, udid):
    """True when this profile can sign `bundle_id` for `udid`, with how specific the match is."""
    entitlements = profile.get('Entitlements', {})
    app_id = entitlements.get('application-identifier', '')
    team = entitlements.get('com.apple.developer.team-identifier') or (profile.get('TeamIdentifier') or [''])[0]
    if not app_id or not team or not app_id.startswith(team + '.'):
        return None
    pattern = app_id[len(team) + 1:]
    if pattern == bundle_id:
        specificity = 2
    elif pattern == '*' or (pattern.endswith('.*') and bundle_id.startswith(pattern[:-1])):
        specificity = 1
    else:
        return None
    expires = profile.get('ExpirationDate')
    if isinstance(expires, datetime):
        when = expires if expires.tzinfo else expires.replace(tzinfo=timezone.utc)
        if when <= datetime.now(timezone.utc):
            return None
    provisioned = profile.get('ProvisionedDevices')
    # A profile with no device list is a distribution profile; it cannot install on a device here.
    if not provisioned or udid not in provisioned:
        return None
    return specificity, expires, team


def resolve_profile(requested, bundle_id, udid):
    if requested:
        path = Path(requested).expanduser()
        profile = read_profile(path)
        if profile is None:
            die('%s is not a readable provisioning profile' % path)
        match = profile_covers(profile, bundle_id, udid)
        if match is None:
            die('%s does not cover %s on device %s (wrong app id, expired, or the device is not in '
                'it)' % (path, bundle_id, udid))
        return path, profile, match[2]

    candidates = []
    for directory in PROFILE_DIRS:
        for path in sorted(directory.glob('*.mobileprovision')) if directory.is_dir() else []:
            profile = read_profile(path)
            if profile is None:
                continue
            match = profile_covers(profile, bundle_id, udid)
            if match is not None:
                candidates.append((match[0], match[1], path, profile, match[2]))
    if not candidates:
        die('no provisioning profile covers %s on this device.\n'
            'Open any project in Xcode once with your Apple ID signed in and this device selected, '
            'so Xcode downloads a team profile, then run this again.' % bundle_id)
    candidates.sort(key=lambda row: (row[0], row[1] or datetime.min.replace(tzinfo=timezone.utc)),
                    reverse=True)
    _, _, path, profile, team = candidates[0]
    return path, profile, team


def entitlements_for(profile, team, bundle_id, app_identifier=None):
    """The profile's entitlements with every team wildcard resolved to this bundle identifier."""
    source = dict(profile.get('Entitlements', {}))
    application_identifier = app_identifier or '%s.%s' % (team, bundle_id)
    resolved = {}
    for key, value in source.items():
        if key == 'application-identifier':
            resolved[key] = application_identifier
        elif key == 'keychain-access-groups':
            resolved[key] = [application_identifier if item == '%s.*' % team else item
                             for item in value]
        else:
            resolved[key] = value
    resolved.setdefault('com.apple.developer.team-identifier', team)
    return resolved


def profile_allows(profile, team, application_identifier):
    """True when the profile's own app-id pattern still covers `application_identifier`."""
    pattern = profile.get('Entitlements', {}).get('application-identifier', '')
    if pattern == application_identifier:
        return True
    return pattern.endswith('*') and application_identifier.startswith(pattern[:-1])


# iOS keys an upgrade on the application-identifier entitlement, not on the bundle identifier, and
# refuses to replace an app whose string differs. A copy signed by another tool can carry a string
# this script would not have chosen -- Sideloadly and friends register an App ID with the team
# appended -- and the refusal names it. Matching it is what makes the install an upgrade that keeps
# the container, which is where the imported disc image and the memory card live; the alternative is
# deleting the app and losing both.
INSTALLED_IDENTIFIER = re.compile(
    r"installed application's application-identifier string \(([^)]+)\)")


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--app', type=Path, required=True, help='the unsigned .app to install')
    parser.add_argument('--staging', type=Path, required=True,
                        help='where the signed copy is written; replaced on every run')
    parser.add_argument('--device', help='device UDID; the only connected one by default')
    parser.add_argument('--identity', help='signing identity name or SHA-1; the only Apple '
                                           'Development one by default')
    parser.add_argument('--profile', help='a .mobileprovision to embed; chosen automatically by '
                                          'default')
    parser.add_argument('--sign-only', action='store_true', help='stop after signing')
    parser.add_argument('--app-identifier',
                        help='application-identifier entitlement to sign with, when it has to '
                             'match a copy already installed; discovered from the installer\'s own '
                             'refusal by default')
    args = parser.parse_args()

    app = args.app.resolve()
    if not (app / 'Info.plist').is_file():
        die('%s is not an app bundle. Build it first:\n'
            '  scripts/native/build.sh --platform device' % app)
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    bundle_id = info['CFBundleIdentifier']

    device = resolve_device(args.device)
    if device['developer_mode'] not in ('enabled', 'unknown'):
        die('Developer Mode is %s on %s. Turn it on in Settings > Privacy & Security > Developer '
            'Mode and reboot the device.' % (device['developer_mode'], device['name']))
    sha1, identity_name = resolve_identity(args.identity)
    profile_path, profile, team = resolve_profile(args.profile, bundle_id, device['udid'])

    print('device    %s  %s (%s, iOS %s)' % (device['udid'], device['name'], device['model'],
                                             device['os']))
    print('app       %s %s (build %s) %s' % (bundle_id, info.get('CFBundleShortVersionString', '?'),
                                             info.get('CFBundleVersion', '?'), app))
    print('identity  %s' % identity_name)
    print('profile   %s  [%s]' % (profile.get('Name', '?'), profile_path.name))
    print('team      %s' % team)

    staging = args.staging.resolve()
    signed = staging / app.name
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    entitlements = staging / 'entitlements.plist'

    # Every attempt starts from the build's own bundle rather than re-signing the previous attempt.
    # A second pass over an already-signed copy is the one that fails with "resource fork, Finder
    # information, or similar detritus not allowed", and on a Mac whose Documents folder is synced
    # the extended attributes come back on their own between passes -- so the cheap copy is worth
    # more than the state it removes. ditto drops resource forks, extended attributes and ACLs as it
    # goes, and the xattr sweep covers anything re-applied while the copy was being made.
    def sign(application_identifier):
        if signed.exists():
            shutil.rmtree(signed)
        copied = run('ditto', '--norsrc', '--noextattr', '--noacl', str(app), str(signed))
        if copied.returncode != 0:
            die('could not stage the bundle:\n' + (copied.stderr or copied.stdout))
        (signed / 'embedded.mobileprovision').write_bytes(profile_path.read_bytes())
        entitlements.write_bytes(
            plistlib.dumps(entitlements_for(profile, team, bundle_id, application_identifier)))
        run('xattr', '-cr', str(signed))
        result = run('codesign', '--force', '--sign', sha1, '--entitlements', str(entitlements),
                     '--timestamp=none', '--generate-entitlement-der', str(signed))
        if result.returncode != 0:
            die('codesign failed:\n' + (result.stderr or result.stdout))
        # Again before the check, because an attribute put back between the two is enough to fail a
        # signature that is otherwise sound. See the staging note in install-device.sh.
        run('xattr', '-cr', str(signed))
        verified = run('codesign', '--verify', '--strict', '--verbose=2', str(signed))
        if verified.returncode != 0:
            die('the signed bundle does not verify:\n' + (verified.stderr or verified.stdout))
        print('signed    %s  (app id %s)'
              % (signed, application_identifier or '%s.%s' % (team, bundle_id)))

    sign(args.app_identifier)

    if args.sign_only:
        return

    def install():
        return subprocess.run(['xcrun', 'devicectl', 'device', 'install', 'app',
                               '--device', device['udid'], str(signed)],
                              capture_output=True, text=True)

    result = install()
    # One retry, and only for the one refusal that has a non-destructive answer: the installer has
    # told us the application-identifier the installed copy carries, so signing with that string
    # makes this an upgrade that keeps the container instead of a fresh install that needs the app
    # deleted first. The retry is skipped when the caller named an identifier, and when the profile
    # would not cover the one the installer named.
    if result.returncode != 0 and args.app_identifier is None:
        match = INSTALLED_IDENTIFIER.search(result.stdout + result.stderr)
        if match and profile_allows(profile, team, match.group(1)):
            print('note      the installed copy carries application-identifier %s; re-signing with '
                  'it so this is an upgrade rather than a replacement' % match.group(1))
            sign(match.group(1))
            result = install()

    sys.stdout.write(result.stdout)
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        die('install failed. If it names a signing or identity mismatch this script could not '
            'match, the copy on the device was signed by a different team: export the memory card '
            'from inside the app first, delete BallPad on the device, then run this again.')
    print('installed on %s' % device['name'])


if __name__ == '__main__':
    main()
