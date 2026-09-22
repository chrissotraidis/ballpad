// Ballpad's physical-controller bridge. The design notes are in BallpadPhysicalControllers.h.

#import "BallpadPhysicalControllers.h"

#import "BallpadLog.h"
#import "SunPadControllerSlots.h"
#import "SunPadInputMixer.h"

#import <GameController/GameController.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <mutex>
#include <string>
#include <stdlib.h>
#include <string.h>
#include <vector>

namespace {

// The pressure at which a physical trigger counts as a *press* of the GameCube shoulder rather
// than only as analog travel.
//
// The number is the port's own, not a taste: PADClampCircle holds a trigger to a minimum of 30 and
// clamps anything at or below it to zero, so 30 is the line the engine itself draws between "this
// trigger is being held" and "this trigger is at rest". Taking the same line means the digital bit
// and the analog value the engine keeps can never disagree about whether a shoulder is down: at 31
// the pad carries both, and at 29 it carries neither.
//
// This is deliberately not the vendored `SunPadControllerRightTriggerPressure`. That helper exists
// for Mario Sunshine, where a digital shoulder stands in for a partially pulled spray nozzle and is
// therefore reported as at least half pressure. Strikers has no pressure gameplay -- R is a
// GameCube shoulder button -- so borrowing that rule would make a digital press read as a
// half-pulled analog trigger in the engine's own read-back, which is a claim about the pad that
// nothing on the pad did.
constexpr uint8_t kBallpadTriggerPressThreshold = 30;

// This bridge is the *only* reader of a physical controller on iOS, and this is what makes that
// true rather than merely intended.
//
// SDL's own MFi joystick driver enumerates the very same `GCController` objects this file observes,
// and Aurora then reads them into the engine's pad on its own account (`PADRead`, in
// extern/aurora/lib/dolphin/pad/pad.cpp). With both readers live, one controller reaches the game
// twice: once through this bridge -- the app's map, the player's own remap, the same mixer a finger
// uses -- and once through Aurora's positional map, on whichever port SDL's player index happened
// to hand it. That was measured rather than assumed: a single scripted press landed as
// `cur=0x0100,0x0000,0x0100,0x0000` in the engine's own four-port pad dump, one press on two ports.
//
// Three things follow from it, and all three are defects a player meets.
//   * The maps disagree. This bridge binds the right shoulder to the GameCube R and the left
//     shoulder to Z; Aurora's table binds the right shoulder to Z and the left to nothing. OR'ed
//     together, one press of R1 presses both R and Z.
//   * The front end counts pads. `IChooseSide::UpdateForFE` and `IChooseCaptain::Update` iterate all
//     four ports and branch on `IsConnected`, so a duplicate is a phantom second player in exactly
//     the Grudge Match flow.
//   * When both readings land on the same port they are OR'ed into one button mask, and any
//     disagreement about the A/B pair then puts *both* bits in the same frame. Every front-end
//     screen that tests B before A -- `IChooseCaptain::Update` is one, and its B is
//     `PopEntireStack()` back to the main menu -- resolves such a frame as B. That is the whole of
//     "the main menu is fine but in a submenu A acts like B": at the root, a frame carrying A and B
//     resolves as A, so nothing looks wrong until there is a screen to go back from.
//
// `SDL_JOYSTICK_MFI=0` turns the second reader off at its source: `IOS_JoystickInit` returns before
// registering anything, so no `GCController` becomes an SDL gamepad and Aurora has nothing to read.
// Aurora's keyboard bindings still hold port 0 open, which is the same thing that keeps the pad
// alive for touch-only play, so the port the game reads is unchanged -- only the second writer to it
// is gone.
//
// Written into the environment rather than through `SDL_SetHint` because SDL's joystick subsystem is
// initialized inside Aurora's own start-up, before any hook of this app's runs; a static initializer
// is the one thing that is reliably earlier. SDL resolves an unset hint from the environment, so
// this is the same switch `SDL_SetHint` would throw.
struct BallpadPhysicalControllerOwnership {
  BallpadPhysicalControllerOwnership() { setenv("SDL_JOYSTICK_MFI", "0", 1); }
};
const BallpadPhysicalControllerOwnership kBallpadPhysicalControllerOwnership;

uintptr_t ControllerInstanceID(GCController *controller) {
  return reinterpret_cast<uintptr_t>((__bridge void *)controller);
}

GCControllerPlayerIndex PlayerIndexForSlot(const std::size_t slot) {
  switch (slot) {
    case 0: return GCControllerPlayerIndex1;
    case 1: return GCControllerPlayerIndex2;
    case 2: return GCControllerPlayerIndex3;
    case 3: return GCControllerPlayerIndex4;
    default: return GCControllerPlayerIndexUnset;
  }
}

SunPadPhysicalControllerButton PressedFaceButtons(GCExtendedGamepad *pad) {
  uint8_t buttons = 0;
  if (pad.buttonA.isPressed) buttons |= SunPadPhysicalControllerButtonA;
  if (pad.buttonB.isPressed) buttons |= SunPadPhysicalControllerButtonB;
  if (pad.buttonX.isPressed) buttons |= SunPadPhysicalControllerButtonX;
  if (pad.buttonY.isPressed) buttons |= SunPadPhysicalControllerButtonY;
  if (pad.leftShoulder.isPressed) {
    buttons |= SunPadPhysicalControllerButtonLeftShoulder;
  }
  return static_cast<SunPadPhysicalControllerButton>(buttons);
}

BallpadPhysicalControllerSample SampleFromGamepad(GCExtendedGamepad *gamepad) {
  BallpadPhysicalControllerSample sample;
  sample.faceButtons = PressedFaceButtons(gamepad);
  sample.menu = gamepad.buttonMenu.isPressed;
  sample.dpadUp = gamepad.dpad.up.isPressed;
  sample.dpadDown = gamepad.dpad.down.isPressed;
  sample.dpadLeft = gamepad.dpad.left.isPressed;
  sample.dpadRight = gamepad.dpad.right.isPressed;
  sample.rightShoulder = gamepad.rightShoulder.isPressed;
  sample.leftX = gamepad.leftThumbstick.xAxis.value;
  sample.leftY = gamepad.leftThumbstick.yAxis.value;
  sample.rightX = gamepad.rightThumbstick.xAxis.value;
  sample.rightY = gamepad.rightThumbstick.yAxis.value;
  sample.leftTrigger = gamepad.leftTrigger.value;
  sample.rightTrigger = gamepad.rightTrigger.value;
  return sample;
}

// -- The scripted controller's vocabulary --------------------------------
// Steps are frame-counted, and each one is one *sample* rather than one device write: what the
// script does is hand the bridge the same struct a real pad produces, so the scripted run and a
// physical one meet the code under test at the identical seam.
constexpr unsigned long kScriptStepFrames = 30;
// Frames after the controller connects before the first step, so the slot is assigned and the
// engine's pad has caught up with an honest rest state before anything is pressed.
constexpr unsigned long kScriptSettleFrames = 20;

enum ScriptStep {
  kStepPressA = 0,
  kStepPressB,
  kStepPressX,
  kStepPressY,
  kStepPressZ,
  kStepPressStart,
  kStepPressDpadUp,
  kStepPressDpadLeft,
  kStepPressL,
  kStepPressR,
  kStepPressRightShoulder,
  kStepMoveStick,
  kStepMoveCStick,
  kStepRelease,
  kStepCount,
};

const char *const kScriptStepNames[kStepCount] = {
    "press-a", "press-b", "press-x", "press-y", "press-z", "press-start",
    "press-dpad-up", "press-dpad-left", "press-l", "press-r", "press-right-shoulder",
    "move-stick", "move-cstick", "release",
};

BallpadPhysicalControllerSample SampleForStep(const unsigned long step) {
  BallpadPhysicalControllerSample sample;
  switch (step) {
    case kStepPressA:
      sample.faceButtons = SunPadPhysicalControllerButtonA;
      break;
    case kStepPressB:
      sample.faceButtons = SunPadPhysicalControllerButtonB;
      break;
    case kStepPressX:
      sample.faceButtons = SunPadPhysicalControllerButtonX;
      break;
    case kStepPressY:
      sample.faceButtons = SunPadPhysicalControllerButtonY;
      break;
    case kStepPressZ:
      sample.faceButtons = SunPadPhysicalControllerButtonLeftShoulder;
      break;
    case kStepPressStart:
      sample.menu = true;
      break;
    case kStepPressDpadUp:
      sample.dpadUp = true;
      break;
    case kStepPressDpadLeft:
      sample.dpadLeft = true;
      break;
    case kStepPressL:
      sample.leftTrigger = 1.0f;
      break;
    case kStepPressR:
      sample.rightTrigger = 1.0f;
      break;
    case kStepPressRightShoulder:
      sample.rightShoulder = true;
      break;
    case kStepMoveStick:
      sample.faceButtons = SunPadPhysicalControllerButtonA;
      sample.leftX = 1.0f;
      break;
    case kStepMoveCStick:
      sample.rightX = 1.0f;
      break;
    case kStepRelease:
    default:
      break;
  }
  return sample;
}

// The elements the virtual controller offers, which is every one a `GCExtendedGamepad` needs for
// this game's control set: the four face buttons, both shoulders, both analog triggers, Menu, the
// D-pad and both thumbsticks.
NSSet<NSString *> *ScriptedElements(void) {
  return [NSSet setWithObjects:GCInputButtonA, GCInputButtonB, GCInputButtonX,
                               GCInputButtonY, GCInputLeftShoulder, GCInputRightShoulder,
                               GCInputLeftTrigger, GCInputRightTrigger, GCInputButtonMenu,
                               GCInputDirectionPad, GCInputLeftThumbstick,
                               GCInputRightThumbstick, nil];
}

void ApplySampleToVirtual(GCVirtualController *pad,
                          const BallpadPhysicalControllerSample& sample) {
  const CGFloat on = 1.0;
  const CGFloat off = 0.0;
  const BOOL buttonA = (sample.faceButtons & SunPadPhysicalControllerButtonA) != 0;
  const BOOL buttonB = (sample.faceButtons & SunPadPhysicalControllerButtonB) != 0;
  const BOOL buttonX = (sample.faceButtons & SunPadPhysicalControllerButtonX) != 0;
  const BOOL buttonY = (sample.faceButtons & SunPadPhysicalControllerButtonY) != 0;
  const BOOL shoulderL =
      (sample.faceButtons & SunPadPhysicalControllerButtonLeftShoulder) != 0;
  [pad setValue:buttonA ? on : off forButtonElement:GCInputButtonA];
  [pad setValue:buttonB ? on : off forButtonElement:GCInputButtonB];
  [pad setValue:buttonX ? on : off forButtonElement:GCInputButtonX];
  [pad setValue:buttonY ? on : off forButtonElement:GCInputButtonY];
  [pad setValue:shoulderL ? on : off forButtonElement:GCInputLeftShoulder];
  [pad setValue:sample.rightShoulder ? on : off forButtonElement:GCInputRightShoulder];
  // The two triggers are analog in the framework and are driven as values rather than as presses,
  // so a step that wants one held presses it to its top.
  [pad setValue:sample.leftTrigger forButtonElement:GCInputLeftTrigger];
  [pad setValue:sample.rightTrigger forButtonElement:GCInputRightTrigger];
  [pad setValue:sample.menu ? on : off forButtonElement:GCInputButtonMenu];

  CGFloat dpadX = 0.0;
  CGFloat dpadY = 0.0;
  if (sample.dpadLeft) dpadX -= 1.0;
  if (sample.dpadRight) dpadX += 1.0;
  if (sample.dpadDown) dpadY -= 1.0;
  if (sample.dpadUp) dpadY += 1.0;
  [pad setPosition:CGPointMake(dpadX, dpadY) forDirectionPadElement:GCInputDirectionPad];
  [pad setPosition:CGPointMake(sample.leftX, sample.leftY)
   forDirectionPadElement:GCInputLeftThumbstick];
  [pad setPosition:CGPointMake(sample.rightX, sample.rightY)
   forDirectionPadElement:GCInputRightThumbstick];
}

}  // namespace

