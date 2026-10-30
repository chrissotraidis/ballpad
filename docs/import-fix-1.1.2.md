# Import corrections in 1.1.2

Three concrete problems were found in the production importer:

- First-launch text told players to import an extracted `files` directory, but
  the fallback only discovers ISO and GCM images. The instructions now name the
  actual supported input.
- Fallback discovery used a string prefix to exclude `BallpadGameData`. This
  also hid legitimate images in sibling folders such as
  `BallpadGameData-backup`. Discovery now excludes the exact retained-store
  directory and its descendants.
- Copy-mode picker URLs remained in UIKit's Inbox after the retained copy was
  made or an invalid image was rejected. The fallback could list these old
  Inbox images as new inputs. Discovery now skips Inbox; the picker path
  removes only the selected regular file inside this app's exact
  `Documents/Inbox` or temporary `<bundle-id>-Inbox` directory. The manual
  folder route never invokes this cleanup.

The image validator, active-installation transaction, saves, and picker types
are unchanged. This does not establish a failure in every file provider or
reproduce the separate BellPad reporter's device.

## Regression evidence

`sh scripts/native/test-import-files.sh` runs the production Foundation helpers
against synthetic files. Its eight checks cover legitimate nested and
same-prefix folders, retained-store and Inbox exclusion, uppercase extensions,
symbolic links, both UIKit copy locations, another app's Inbox name, and
preservation of manual/external originals and retained data. All eight pass.
The old production discovery implementation fails the same fallback fixture.

The existing nine Python tests also pass with
`python3 -m unittest discover -s tests -p 'test_*.py'`.

These are local source/transaction checks. A release additionally requires the
clean PadMint build before tagging, the published-route check afterwards, and
the private artifact gate. They do not certify physical-device gameplay or
every cloud file provider.
