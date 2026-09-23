# Sharing the main thread with UIKit — 2026-09-22

A player reported that opening the three-dot menu froze the app and left it unstable
until they backgrounded it and came back. This is why, what was changed, and the
reading that shows it moved.

## Why the menu was unusable

The port's frame loop owns the main thread outright. `src/Game/main.cpp` runs
`while (s_portRunning && !PortQuitRequested())` and, on iOS, that loop is entered from
the scene delegate rather than from a run loop — so the only time UIKit gets is what
SDL's own pump hands it:

```c
/* SDL_uikitevents.m, UIKit_PumpEvents */
const CFTimeInterval seconds = 0.000002;
do { result = CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, TRUE); }
while (result == kCFRunLoopRunHandledSource);
```

Two microseconds, ending at the first source that has nothing left. That is enough for
a touch to be delivered and nowhere near enough for UIKit to run a menu: a presented
sheet lays out, animates and hit-tests on the same thread the game is holding, so it
arrives in stutters.

Underneath that sits the defect that turns a slow menu into an unresponsive app. When
`aurora_begin_frame()` returns false — no surface, not presentable, paused — the loop
does this:

```cpp
if (!aurora_begin_frame())
    continue;              // minimised or surface lost; nothing to draw
```

and the frame limiter it skips by continuing is **inside** `RunAllTasks`: `vi.c` sleeps
to an absolute deadline in `VIWaitForRetrace`. So the loop stops being paced at all and
spins a core flat out, doing nothing, for as long as the surface is unavailable. That is
both the heat and the "until I close and return to the app" — a foreground resume is
what rebuilds the surface and lets the loop pace itself again.

## What changed

### The frame is shared

`BallpadShareMainThread` runs once per frame, at the end of the host's own per-frame
work, and is the only thing the app can do from inside a hook the loop calls:

* **While something of this app's own is on screen**, it *waits* in the run loop for up
  to 14 ms, letting UIKit run. The wait is the point — a run loop polled with a zero
  timeout hands over only what is already queued, and UIKit's work arrives across the
  frame, on timers and on its own display link, not in a lump at the start of it.
* **Otherwise** it polls: whatever is already queued is handed over and the frame
  continues. A frame of ordinary play costs one poll of a run loop with nothing in it.
* **Either way** a floor guarantees a minimum of 5 ms between frames, spent waiting in
  the run loop rather than asleep. Ordinary play never reaches it — the limiter paces at
  ~60 Hz — so it only bites on the unpaced spin above, where it becomes the pacing and
  turns a burning core into idle time UIKit can use.