// The translation itself, and it is a free function on purpose: a physical pad and the scripted one
// both arrive here as the same struct, so this is the one place a sample becomes a GameCube state
// and the only place the two paths could disagree. It holds no Apple types, which is what lets the
// scripted run exercise the shipping translation rather than a re-implementation of it.
SunPadInputState BallpadAdaptPhysicalControllerSample(
    const BallpadPhysicalControllerSample& sample,
    const SunPadControllerButtonMapping mapping) noexcept {
  SunPadInputState state{};
  state.connected = 1;

  // The four face buttons and the left shoulder go through the vendored map, because those are the
  // five the vendored store remaps. Everything below is a direct binding, which is the store's own
  // documented boundary rather than a decision made here.
  state.buttons |= SunPadApplyControllerButtonMapping(mapping, sample.faceButtons);
  if (sample.menu) state.buttons |= SunPadButtonStart;
  if (sample.dpadUp) state.buttons |= SunPadButtonDpadUp;
  if (sample.dpadDown) state.buttons |= SunPadButtonDpadDown;
  if (sample.dpadLeft) state.buttons |= SunPadButtonDpadLeft;
  if (sample.dpadRight) state.buttons |= SunPadButtonDpadRight;

  state.stickX = static_cast<int8_t>(
      std::lround(std::clamp(sample.leftX, -1.0f, 1.0f) * 127.0f));
  state.stickY = static_cast<int8_t>(
      std::lround(std::clamp(sample.leftY, -1.0f, 1.0f) * 127.0f));
  state.cStickX = static_cast<int8_t>(
      std::lround(std::clamp(sample.rightX, -1.0f, 1.0f) * 127.0f));
  state.cStickY = static_cast<int8_t>(
      std::lround(std::clamp(sample.rightY, -1.0f, 1.0f) * 127.0f));

  // The analog line carries what the pad reported, and the digital bit is derived from the same
  // number rather than from a helper that would raise it -- see kBallpadTriggerPressThreshold.
  state.triggerL = static_cast<uint8_t>(
      std::lround(std::clamp(sample.leftTrigger, 0.0f, 1.0f) * 255.0f));
  state.triggerR = static_cast<uint8_t>(
      std::lround(std::clamp(sample.rightTrigger, 0.0f, 1.0f) * 255.0f));
  if (state.triggerL > kBallpadTriggerPressThreshold) state.buttons |= SunPadButtonL;
  if (state.triggerR > kBallpadTriggerPressThreshold || sample.rightShoulder) {
    state.buttons |= SunPadButtonR;
  }

  return state;
}

