# Agent instructions

## Releases paused

No public releases until this repo is marked Clear in the maintainer's private release audit. Do not publish, re-publish, or restore any release, IPA, APK, or macOS build, and do not add download links, until then.

Before any future public release, every artifact must pass `python3 ~/.codex/release-gate/release_gate.py <artifact>` on the maintainer's machine. A failure is a stop, not a note.

## Local verification

Run `python3 -m unittest discover -s tests -p 'test_*.py' -v` on macOS with Xcode installed. Controller tests compile the shipping button translation and exercise the press recognizer with a UIKit test double; they do not validate UIKit event delivery on a device.

On iOS 26+, UIKit can deliver controller presses as keyboard navigation. With SDL's MFi reader disabled, SDL may convert Select into Return, which the engine binds to Start. Controller regression testing must cover this path without an open SDL virtual joystick, since `STRIKERS_FAKE_PAD=controller` opens one and masks the conversion.
