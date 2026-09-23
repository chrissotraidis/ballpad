# Rebasing the engine, and a pause the host can ask for — 2026-09-22

This records build 6's PR state. Build 7 republished and rebased the engine
onto upstream v1.3.0; the current pin and verification are in
[the v1.3.0 integration notes](45-strikers-v1.3-integration-2026-09-23.md).

Three things, and the third is the one that changed a claim made in doc 43.

## The pin moved forward ten commits

The engine was pinned to `37c0ad9`, which is upstream `22649cb` (v1.1.1) plus BallPad's
two commits. Upstream had moved on, and what it had moved on *to* is directly relevant
to the artifacts in this repo's known-issues list:

* `4ba5dce` — "Fix crashes and improve Steam Deck pacing, rendering and profiling". A
  texture-cache rework in Aurora's `gx/texture.cpp` (+343), `gfx/texture.cpp`, the
  command processor, and new `gx_texture_cache_test` / `gx_fifo_test` suites.
* `0e44049` — "Fix a rare enough crash during goal replays at high frame rates".
* `21f006c` — Windows FFmpeg fixes, a goalie LOD fix at extreme resolutions.
* Six more, including a shader compilation stage and MUSYX output parameter types.

BallPad's two commits rebase onto `4ba5dce` with three conflicts, all resolved by keeping
both sides rather than choosing one:

| File | Upstream wanted | BallPad wanted | Resolution |
| --- | --- | --- | --- |
| `CMakeLists.txt` | `configure_file` for the macOS Info.plist | `if(APPLE AND NOT IOS)` | Both: the guard around the configure |
| `vi.c` | gamescope rate rounding | the NTSC field cap | Both, cap applied *after* the panel adjustments, so a display below the field keeps gamescope's exact rate or vsync's margin and only one above it is held back |
| `benchmark.c` | acquire/pipeline/draw/upload columns | the phase column | Both, merged into one CSV row |

## A pause the host can ask for

Doc 43 ended by saying a real pause would have to come from the engine. It does now.

```c
int  PortHostUIWantsPause(void);   // asked once a frame, after PortHostUIFrame
void PortHostUIIdle(double seconds);
```

Both are weak no-ops by default, so a desktop build links and behaves exactly as before.
While the host answers nonzero the port does not advance the game and does not draw; it
feeds the audio transport and hands the rest of the frame to `PortHostUIIdle`, whose
default sleeps and whose iOS implementation runs the run loop.

Feeding the audio is the part that makes this a pause rather than a freeze.
`salPortNextBuffer` advances MusyX by one 5 ms tick per buffer, so a paused frame that
still calls `PortAudioUpdate` keeps the music playing exactly as a console pause menu
leaves it. Both skip paths feed it now, which also stops a momentary loss of surface from
starving the device.

The same hook closes the defect doc 43 could only contain from outside. When
`aurora_begin_frame()` returned false the loop continued from the top, and the frame
limiter it skipped by continuing is inside `VIWaitForRetrace`, inside the task tree that
path skips — so the loop stopped being paced at all. It is paced at the source now, and
the app-side workaround (a 14 ms budget and a frame-counter heuristic) is gone.

## "Uncapped Frame Rate" was not inert, and doc 43's account of it was wrong

The row was reported as doing nothing: the rate stays at 60 either way. The first
explanation written here was that lifting the cap could not produce more frames. The
measurement says otherwise.

Same build, same device, twenty-second benchmark, `STRIKERS_BENCHMARK=1`:

| | limiter | measured |
| --- | --- | --- |
| Default | `59.94 Hz (display, capped at the field)` | 59.9 fps, steady |
| `STRIKERS_FPS_LIMIT=0` | `uncapped (STRIKERS_FPS_LIMIT)` | 122.9 → 172.5 → 170.6 fps |

One loop pass is one `VIWaitForRetrace` is one game frame, so 170 fps is not a smoother
sixty. It is the same game running close to three times its own speed, with the audio
transport still draining in real time underneath it.

So the row is not inert; it is *masked*. What holds the rate at sixty on a phone is
**vsync**, not the limiter — iOS paces an app to 60 Hz on a ProMotion display unless
`CADisableMinimumFrameDuration` is set. The row looks like it does nothing and is one
display setting away from running the game fast.

It is renamed rather than removed, because it does reach the limiter and
`S.r1.frame-limit-row` asserts exactly that and passes. **Lift the Port's Frame Cap** says
what the switch moves instead of what a player would hope it buys, and its alert names
what is really pacing the frames:

> The port's own limiter is now uncapped. The game advances one frame per pass of the
> loop, so lifting the cap does not add frames to a second — it lets the game run fast
> wherever nothing else paces the loop. Here the display reports 59.9 Hz and paces by
> vsync, and that is what is holding the rate.

Making the frame rate genuinely higher would mean decoupling the render from the
simulation, which this engine does not do anywhere: the task tree, the pad sample, the
audio clock and the retrace count are one clock.

## What was run

Five rows against the rebased engine, on an iPhone 17 Pro Simulator:

| Row | |
| --- | --- |
| `S.uitest.menu-order` | PASS 17.7s |
| `S.uitest.lifecycle-surface` | PASS 26.5s |
| `S.r1.display-readback` | PASS 52.0s |
| `S.r1.frame-limit-row` | PASS 36.2s |
| `S.uitest.settings-panel` | PASS 55.0s |

## Where the engine commit lives

The pin points at `pedroea0/strikers@9e1a9a9` on branch `ballpad-ios-rebase`, because the
maintained fork is not writable from here. **Before this can merge**, that commit needs
republishing in `chrissotraidis/strikers` and `ENGINE_URL` / `ENGINE_PIN` /
`ENGINE_SOURCE_TREE` / `UPSTREAM_PIN` / `ENGINE_BRANCH` in `scripts/native/common.sh`
repointing at it, along with the `engine_pin` block and the `strikers` component in
`docs/native-strikers-dependency-manifest.json`. The tree hash is
`a0e22501e34186e18947c9d0f341afb01d585c17`; `verify-clean.sh --scope source` checks all of
it and passes as configured.