@implementation BallpadPhysicalControllers {
  SunPadControllerSlots _slots;
  NSMutableDictionary<NSNumber *, GCController *> *_configuredControllers;
  NSMutableSet<NSNumber *> *_ignoredControllers;
  std::mutex _stateMutex;
  std::array<SunPadInputState, SunPadControllerSlots::kMaxPlayers> _states;
  BOOL _started;
}

+ (instancetype)sharedControllers {
  static BallpadPhysicalControllers *controllers = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    controllers = [[BallpadPhysicalControllers alloc] init];
  });
  return controllers;
}

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    _configuredControllers = [NSMutableDictionary dictionary];
    _ignoredControllers = [NSMutableSet set];
    _states = {};
  }
  return self;
}

- (void)start {
  if (_started) return;
  _started = YES;
  NSNotificationCenter *notifications = NSNotificationCenter.defaultCenter;
  [notifications addObserver:self
                    selector:@selector(controllerConnectionChanged:)
                        name:GCControllerDidConnectNotification
                      object:nil];
  [notifications addObserver:self
                    selector:@selector(controllerConnectionChanged:)
                        name:GCControllerDidDisconnectNotification
                      object:nil];
  [self reconcileControllers];
}

- (void)stop {
  if (!_started) return;
  _started = NO;
  [NSNotificationCenter.defaultCenter removeObserver:self];
  // Every slot is released through the same three steps a disconnect takes, so a pad held as the
  // app went away cannot leave a pressed bit behind for the next session to inherit.
  for (GCController *controller in _configuredControllers.allValues) {
    controller.extendedGamepad.valueChangedHandler = nil;
    controller.playerIndex = GCControllerPlayerIndexUnset;
  }
  [_configuredControllers removeAllObjects];
  _slots = {};
  {
    std::scoped_lock lock(_stateMutex);
    _states = {};
  }
  [[SunPadInputMixer sharedMixer] clearInputFromTouch:NO];
}

