# Strikers v1.3.0 integration — 2026-09-23

BallPad build 7 uses upstream `new-coke/strikers` v1.3.0 at
`b0e54c9a51cbfcfef7e5487feb02f843ff723d97`. The iOS integration and
host pause work from PR #4 are rebased as three commits in the maintained
`chrissotraidis/strikers` fork, ending at
`c4ee7189e7f9193be6ec7cedd569a17f25266136` (tree
`c64813ea6117428a345477edc543fe56e94d5f3f`). Both the build script and
dependency manifest pin this exact commit.

The upstream range adds fixes for AI pass selection, goal replay hangs, and
controller sampling with VSync. It also adds desktop and Switch features.
BallPad retains its own iOS controller bridge, disc importer, and UI pause
hooks; the upstream desktop settings app and Switch and texture-pack controls
are not exposed in this iOS build.

Rebasing the iOS commits needed manual merges in CMake flags, the script
question cache, match benchmarking, DVD headers, host pad input, render scale,
and launch code. The upstream cache key fix was kept with BallPad's MSL map
comparator. The host pad contribution was kept with upstream's neutral-pad
rule for the debug menu. The benchmark CSV carries both upstream input age
and BallPad's game phase columns.

`verify-clean.sh --scope source` checks the exact commit, source tree, clean
checkout, and v1.3.0 ancestry. Build 7 compiled for Simulator and device;
the macOS unit suite passed all 12 data-independent checks and the Simulator
Metal probe presented 90/90 frames. The controller mapping
panel UI test passed on a dedicated iPhone 17 Pro Simulator after its stale
expectations were updated to the current editable bridge map. These are
build and bounded UI evidence. The three-dot menu and frame-cap row also
passed their focused iPhone Simulator checks. The mapping rebind test passed
after following Controls and allowing the table to finish scrolling before
selecting Z; it verifies swap, persistence, and reset across fresh launches.
The `f04-live-match` Simulator scenario also passed: it reached a live match,
observed all 12 control masks in the engine's pad sample while moving the stick,
and saw the game's pause state after Start. Its controls are injected at the
engine's control channel, so this proves the game path rather than a physical
controller or real touch. Physical controller play and full gameplay acceptance
remain to be checked on the new build.
