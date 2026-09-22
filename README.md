# BallPad

<p align="center"><img src="mobile/ios/Assets.xcassets/AppIcon.appiconset/AppIcon.png" alt="BallPad geometric black-and-white soccer icon" width="128"></p>

<p align="center">
  <img alt="Configured iOS and iPadOS target 17+" src="https://img.shields.io/badge/iOS%20%2F%20iPadOS%20target-17%2B-0A84FF?logo=apple">
  <img alt="Native ARM64 game code" src="https://img.shields.io/badge/game%20code-native%20ARM64-FF9F0A">
  <img alt="Metal renderer" src="https://img.shields.io/badge/renderer-Metal-5E5CE6">
  <img alt="Experimental preview" src="https://img.shields.io/badge/preview-experimental-FFD60A">
  <img alt="Game data not included" src="https://img.shields.io/badge/game%20data-not%20included-FF453A">
  <a href="https://discord.gg/UwhfwXx4C"><img alt="Join the BallPad Discord" src="https://img.shields.io/badge/Discord-BallPad%20community-5865F2?logo=discord&amp;logoColor=white"></a>
</p>

**BallPad is an iOS/iPadOS port of [new-coke/strikers](https://github.com/new-coke/strikers).**
Play Super Mario Strikers on iPhone and iPad through the community native source port.
BallPad is an experimental Apple app with Metal rendering, GameCube touch controls,
physical controller support, and local game-data import.

Built on [new-coke/strikers](https://github.com/new-coke/strikers), the native desktop
port based on the [community decompilation](https://github.com/yannicksuter/smstrikers-decomp)
by Yannick Suter and contributors. [Aurora](https://github.com/encounter/aurora)
provides the platform and graphics layer, and
[SunPad](https://github.com/chrissotraidis/sunpad) provides the touch interface BallPad
adapts. See [full attribution](ATTRIBUTION.md) and [third-party notices](THIRD_PARTY_NOTICES.md).

BallPad is the Apple app repository. Its engine changes live in the maintained
[Strikers fork](https://github.com/chrissotraidis/strikers), built from
`new-coke/strikers` v1.1.1 with the upstream history preserved. Builds select an
exact fork commit; they do not apply a patch series. The
[dependency manifest](docs/native-strikers-dependency-manifest.json) records the
source relationships and exact versions. BallPad's work is the Apple integration,
touch adaptation, importer, mobile fixes, and build/test tooling.

You supply your own supported disc image. BallPad does not download or include
game images, extracted assets, or saves.

## Experimental preview

BallPad is under active development. Expect bugs and compatibility differences
between devices; performance, audio, and touch comfort are still being refined.
Download [**BallPad 1.0 Preview 1 (build 2)**](https://github.com/chrissotraidis/ballpad/releases/tag/v1.0-preview.1),
join the [community on Discord](https://discord.gg/UwhfwXx4C) for updates and testing
feedback, or [build from source](#build-from-source).

Installing on iPhone or iPad requires signing with your own Apple account. The
release IPA is unsigned; it is not a TestFlight or App Store build.
You must supply the supported game image yourself.

### Install the preview

1. Download [BallPad-unsigned.ipa](https://github.com/chrissotraidis/ballpad/releases/download/v1.0-preview.1/BallPad-unsigned.ipa)
   from the release. Use an iPhone or iPad running iOS/iPadOS 17 or later; the
   minimum OS setting has not been validated on every supported device.
2. Sign and install the IPA using your preferred sideloading tool and your own
   Apple account. For an update, keep the same signing account and application
   identity, export your memory card first, and install over the existing app.
3. Open BallPad and [import your supported ISO or GCM](#first-launch-and-game-data).

The release also includes `BallPad-sources.tar.gz`, `BallPad-FFmpeg-relink.tar.gz`,
and `SHA256SUMS`. Keep these matching source and relinking materials with the IPA
when redistributing it. To verify downloaded files on macOS, put all four assets
in one directory and run `shasum -a 256 -c SHA256SUMS` there.

## Current status

Version 1.0, build 6 moves the engine pin forward ten upstream commits — including a
crash and texture-cache rework and a goal-replay crash fix — and adds a pause the host
can ask for. Opening the menu now stops the game rather than slowing it: two new weak
hooks in the port (`PortHostUIWantsPause`, `PortHostUIIdle`) hold the game still, keep
the audio transport fed so music carries on, and hand the frame to the interface. The
same hooks pace the loop when there is no surface to draw into, which build 4 could only
contain from outside. The Experimental frame row is renamed **Lift the Port's Frame Cap**:
it was called "Uncapped Frame Rate" and measured at 170 fps uncapped against 59.9 capped,
which on this engine is the game running fast rather than drawing more — vsync is what
holds a phone at sixty, not the limiter. See the
[engine notes](docs/44-engine-rebase-and-pause-2026-09-22.md).

Version 1.0, build 4 makes the interface usable while the game is running. The port's
frame loop owns the main thread and SDL's pump hands UIKit two microseconds a frame,
so the three-dot menu was starved; and when the render surface was unavailable the
loop skipped the frame limiter and spun a core flat out, which is why the app stayed
unstable until it was backgrounded and brought back. The app now shares each frame
with UIKit, paces a loop nothing else is pacing, and does far less per-frame
diagnostic work. The three-dot button can also be hidden — **Controls ▸ Hide Menu
Button**, with a two-finger tap anywhere to bring it back. See the
[main-thread notes](docs/43-sharing-the-main-thread-2026-09-22.md).

Version 1.0, build 3 repairs physical controller input. One controller was reaching
the game twice — once through BallPad's own GameController bridge and once through
SDL's MFi driver, which Aurora reads on its own account — so the engine saw two
GameCube pads pressing every button. A frame carrying both A and B is resolved as B
by the front-end screens that test B first, which is why the main menu worked and
every submenu behaved as if B had been pressed. The app's bridge is now the only
reader. Build 3 also stops a quick tap being dropped between queue hops, stops a
button held across a background from sticking down, and keeps the pad polled while
the overlay is being rebuilt. See the
[controller notes](docs/42-physical-controller-single-reader-2026-09-22.md).

Build 2 refreshed the app icon, About & Credits, keyboard-aware problem reporting
and the FPS badge, added movie/scene diagnostics for rendering reports, and kept
imported game-data paths working when iOS relocates the app during an in-place
update.

Build 2 was installed and launched with game data on iPad Pro and iPhone 14, and
gameplay was tested on both. Build 3's controller repair is verified in the
Simulator against the engine's own pad read-back; it has not yet been played
through on hardware. Simulator checks cover the front end, a live match with
scoring and replay, memory-card screens, and focused controls/settings flows.
Sustained performance, multitouch behavior, and full-game validation remain work
in progress.

| Area | Current result |
| --- | --- |
| Game setup | Local import validates USA `G4QE01`, revision 0, raw ISO/GCM header and size |
| Rendering | Native engine with Metal presentation; render resolution and aspect-ratio settings |
| Controls | Floating movement stick, GameCube buttons, physical controller mapping, editable layouts |
| Saves | Sandboxed Slot A memory card, with import and export |
| Platforms | iPhone/iPad targets; configured iOS/iPadOS 17 minimum is not verified oldest-device compatibility |
| Status | Experimental; broader device testing and full-game validation remain in progress |

**Known issues:** intro movies and some stadium introductions have reported rendering
artifacts on hardware. Local multiplayer with two physical controllers is not wired:
the port's host seam carries a single pad, so a second controller is tracked and
logged but has nowhere to be offered. Controller rumble through SDL is gone with the
MFi driver that caused the duplicate-input defect. These remain open while testing
continues.

See the [controller notes](docs/42-physical-controller-single-reader-2026-09-22.md),
the [testing notes](docs/37-local-controls-2026-09-16.md) and
[development record](docs/36-native-strikers-progress.md) for tested behavior and
known limitations. Simulator results do not establish physical-device performance.

## Frequently asked questions

<details>
<summary><strong>Is this native recompilation or emulation?</strong></summary>

The active app builds reconstructed C/C++ game source from `new-coke/strikers`
into native ARM64 code. Aurora supplies platform and graphics support, with
Dawn's Metal backend. It does not use a runtime PowerPC JIT.

BallPad's active source-port engine differs from GalaxyPad's ahead-of-time
PowerPC recompilation and Dolphin-derived runtime. The older static-recompilation
experiment in `app/` and `host/` remains in this repository for history; it is not
the engine built by `scripts/native/`.

</details>

<details>
<summary><strong>Is the game included, and which version do I need?</strong></summary>

Supply your own lawfully obtained **Super Mario Strikers USA, `G4QE01`, revision 0**
raw ISO or GCM image. Its raw size is **1,459,978,240 bytes**. Other regions,
revisions, and compressed images are unsupported. Game data is never downloaded
or bundled by BallPad.

The executable builds reconstructed game code from the upstream source port;
that is separate from the disc image and assets supplied at first launch.
See [rights-status limitations](ATTRIBUTION.md#rights-status-limitations).

</details>

<details>
<summary><strong>Does it run at 60 FPS?</strong></summary>

The FPS badge is a live diagnostic reading, not a sustained-performance promise.
Performance varies with the scene and device. Sustained iPad frame rates, thermals,
audio quality, and battery use still need broader testing.

</details>

<details>
<summary><strong>Will updates preserve my save?</strong></summary>

Use an in-place update with the same application identity. Uninstalling the app
can remove local game data and saves. Export your memory card from the app's
menu before changing installation or signing boundaries. Imported game data is managed in the app sandbox. The active memory card is stored
in app support data; use the menu’s memory-card export to keep a portable backup.

</details>

<details>
<summary><strong>How can I report a problem?</strong></summary>

Open the three-dot menu → **Report a Problem**. Describe what happened and choose
**Continue**. BallPad saves a diagnostic log and prepares an issue
for [the BallPad repository](https://github.com/chrissotraidis/ballpad/issues).
Choose **Open GitHub**, review the draft, and manually attach the saved log from
**Files → BallPad → Diagnostics** before submitting. **Share Log…** also exports it.

The log includes build/device context, control settings, and bounded recent
runtime/interface logs, movie decoder details, and scene/stadium transitions.
Review it before sharing. Nothing is uploaded or
submitted automatically; never attach disc images, extracted assets, saves,
or signing material. A GitHub account is required to submit an issue.

Join the [BallPad community on Discord](https://discord.gg/UwhfwXx4C)
for discussion and testing feedback.

</details>

## Build from source

Engine changes are maintained directly in the pinned source fork. To make local
changes, commit them in your engine fork and update its URL, commit, and tree in
`scripts/native/common.sh` and the dependency manifest. The build verifies source
identity before compiling.

<details>
<summary><strong>Developer prerequisites and build commands</strong></summary>

Use an Apple Silicon Mac with Xcode 26.x or newer and its command-line tools, CMake,
Ninja, Git, Python 3.10+, and ripgrep. Keep your own supported game image in
ignored local storage. The [runbook](docs/33-native-strikers-implementation.md)
and [dependency manifest](docs/native-strikers-dependency-manifest.json) record
the engine and dependency pins. Preview 1 was built with Xcode 27.0; its device
and Simulator targets retain the iOS/iPadOS 17 deployment minimum.

From the repository root, bootstrap the pinned engine and dependencies, then
build the Simulator app:

```sh
scripts/native/bootstrap.sh --platform simulator
scripts/native/build.sh --platform simulator
```

Install and launch on an already-booted Simulator:

```sh
xcrun simctl install booted build/native/simulator-release/port/BallpadStrikers.app
xcrun simctl launch booted com.ballpad.strikers
```

For a device build, run bootstrap and build with `--platform device`. That
produces an unsigned app. A Simulator bundle cannot be installed on an iPad.

To sign that app with your own Apple account and install it on a connected
iPhone or iPad:

```sh
scripts/native/build.sh --platform device
scripts/native/install-device.sh
```

The device must be plugged in, unlocked, paired, and have Developer Mode on
(Settings > Privacy & Security > Developer Mode). Signing material is whatever
this Mac already has: the Apple Development certificate in the login keychain
and a provisioning profile Xcode has downloaded that covers the device. Nothing
is uploaded and no Apple account is contacted. Pass `--device`, `--identity` or
`--profile` when more than one is available, and `--sign-only` to stop before
installing.

Installing over an existing copy is an in-place update, so the app's container —
the imported disc image and the memory card — is kept. iOS keys that on the
`application-identifier` entitlement rather than the bundle identifier, so a copy
signed earlier by another tool can carry a string this script would not have
chosen; the installer names it in its refusal and the script re-signs with it and
retries once. If it still refuses, the copy on the device belongs to a different
team: export your memory card from inside the app, delete BallPad, and run it
again.

Bootstrap fetches the maintained engine fork into ignored `work/native/strikers`
and checks out the exact manifest revision. Engine changes belong in the maintained
fork; update the manifest pin after committing them there. Upstream authorship and
notices remain intact.
Do not commit `build/`, `work/`, `ref/`, or `.local-assets/`.

</details>

## First launch and game data

1. Launch BallPad to open **Add your game**.
2. Choose **Choose ISO or GCM** and select your supported image, or place it in
   BallPad's Files folder and choose **Import from BallPad Folder**.
3. Keep BallPad open while it copies and validates the image.
4. Choose **Start the Game** when the data is ready.

Wrong game codes, revisions, headers, and sizes are rejected without replacing
existing valid data. Use **Game Data** in the menu to manage the image later;
memory-card import/export is separate. Do not erase the app container to fix a
launch problem.

For local scripted Simulator scenarios, `SIMCTL_CHILD_STRIKERS_DATA` can point
to a private image path. This development route does not bundle that image.

## Controls and the three-dot menu

The touch overlay adapts SunPad's GameCube controls and native menu. BallPad's
changes live alongside the unmodified vendored reference.

- **Movement:** touch the lower-left movement area to place the stick at your
  thumb. It is invisible at rest and disappears on release.
- **GameCube buttons:** D-pad and L on the left; C-stick, A/B/X/Y, Z, R, and Start
  on the right. Touch shoulders provide analog pressure and the digital click.
- **Controls:** controller button mapping, touch visibility, and touch settings.
  Touch and physical-controller input can be used together.
- **Touch Control Settings → Move controls:** drag a control, select it to change
  its size or visibility, then choose **Done**. Phone and iPad layouts are stored
  separately. Reset restores the current device's layout.
- **Display:** FPS counter, render resolution, and aspect ratio. The experimental
  frame-rate limiter is separate from these display settings.
- **Game data, memory card, diagnostics, and About & Credits** are available
  from the same menu. Credits and license texts are bundled for offline viewing.

If a layout is uncomfortable or an input behaves incorrectly, include your device,
controller model, and reproduction steps in a report. Touch and controller feedback
helps improve the defaults.

## Validation

```sh
scripts/native/test.sh --suite unit
scripts/native/verify-notices.sh --inventory-only --final
scripts/native/verify-notices.sh --final --require-bundle
scripts/native/verify-clean.sh --scope all
```

Simulator checks include `scripts/native/test.sh --suite acceptance --device <UDID>`
and `scripts/native/run-uitests.sh --run-id <id> --device <UDID> --form-factor pad`.
Scenario and UI runs record evidence under ignored `build/proofs/native-strikers/`.
See the [acceptance specification](docs/34-native-strikers-acceptance.md) for what
each check establishes. Passing checks does not prove full-game or device readiness.

## Project map

| Path | Purpose |
| --- | --- |
| `mobile/` | Apple app, engine bridge, touch adapter, importer, and credits |
| `mobile/interface/sunpad/` | Unmodified SunPad interface with source revision and hashes |
| [Maintained Strikers fork](https://github.com/chrissotraidis/strikers) | Native engine with committed iOS/iPadOS adaptations |
| `scripts/native/`, `tests/native/` | Build, reproduction, audit, scenario, and UI tools |
| `notices/`, `ATTRIBUTION.md` | Upstream notices and contribution boundaries |
| `docs/` | Runbook, evidence, dependency manifest, and release readiness |
| `app/`, `host/` | Superseded static-recompilation experiment |
| `work/`, `build/`, `ref/`, `.local-assets/` | Ignored local sources, builds, evidence, and private game data |

## Credits, legal and contributing

BallPad builds on **new-coke/strikers**, **Yannick Suter and the Strikers
decompilation contributors**, **Aurora/Dawn**, **SDL**, **FFmpeg**, **SunPad**, and
their dependencies. Preserve their authorship and notices when adapting code.
The [manifest](docs/native-strikers-dependency-manifest.json),
[attribution](ATTRIBUTION.md), and [notice inventory](THIRD_PARTY_NOTICES.md)
identify their exact roles, revisions, and license status.

BallPad's original code is [GPL-3.0-only](LICENSE); see [license scope](LICENSE-SCOPE.md)
for inherited material. SunPad's interface retains its GPL-3.0 license. Static FFmpeg linkage also requires the applicable
relinking and corresponding-source material to accompany distribution. Upstream's
CC0 offer covers its author's own material within their rights; it does not
clear reconstructed game code or other third-party material.

This is unofficial and unaffiliated with Nintendo or Next Level Games. Their
game and trademarks belong to their respective owners. BallPad grants no rights
to redistribute game images or assets. See [attribution and rights status](ATTRIBUTION.md)
for the scope of upstream licenses and reconstructed material.

Keep contributions small, preserve upstream notices, commit engine changes in
the maintained fork, and record visible results and remaining failures. Never commit
game images, extracted assets, generated game code, saves, signing material, or
private runtime evidence.

## Package an IPA

After building the device target and committing the exact app source, run:

```sh
scripts/native/package-release.sh --out build/releases/ballpad-preview-1 --source-ref HEAD
```

This creates an unsigned IPA, source-material archive, portable FFmpeg relink
archive, and `SHA256SUMS`. Keep those materials together when distributing a
build. The packager verifies the engine pin and exercises relinking with the
recipient’s Xcode paths. It does not upload anything or include game data.