- (void)controllerConnectionChanged:(NSNotification *)notification {
  (void)notification;
  [self reconcileControllers];
}

- (void)releaseHeldInput {
  {
    std::scoped_lock lock(_stateMutex);
    for (SunPadInputState& state : _states) {
      const int connected = state.connected;
      state = {};
      // The slot keeps saying a pad is there; what it stops saying is that anything on it is held.
      state.connected = connected;
    }
  }
  [[SunPadInputMixer sharedMixer] clearInputFromTouch:NO];
}

- (void)resampleControllers {
  for (NSNumber *key in _configuredControllers.allKeys) {
    GCController *controller = _configuredControllers[key];
    GCExtendedGamepad *gamepad = controller.extendedGamepad;
    if (gamepad != nil) {
      [self publishController:controller gamepad:gamepad];
    }
  }
}

- (void)publishController:(GCController *)controller
                  gamepad:(GCExtendedGamepad *)gamepad {
  [self publishController:controller sample:SampleFromGamepad(gamepad)];
}

// The sample is taken by the caller rather than here, and that is the whole point of the split: the
// device's own frame has to be read on the frame it was delivered. `valueChangedHandler` hands over
// the pad at the moment something moved, and reading it later -- after a hop to the main queue --
// reads whatever the pad holds *then*. A press and its release that both happen between two hops
// therefore look like nothing at all: the bridge never observes the pressed state, so the mixer has
// no rising edge to latch and the tap is gone. Taking the sample where the event is delivered is
// what makes a quick tap survive the hop; everything below still runs on the main thread, because
// the slot table and the mixer are main-thread state.
- (void)publishController:(GCController *)controller
                   sample:(const BallpadPhysicalControllerSample&)sample {
  const int slot = _slots.SlotFor(ControllerInstanceID(controller));
  if (slot < 0 || slot >= static_cast<int>(SunPadControllerSlots::kMaxPlayers)) return;
  const SunPadInputState state =
      BallpadAdaptPhysicalControllerSample(sample, [SunPadControllerMappingStore mapping]);
  {
    std::scoped_lock lock(_stateMutex);
    _states[static_cast<std::size_t>(slot)] = state;
  }
  // Only the first slot is offered to the game, and one slot's worth of the mixer is what the port
  // reads: PortHostUIPollPad merges it into port 0 once per frame, and port 0 is the only port the
  // engine's pad is ever opened on. A pad that lands in a later slot is still tracked -- the log
  // says which slot it took -- but offering it here would be an input the game has nowhere to read.
  if (slot == 0) {
    [[SunPadInputMixer sharedMixer] setInputState:state fromTouch:NO];
  }
}