The 14 ms is bounded by the audio, not by taste. `PortAudioUpdate` tops the stream up to
`kTargetBuffers` (six of MusyX's own buffers, about 30 ms) once per frame, so a frame
interval that grows past that queue underruns the device. Fourteen milliseconds on top of
a frame the engine already spends keeps the whole frame inside it with margin, and is
several times what UIKit needs to animate a menu.

### Knowing when the app's own UI is up

Three sources, because UIKit puts these things in three different places:

* A presented view controller covers every sheet this app puts up — the mapping panel,
  credits, game data, an alert, a share sheet.
* The layout editor is the overlay's own mode rather than a presentation.
* A **`UIDeferredMenuElement`** covers the menu. The vendored button holds its menu in
  `_menuButton.menu`, a built object UIKit displays without calling back into the app, so
  `-buildMenu` running means a menu was rebuilt, not opened — and opened is the moment
  that matters. An uncached deferred element is the documented way to be called at that
  moment: UIKit asks its provider every time the menu is presented, and a provider that
  completes immediately with no elements adds no row and no delay.

Nothing tells the app when a menu closes, so the menu's claim is a generous deadline that
the sharing gives up early: two consecutive frames of a quiet run loop release it.

### The per-frame diagnostics got cheaper

These run on the thread the game runs on, every frame, in the shipping build:

| Reading | Was | Now |
| --- | --- | --- |
| `BallpadLogOverlayTouchIfSettled` | Formatted a string naming all 14 drawn controls every frame to decide whether anything had moved | Sampled at 10 Hz; the settle window is measured in time, so the same lines appear |
| `BallpadLogLayoutIfSettled` | The same shape, every frame | The same 10 Hz sampler |
| `BallpadLogShoulderOutlineIfChanged` | Two recursive walks of the drawn tree per frame, comparing an accessibility label at every node, to find the same two views | The two views are found once and held, keyed on the overlay so a rebuilt one re-derives them. Still sampled every frame, because a press is an edge |
| `BallpadRefreshFPSCounter` | Assigned `attributedText` every frame — a text layout pass and a committed transaction to redraw a number that had not changed — and rebuilt the placement signature every frame | Text assigned only when the reading changes (the card is drawn to whole frames a second); placement checked on the 10 Hz sampler |

### Hiding the menu button

The three-dot button is the only thing on screen for a whole match that is not part of
the game. **Controls ▸ Hide Menu Button** takes it away; a **two-finger tap anywhere**
brings it back for five seconds and then it fades out again.

Two fingers rather than a hot corner, because a corner is a place a thumb already goes —
the Start control sits in the top-left of the phone layout and the shoulder row runs
across the top. Two simultaneous touches are something the game's own controls never ask
for as a pair, and touches that land on a control are refused by the recogniser's
delegate, so pressing A and B together is not a reveal. The recogniser lives on the
window rather than on the overlay because the overlay's hit test passes empty space
through to the game, so a tap on nothing would never reach it; it observes rather than
consumes (`cancelsTouchesInView = NO`), so the game's controls keep every touch they
would have had.

The preference is BallPad's own key, `BallpadHideMenuButton`, and the settings read-back
names it — a report that says a row could not be reached should also say whether the
button was hidden.

## The reading

`scripts/native/run-uitests.sh --only testThreeDotMenuAdoptsTheVendoredRowsInOrder` taps
the three-dot button and walks every vendored row, page by page, asserting each is
reachable and in its vendored order. Same test, same device, same taps:

| Build | Result |
| --- | --- |
| Before | `S.uitest.menu-order PASS … passed in 26.8s` |
| After | `S.uitest.menu-order PASS … passed in 12.4s` |

Less than half the wall time for the same interactions, which is the menu no longer
waiting on the game loop between every tap. The row-order assertion still passes, so the
added row and the deferred element change nothing about what the menu publishes.

## Two stale acceptance rows found on the way

Both were failing before this work and were confirmed against the previous commit rather
than assumed, because "this failure is not mine" is the claim that is expensive to get
wrong.

### The display read-back had nowhere to be read from

`testDisplayRowsReachTheRenderer` parses the render target, scale, aspect, pin, logical
width and camera blend out of the FPS card's accessibility label. The card spelled that
reading out until build 2 reduced it to the rate (doc 37, "Reduced the FPS badge to FPS"),
and the card's text has been `[NSString stringWithFormat:@"%.0f fps", live.fps]` ever
since — so the row's regex has had nothing to match and the row has failed on every build
since. On this branch it fails in 33.6 s; on build 3 it fails in 34.9 s with the same
`last reading: none`.

The reading is published again, as the card's accessibility **value**. What the card draws
stays `60 fps` and what VoiceOver announces stays `60 fps`; the value is a second channel
that costs the player nothing and gives the row its reading back. The helper reads the
value and falls back to the label.

### The lifecycle row looked for a row behind a group

`testBackgroundAndForegroundKeepTheOverlay` was failing, and not because of this work. It
resumes the app and then asks for `Touch Control Settings…` with `scrollMenuForElement`,
which scrolls only the level it is given — and that row has lived inside the **Controls**
group since the menu was grouped in build 2. The helper on the very next line,
`openTouchSettings`, taps `Controls` first for exactly that reason.

The same test on build 3 fails the same assertion in 175.8 s, against 174.2 s here. The
assertion now asks for the group, which is what "the menu is open and populated after a
resume" actually means at that level; reaching the row behind it stays `openTouchSettings`'
job. With that fixed the row passes in 21.7 s rather than spending 175 s scrolling a menu
for something that was never at that level.

Doc 37 predicted this class of thing — "some older tests assert the retired debug panels
and always-visible stick and need to be updated before claiming the full suite again" —
and these are two of them.

## What this does not do

The engine still advances while a menu is open — it is slowed, not stopped. A true pause
would have to come from the engine: the port's loop has no hook for it, and the one path
that does stop the game (`aurora_begin_frame()` returning false) is the unpaced spin this
work exists to contain. Stopping `PortAudioUpdate` along with it would stall the audio
device rather than silence it.

The frame-limiter skip itself is still in the engine's loop. What is here is containment
from the app side: the loop can still reach that path, but it can no longer spin unpaced
when it does. The fix belongs in `src/Game/main.cpp` — pacing before the `continue` — and
that is an engine-fork change with a pin update behind it.
