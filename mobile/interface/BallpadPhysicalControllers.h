// The physical-controller half of Ballpad's input boundary (doc 36 R1 item 16, doc 34 F12).
//
// SunPad's own design puts a controller in one of the vendored mixer's two slots -- the mixer
// documents `fromTouch:NO` for exactly that -- and nothing in this app ever wrote it. This is the
// writer: it observes Apple's GameController connections, translates a `GCExtendedGamepad` sample
// into the vendored `SunPadInputState` vocabulary, and publishes the result through
// `SunPadInputMixer`, which is the same boundary the overlay's touch path uses and the same one
// `PortHostUIPollPad` reads once per frame. A physical pad therefore reaches the game through the
// identical route a finger does, rather than through a second input path that would have to be
// kept in agreement with the first.
//
// The file this mirrors is `apple/mobile/KartPadPhysicalControllers.{h,mm}` in the sibling project.
// Two of its decisions are deliberately not carried over, and both are stated where they are made
// below rather than left as a silent divergence: the right trigger's semantics, and the per-player
// button latch.

#ifndef BALLPAD_PHYSICAL_CONTROLLERS_H
#define BALLPAD_PHYSICAL_CONTROLLERS_H

#import <Foundation/Foundation.h>

#include <cstdint>

#import "SunPadControllerMapping.h"
#import "SunPadInputState.h"

NS_ASSUME_NONNULL_BEGIN

// One frame of a physical controller, in the vocabulary the vendored mapping table speaks: the four
// face buttons plus the left shoulder as `SunPadPhysicalControllerButton`, and every other element
// as itself. `leftTrigger`/`rightTrigger` are the analog lines at 0..1, which is what
// `GCExtendedGamepad` reports and what `SunPadInputState` scales to 0..255.
struct BallpadPhysicalControllerSample {
    SunPadPhysicalControllerButton faceButtons =
        static_cast<SunPadPhysicalControllerButton>(0);
    bool menu = false;
    bool dpadUp = false;
    bool dpadDown = false;
    bool dpadLeft = false;
    bool dpadRight = false;
    bool rightShoulder = false;
    float leftX = 0.0f;
    float leftY = 0.0f;
    float rightX = 0.0f;
    float rightY = 0.0f;
    float leftTrigger = 0.0f;
    float rightTrigger = 0.0f;
};

// The whole translation from a device sample to the state the mixer takes, with no Apple types in
// its signature. That is what makes it checkable on its own: the fault injector below builds the
// same struct a real controller produces, so the scripted and the physical paths differ only in who
// filled it in.
SunPadInputState BallpadAdaptPhysicalControllerSample(
    const BallpadPhysicalControllerSample& sample,
    SunPadControllerButtonMapping mapping) noexcept;

@interface BallpadPhysicalControllers : NSObject

+ (instancetype)sharedControllers;

// Idempotent, and safe to call from a lifecycle rebuild: `start` re-registers and re-reconciles,
// `stop` releases every slot and clears the mixer's controller half so a pad that was held as the
// app went away cannot survive into the next session.
- (void)start;
- (void)stop;

- (void)reconcileControllers;

// The two halves of a lifecycle cycle, and they exist because GameController stops delivering while
// the app is away. A button held as the app goes to the background has its release delivered to
// nobody, so without `releaseHeldInput` the bridge's last published state keeps that button down for
// the rest of the session -- and a stuck B is a front end that leaves every screen it is given.
// `resampleControllers` is the other side: it re-reads every pad the bridge already holds, so the
// state the game resumes on is what the sticks and buttons are doing now rather than the rest state
// the background left behind. `reconcileControllers` cannot do that job, because a controller that
// was configured before the app went away is still configured and is deliberately not re-configured.
- (void)releaseHeldInput;
- (void)resampleControllers;

// The bridge's own record of what it last published into each slot. Read rather than consumed:
// this app has one consumer and the vendored mixer already latches rising edges, so a second latch
// here would be a second place for an edge to be cleared and a second thing to keep in agreement
// with the first. KartPad's bridge keeps one because it feeds four players directly; this one
// publishes into the mixer and reads back what it published.
- (BOOL)readPlayer:(NSUInteger)player state:(SunPadInputState*)state;

// How many slots hold a controller. The interface's own controller-visibility rule asks
// GameController directly (see the vendored overlay), so this is the bridge's bookkeeping rather
// than a second answer to the same question.
- (NSUInteger)connectedControllerCount;

@end

// The scripted controller: a fault injector, not a feature.

// One property of the injector is carried by the bridge rather than by this class, and it is stated
// here because it is the one place the shipping path behaves differently when a script runs: while
// the script is running, the controller it holds is the one the bridge assigns slot 0, and any other
// controller in `GCController.controllers` is left unassigned and named in the log. The game reads
// port 0 and only port 0, so a scripted press that landed in a later slot would be a press nothing
// in the engine could read -- and the row that judges the boundary would be judging an absence.
//
// doc 34's F12 asks for the merge/connect/disconnect boundary to be *tested*, and a Simulator cannot
// be handed a physical pad. What it can be handed is the framework's own virtual controller, which
// is a real `GCController` in `GCController.controllers` that posts the real connect and disconnect
// notifications and drives the real `valueChangedHandler` -- so the code under test is the shipping
// bridge rather than a stub of it, and only the *hand* holding the pad is synthetic. The script is
// frame-counted rather than clocked, so the steps line up with the port's own frames and the
// evidence is deterministic. It runs only when `STRIKERS_FAKE_PAD` names a script, which no shipping
// path sets.
@interface BallpadScriptedController : NSObject

+ (instancetype)sharedScriptedController;

// NO when the environment names no script, which is every launch a player makes.
- (BOOL)startIfEnabled;
- (void)stop;

// One port frame's worth of script. Called from the adapter's frame hook so the steps are counted in
// the same frames the engine runs in.
- (void)advanceFrame;

- (BOOL)isRunning;
- (nullable NSString*)scriptName;
- (const char*)currentStepName;

// The process-local instance ID of the virtual controller, or 0 before the framework hands it over.
// The bridge uses it to tell the script's own pad from a controller the script displaced.
- (uintptr_t)controllerInstanceID;

@end

NS_ASSUME_NONNULL_END

#endif // BALLPAD_PHYSICAL_CONTROLLERS_H