- (void)configureController:(GCController *)controller slot:(const std::size_t)slot {
  GCExtendedGamepad *gamepad = controller.extendedGamepad;
  if (gamepad == nil) return;
  __weak BallpadPhysicalControllers *weakSelf = self;
  __weak GCController *weakController = controller;
  gamepad.valueChangedHandler = ^(GCExtendedGamepad *pad, GCControllerElement *element) {
    (void)element;
    // Read the pad here, on GameController's own queue, because this is the only moment the sample
    // and the event agree; see -publishController:sample: for what re-reading it after the hop
    // costs. What crosses the queue is the finished struct, which is a plain value with no Apple
    // types in it -- everything downstream, the mixer and the port's per-frame poll, is main-thread
    // state.
    const BallpadPhysicalControllerSample sample = SampleFromGamepad(pad);
    dispatch_async(dispatch_get_main_queue(), ^{
      BallpadPhysicalControllers *strongSelf = weakSelf;
      GCController *strongController = weakController;
      if (strongSelf != nil && strongController != nil) {
        [strongSelf publishController:strongController sample:sample];
      }
    });
  };
  controller.playerIndex = PlayerIndexForSlot(slot);
  // The first sample, immediately: a pad that has just connected is a pad at rest, and publishing
  // that rather than waiting for the person to move something means the slot's state is never a
  // guess about whether a controller is there.
  [self publishController:controller gamepad:gamepad];
}

