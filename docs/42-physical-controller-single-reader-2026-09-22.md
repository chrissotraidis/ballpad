# Physical controllers: one reader, one port — 2026-09-22

A player reported that with a DualSense paired to an iPhone the main menu worked but
every submenu did not: after choosing Grudge Match, both the A and the B button
behaved as B and the game returned to the main menu. This is the investigation, the
defect, the fix and the reading that shows the fix landed.

## What was wrong

The app had **two independent readers of the same physical controller**.

`mobile/interface/BallpadPhysicalControllers.mm` observes `GCController` and publishes
into `SunPadInputMixer`, which `PortHostUIPollPad` merges into the engine's pad once
per frame. That is BallPad's own input boundary and it is the one with the app's
GameCube map and the player's own remap behind it.

Aurora also initialises SDL's joystick and gamepad subsystems
(`extern/aurora/lib/input.cpp`, `SDL_Init(... SDL_INIT_JOYSTICK | SDL_INIT_GAMEPAD ...)`),
and on iOS SDL's MFi driver enumerates *the same* `GCController` objects. `PADRead`
then reads them on its own account, through Aurora's positional table, onto whichever
port SDL's player index handed them.

That was measured rather than inferred. With `STRIKERS_LOG_INPUT=1` and the app's own
scripted `GCVirtualController` (`STRIKERS_FAKE_PAD=controller`), a single scripted
press of A produced, in the engine's own four-port dump:

```
[pad] f=22 cat=0 err=0,0,0,-1 cur=0x0100,0x0000,0x0100,0x0000 prev0=0x0100 jp0=0x0100 jr0=0x0000
```

One press, two GameCube ports, three ports reporting a controller. Aurora had also
opened the simulator's own `Gamepad` and the port's `Strikers Test Pad`, so the run
shows every reader at once.

Three defects follow from the duplicate, and all three are things a player meets:

* **The two maps disagree.** This bridge binds the right shoulder to the GameCube R and
  the left shoulder to Z. Aurora's table binds the right shoulder to Z and the left to
  nothing. OR'ed together, one press of R1 presses both R and Z.
* **The front end counts pads.** `IChooseSide::UpdateForFE` and `IChooseCaptain::Update`
  iterate all four ports and branch on `IsConnected`, so a duplicate is a phantom second
  player in exactly the Grudge Match flow the report named.
* **Both readings land on one port and are OR'ed into one button mask.** Any disagreement
  about the A/B pair then puts both bits in the same frame, and every front-end screen
  that tests B before A resolves such a frame as B. `IChooseCaptain::Update` is one of
  them, and its B is `PopEntireStack()` followed by `Push(SCENE_MAIN_MENU, SCREEN_BACK)`.
  That is the whole of the report: at the main menu a frame carrying A and B resolves as
  A, so nothing looks wrong until there is a screen to go back from.

## The fix

`SDL_JOYSTICK_MFI=0` is written into the environment from a static initialiser in
`BallpadPhysicalControllers.mm`. `IOS_JoystickInit` then returns before it registers
anything, no `GCController` becomes an SDL gamepad, and Aurora has nothing to read. The
app's bridge is the only reader, which is what the design already claimed.

The environment rather than `SDL_SetHint` because SDL's joystick subsystem comes up
inside Aurora's start-up, before any hook of this app runs; a static initialiser is
reliably earlier, and SDL resolves an unset hint from the environment. Aurora's keyboard
bindings still hold port 0 open, which is the same thing that keeps the pad alive for
touch-only play, so the port the game reads is unchanged — only the second writer to it
is gone.

Two further controller defects were fixed alongside it, both in the same path:

* **A quick tap could be dropped entirely.** `valueChangedHandler` hopped to the main
  queue and *then* read the pad, so a press and release that both happened between two
  hops were never observed at all — the mixer had no rising edge to latch. The sample is
  now taken on GameController's own queue, at the moment of the event, and the finished
  plain struct is what crosses to the main thread.
* **A button held across a background could stick down forever.** GameController stops
  delivering while the app is away, so the release of a button held at the moment of
  backgrounding reached nobody and the bridge's last published state kept it down for the
  rest of the session. A stuck B is a front end that walks out of every screen it is
  given. The controller half of the mixer is now released on background
  (`-releaseHeldInput`) and re-read from the live pads on resume (`-resampleControllers`);
  `reconcileControllers` could not do the second job, because a controller configured
  before the app went away is still configured and is deliberately not re-configured.
* **The pad poll no longer depends on the overlay.** `PortHostUIPollPad` returned 0 while
  `s_overlay` was nil, which is what a lifecycle rebuild looks like. That dropped a
  physical controller's input for those frames, and because the mixer latches rising edges
  and only clears them when consumed, every press made in that window was held and then
  delivered at once on the first frame after the overlay came back.

## What the fix reads as

Same scenario, same build machinery, after the change:

```
[info] [aurora::input] Added controller 'Strikers Test Pad' (instance 4, vid 045e, pid 02fd, type 3)
[pad] f=22 cat=0 err=0,-1,-1,-1 cur=0x0100,0x0000,0x0000,0x0000 prev0=0x0100 jp0=0x0100 jr0=0x0000
```

One connected GameCube pad, one press, one port. The only SDL gamepad left is the port's
own virtual test pad, which exists only because `STRIKERS_FAKE_PAD` is set for the run and
is absent from any launch a player makes.

`scripts/native/f12-pad-summary.awk` over the same log returns every clause satisfied:

```
29 1 1 1 2 1 1 1 11 11 1 1 1 1 1 1 1 0
```

— 29 records, the app-side map at its default, one connect, the script's own pad in the
offered slot, both other pads named as displaced, offer equal to published on every
record, frames strictly increasing, step cadence intact, **all eleven press steps offered
and all eleven read back by the engine**, stick, C-stick and both analog triggers answered,
release and disconnect at rest, no engine bit outside the previous offer, nothing unread.

## What this does not fix

Local multiplayer with two physical controllers is still not wired. The port's host seam
carries one pad (`PortHostUIPollPad` fills a single `PortHostPad`, and
`PortUpdateSyntheticInput` sets the virtual status of port 0 only), so the bridge tracks a
second controller and logs the slot it took but has nowhere to offer it. Before this change
a second controller reached the engine only as the SDL duplicate of a *first* one, on a port
that also carried the first one's presses, so this is a limitation made visible rather than
a capability removed. Routing slots 1-3 needs a multi-pad host seam in the engine fork.

Controller rumble through SDL goes with the MFi driver. Aurora's device-haptics path
(`lib/device_ios.mm`) is unaffected, and nothing in BallPad drove controller rumble
deliberately, but a pad that used to buzz through `PADControlMotor` will not.

## Reproducing the reading

```
scripts/native/bootstrap.sh --platform simulator
scripts/native/build.sh --platform simulator --no-bootstrap
xcrun simctl install <udid> build/native/simulator-release/port/BallpadStrikers.app
SIMCTL_CHILD_STRIKERS_DATA=<your image> \
SIMCTL_CHILD_STRIKERS_LOG_INPUT=1 SIMCTL_CHILD_STRIKERS_LOG_CONTROLLER=1 \
SIMCTL_CHILD_STRIKERS_FAKE_PAD=controller \
xcrun simctl launch --console-pty <udid> com.ballpad.strikers
```

The `[pad]` lines are the engine's own four ports; the `controller:` lines are the
bridge's published state, the host's offer and the engine's pad on one line each.