- (void)reconcileControllers {
  // The scripted controller, when one is running, owns the pad the game reads. That is a property of
  // the injector rather than of the bridge: a scripted press is evidence only if the engine's own
  // pad is the pad the script is holding, and a second controller sitting in slot 0 would take that
  // place while the script's presses landed in a slot nothing reads. Every other controller is
  // therefore left unconfigured for the duration of the script and named in the log once, so a run
  // says which pad the script displaced rather than leaving it to be noticed as an absence.
  BallpadScriptedController *scripted = [BallpadScriptedController sharedScriptedController];
  const uintptr_t scripted_instance = [scripted controllerInstanceID];

  NSArray<GCController *> *controllers = GCController.controllers;
  std::vector<uintptr_t> instances;
  for (GCController *controller in controllers) {
    if (controller.extendedGamepad != nil) {
      const uintptr_t instance = ControllerInstanceID(controller);
      if ([scripted isRunning] && instance != scripted_instance) {
        NSNumber *key = @(instance);
        if (![_ignoredControllers containsObject:key]) {
          [_ignoredControllers addObject:key];
          BallpadLog(@"controller: script %@ owns the pad; instance 0x%lx vendor %@ is left unassigned",
                     [scripted scriptName], (unsigned long)instance,
                     controller.vendorName != nil ? controller.vendorName : @"unknown");
        }
        continue;
      }
      instances.push_back(instance);
    }
  }

  const SunPadControllerReconcileResult result = _slots.Reconcile(instances);
  for (const SunPadControllerSlotChange& change : result.removed) {
    NSNumber *key = @(change.instance);
    GCController *controller = _configuredControllers[key];
    controller.extendedGamepad.valueChangedHandler = nil;
    controller.playerIndex = GCControllerPlayerIndexUnset;
    [_configuredControllers removeObjectForKey:key];
    {
      std::scoped_lock lock(_stateMutex);
      _states[change.slot] = {};
    }
    // The mixer's controller half goes with the slot: a disconnect is the one moment where holding
    // what was last published would leave the game reading a pad that is no longer there.
    if (change.slot == 0) {
      [[SunPadInputMixer sharedMixer] clearInputFromTouch:NO];
    }
    BallpadLog(@"controller: removed instance 0x%lx slot %lu", (unsigned long)change.instance, (unsigned long)change.slot + 1);
  }

  for (GCController *controller in controllers) {
    if (controller.extendedGamepad == nil) continue;
    const uintptr_t instance = ControllerInstanceID(controller);
    const int slot = _slots.SlotFor(instance);
    if (slot < 0) continue;
    NSNumber *key = @(instance);
    if (_configuredControllers[key] != controller) {
      _configuredControllers[key] = controller;
      [self configureController:controller slot:static_cast<std::size_t>(slot)];
      BallpadLog(@"controller: assigned instance 0x%lx slot %d vendor %@", instance, slot + 1, controller.vendorName != nil ? controller.vendorName : @"unknown");
      // The map goes in the log beside the pad that will be read through it, not only when the fault
      // injector runs. A controller report that names the pad but not what its buttons were bound to
      // leaves the question such a report is usually asked unanswerable, and the map is a stored
      // preference the player can have changed. Its own line rather than a longer one above, because
      // that line's shape is what scripts/native/f12-pad-summary.awk reads a vendor name out of.
      const SunPadControllerButtonMapping mapping = [SunPadControllerMappingStore mapping];
      BallpadLog(@"controller: slot %d category %@ map a 0x%02x b 0x%02x x 0x%02x y 0x%02x z 0x%02x",
                 slot + 1,
                 controller.productCategory != nil ? controller.productCategory : @"unknown",
                 (unsigned)mapping.gameA, (unsigned)mapping.gameB, (unsigned)mapping.gameX,
                 (unsigned)mapping.gameY, (unsigned)mapping.gameZ);
    }
  }
}

- (BOOL)readPlayer:(NSUInteger)player state:(SunPadInputState *)state {
  if (state == nullptr || player >= SunPadControllerSlots::kMaxPlayers) return NO;
  std::scoped_lock lock(_stateMutex);
  *state = _states[player];
  return state->connected != 0;
}

- (NSUInteger)connectedControllerCount {
  std::scoped_lock lock(_stateMutex);
  NSUInteger count = 0;
  for (const SunPadInputState& state : _states) {
    if (state.connected != 0) ++count;
  }
  return count;
}

@end

// -- The scripted controller ----------------------------------------------------------------
//
// The other half of the file, and it shares nothing with the bridge above but the adaptation
// function it deliberately does not call: it drives a real GCVirtualController, so the connect, the
// sample delivery and the disconnect all travel the framework's own path into the bridge's
// valueChangedHandler. The hand holding the pad is synthetic; the pad and the code that reads it
// are not.
@implementation BallpadScriptedController {
  GCVirtualController *_virtual;
  NSString *_script;
  unsigned long _loopsSinceConnect;
  unsigned long _step;
  unsigned long _stepFrame;
  BOOL _enabled;
  BOOL _connected;
  BOOL _finished;
}

+ (instancetype)sharedScriptedController {
  static BallpadScriptedController *scripted = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    scripted = [[BallpadScriptedController alloc] init];
  });
  return scripted;
}

- (BOOL)startIfEnabled {
  if (_enabled) return YES;
  const char *requested = getenv("STRIKERS_FAKE_PAD");
  if (requested == nullptr || requested[0] == '\0') return NO;
  const std::string name(requested);
  if (name != "controller") {
    BallpadLog(@"controller: script %s rejected; the only script is 'controller'", requested);
    return NO;
  }
  _enabled = YES;
  _script = [NSString stringWithUTF8String:name.c_str()];

  // The app-side map, written the way the panel reads it, so an F12 row can state which physical
  // button each GameCube button is bound to rather than only that a map exists. The threshold is
  // the same constant the adapter presses a shoulder with, and the two frame counts are the script's
  // own clock, so a reader can tell a step that never ran from a step that ran and did nothing.
  const SunPadControllerButtonMapping mapping = [SunPadControllerMappingStore mapping];
  BallpadLog(@"controller: mapping a 0x%02x b 0x%02x x 0x%02x y 0x%02x z 0x%02x threshold %u settle %lu step %lu",
             (unsigned)mapping.gameA, (unsigned)mapping.gameB, (unsigned)mapping.gameX,
             (unsigned)mapping.gameY, (unsigned)mapping.gameZ,
             (unsigned)kBallpadTriggerPressThreshold,
             (unsigned long)kScriptSettleFrames, (unsigned long)kScriptStepFrames);
  [self connectVirtual];
  return YES;
}

- (BOOL)isRunning {
  return _enabled && !_finished;
}

- (nullable NSString *)scriptName {
  return _script;
}

- (const char *)currentStepName {
  return _step < static_cast<unsigned long>(kStepCount) ? kScriptStepNames[_step] : "done";
}

// The instance the bridge has to let through while this script runs. Zero until the framework has
// handed over the virtual controller, which is also the window in which the bridge has nothing of
// this script's to reconcile -- so a zero here excludes nothing that exists yet rather than
// admitting a pad the script is not holding.
- (uintptr_t)controllerInstanceID {
  if (!_connected) return 0;
  GCController *controller = _virtual.controller;
  return controller != nil ? ControllerInstanceID(controller) : 0;
}

- (void)connectVirtual {
  GCVirtualControllerConfiguration *configuration = [[GCVirtualControllerConfiguration alloc] init];
  configuration.elements = ScriptedElements();
  // Hidden, because this is a pad being injected rather than a control surface being drawn: with the
  // system overlay left on, the framework would draw its own touch controls over the game and the
  // run would be exercising a second visible interface instead of this app's.
  configuration.hidden = YES;
  _virtual = [GCVirtualController virtualControllerWithConfiguration:configuration];
  __weak BallpadScriptedController *weakSelf = self;
  [_virtual connectWithReplyHandler:^(NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      BallpadScriptedController *strongSelf = weakSelf;
      if (strongSelf == nil) return;
      if (error != nil) {
        BallpadLog(@"controller: script %@ connect failed %@", strongSelf->_script,
                   error.localizedDescription != nil ? error.localizedDescription : @"unknown");
        return;
      }
      strongSelf->_connected = YES;
      strongSelf->_step = 0;
      strongSelf->_stepFrame = 0;
      strongSelf->_loopsSinceConnect = 0;
      GCController *controller = strongSelf->_virtual.controller;
      BallpadLog(@"controller: script %@ connected vendor %@", strongSelf->_script,
                 controller.vendorName != nil ? controller.vendorName : @"unknown");
      // Reconcile here rather than leaving it to the connection notification: the notification and
      // this reply are two orderings of the same event, and only one of them has the instance ID
      // that says which controller the script is holding. Asking for a reconcile after the state is
      // set makes the slot assignment the same on either ordering.
      [[BallpadPhysicalControllers sharedControllers] reconcileControllers];
    });
  }];
}

- (void)stop {
  if (_virtual == nil) return;
  BallpadLog(@"controller: script %@ stopped", _script);
  [_virtual disconnect];
  _virtual = nil;
  _enabled = NO;
  _connected = NO;
  _finished = YES;
}

// One port frame. The steps are counted in the engine's frames rather than in wall-clock time, so a
// slow frame does not stretch a press and the recorded run says what the pad was doing on each of
// the frames the engine saw.
- (void)advanceFrame {
  if (!_connected || _finished) return;
  if (_stepFrame == 0) {
    // The settle window: the slot is being assigned and the engine's own pad is catching up with an
    // honest rest state, and a press delivered inside it would be a press of unknown duration.
    if (_loopsSinceConnect < kScriptSettleFrames) {
      _loopsSinceConnect += 1;
      return;
    }
    _stepFrame = 1;
    [self applyStep];
    return;
  }
  _stepFrame += 1;
  if (_stepFrame <= kScriptStepFrames) return;
  _step += 1;
  if (_step >= static_cast<unsigned long>(kStepCount)) {
    [self finishScript];
    return;
  }
  _stepFrame = 1;
  [self applyStep];
}

- (void)applyStep {
  ApplySampleToVirtual(_virtual, SampleForStep(_step));
  // One line per step rather than per frame: the frames a step is held for belong to the port, and
  // the reading that shows the engine took the press is the adapter's own sampler, written beside
  // the offers it compares.
  BallpadLog(@"controller: script %@ step %lu %s", _script, _step, kScriptStepNames[_step]);
}

- (void)finishScript {
  _finished = YES;
  _connected = NO;
  BallpadLog(@"controller: script %@ done, %lu steps, disconnecting", _script,
             (unsigned long)kStepCount);
  // The pad goes away rather than being left holding a released sample, so the disconnect path --
  // handler cleared, slot released, the mixer's controller half cleared -- is the one an unplugged
  // controller takes, which is the path a script that merely released the buttons would not touch.
  GCVirtualController *pad = _virtual;
  _virtual = nil;
  [pad disconnect];
}

@end
