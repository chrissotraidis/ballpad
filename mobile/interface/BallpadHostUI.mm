// Ballpad's side of the port's host-UI seam (port/hostui.h).
//
// The interface itself is SunPad's, vendored byte-for-byte in interface/sunpad/; this file is the
// adaptation layer that directory's README asks for, and it holds every Ballpad-specific decision:
// where the overlay is attached, how a frame of touch input becomes the port's pad, what the
// menu's delegate callbacks do here, and what each of the vendored menu rows is bound to on this
// runtime. Keeping those decisions out of the vendored files is what makes "SunPad's controls,
// exactly as they are" a claim a reader can check with a diff: the rows, their titles, their order
// and their icons still come from the vendored -buildMenu, and the handful this file does change
// are named by their vendored title in -buildMenu below.
//
// Everything here runs on the main thread. The port's frame loop is main-thread on iOS and
// PortHostUIPollPad is called from inside it, so there is no hopping and no UIKit lock; the only
// lock taken is SunPadInputMixer's own, and it takes that itself.

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <GameController/GameController.h>

#include <SDL3/SDL_properties.h>
#include <SDL3/SDL_video.h>
// getenv, for the STRIKERS_LOG_ poll gates further down. Included rather than reached for through
// UIKit: the port's own files spell it this way, and this one reads the same variables they do.
#include <stdlib.h>
// memcmp, for the RIFF and WAVE tags the audio row's read-back checks before it trusts a chunk.
#include <string.h>

// The port's plain-C headers, included rather than restated: aspect, the frame limiter, and the
// frame-time benchmark the FPS row reads. include/port/input.h is here for the same reason -- it is
// where the controller-mapping panel reads the physical map the port actually resolved.
#include "port/aspect.h"
#include "port/audio.h"
#include "port/benchmark.h"
#include "port/framerate.h"
#include "port/hostui.h"
#include "port/input.h"
#include "port/overlay.h"

// The render-scale pin is the one exception, and the exception is the point. include/port/launch.h
// declares PortSetRenderScale and PortRenderScale inside a PORT_USE_AURORA guard and reaches for
// aurora/aurora.h to do it, while PORT_USE_AURORA is a compile definition on the port's own target
// that does not reach this one. Both are symbols in the port's archive either way, so declaring
// them here is the same link with a much smaller include graph for a UIKit file.
extern "C" {
void PortSetRenderScale(float scale);
float PortRenderScale(void);
void PortRenderTargetSize(unsigned int* width, unsigned int* height);
// The two accessors that say the display *aspect* reached the renderer rather than only the store.
// The render target below follows the window's shape, so it is deliberately not one of them; these
// are: PortLogicalFrameWidth is the coordinate space the game's GXSetViewport, GXSetScissor and 2D
// orthographic projections are set from (480 * aspect, so 640 at 4:3), and PortCameraAspectBlend is
// how far the gameplay camera has been carried from its 4:3 tuning toward its widescreen one.
unsigned int PortLogicalFrameWidth(void);
float PortCameraAspectBlend(void);
}

#import "SunPadDiagnostics.h"
#import "SunPadGameOverlay.h"
#import "SunPadInputMixer.h"
#import "SunPadSettings.h"

#import "BallpadControllerMapping.h"
#import "BallpadCredits.h"
#import "BallpadGameData.h"
#import "BallpadLog.h"
#import "BallpadPhysicalControllers.h"

// SunPad's button mask and the port's are the same twelve bits today. This is a translation rather
// than a cast on purpose: the compiler checks these names, so if either project's layout moves the
// wrong row is visible here, where a numeric hand-off would keep compiling and press a different
// button.
static unsigned int BallpadPortButtons(uint16_t sunPadButtons)
{
    const struct { SunPadButton sunPad; unsigned int port; } rows[] = {
        { SunPadButtonDpadLeft,  PORT_PAD_BUTTON_LEFT  },
        { SunPadButtonDpadRight, PORT_PAD_BUTTON_RIGHT },
        { SunPadButtonDpadDown,  PORT_PAD_BUTTON_DOWN  },
        { SunPadButtonDpadUp,    PORT_PAD_BUTTON_UP    },
        { SunPadButtonZ,         PORT_PAD_TRIGGER_Z    },
        { SunPadButtonR,         PORT_PAD_TRIGGER_R    },
        { SunPadButtonL,         PORT_PAD_TRIGGER_L    },
        { SunPadButtonA,         PORT_PAD_BUTTON_A     },
        { SunPadButtonB,         PORT_PAD_BUTTON_B     },
        { SunPadButtonX,         PORT_PAD_BUTTON_X     },
        { SunPadButtonY,         PORT_PAD_BUTTON_Y     },
        { SunPadButtonStart,     PORT_PAD_BUTTON_START },
    };

    unsigned int port = 0;
    for (const auto& row : rows)
    {
        if ((sunPadButtons & row.sunPad) != 0)
            port |= row.port;
    }
    return port;
}

// ── Ballpad's own row state ───────────────────────────────────────────────────
// The frame-limit row (doc 36 R1 item 11) stands where a vendored row promised an emulator's
// "Experimental 60 FPS" boot mode. A native port has no boot mode to change and no emulated clock
// to speed up -- it has the limiter, which caps rather than accelerates -- so the row's state is
// Ballpad's own key and the vendored key is left where N4 put it (R1 item 14). The port reads
// STRIKERS_FPS_LIMIT once at start and knows nothing about user defaults, which is why this is
// re-applied in PortHostUIStart and not only when the row is tapped.
// The key itself lives with BallpadLog's other app-level facts, because the settings read-back that
// reports this row has to name it too.

static BOOL BallpadFrameLimitIsUnlimited(void)
{
    return [NSUserDefaults.standardUserDefaults boolForKey:BallpadFrameLimitUnlimitedKey];
}

// The C-stick's horizontal axis. "Modern C-stick horizontal" exists because the GameCube camera's
// horizontal convention is inverted relative to what a player raised on a dual-stick pad expects;
// SunPad's own input encoder applies the flip on the way to its emulator, and here the port *is*
// the emulator, so the same flip has to happen on the way into the port's pad. Without this the
// switch would persist a preference that nothing reads -- exactly the failure R1 item 5 names.
static int BallpadCStickX(int sunPadCStickX)
{
    if ([SunPadSettings sharedSettings].modernCStickHorizontal)
        return -sunPadCStickX;
    return sunPadCStickX;
}

// ── The two display settings that have to reach the renderer ──────────────────
// SunPad offers the render scale and the aspect from two surfaces each, and neither surface
// reaches this runtime: the menu's Render Resolution and Aspect Ratio rows are the vendored
// handlers, which write SunPadSettings and stop at -refreshMenuButton, and the settings panel's own
// "Render" segmented control does the same. Ballpad rebuilds the menu rows against its own
// handlers, so that route acts where it happens; the panel's control is vendored code whose bytes
// are the fidelity claim, so this is the other half of the bridge. It is deliberately
// route-independent: whatever put a value in SunPadSettings -- Ballpad's own menu row, the vendored
// panel control, or the store an earlier run left behind -- is read here and handed to the port.
//
// Read from PortHostUIFrame rather than from a UIKit action, because that call sits inside the
// port's frame, after PortPumpAuroraEvents has already run PortFollowWindowShape. A pin applied
// from a UIKit handler races the next follow pass; applied here it is the frame's last word.
//
// Each setting has two states and only the first is a choice:
//   * a stored value is the player's, and it pins the port;
//   * a missing one is nobody's, and the port keeps doing what it did before this bridge existed --
//     following the window, with the window's own height for the render scale and the window's own
//     shape for the aspect. The vendored menu can say that for the aspect -- "Fill Screen" is
//     exactly the window's shape -- but the vendored panel has no render-scale segment for it, so a
//     missing render scale is primed once the window has settled, and the stored value then
//     describes what the port is already doing. The window is resized during the port's own
//     start-up (the first measured phone run showed a transient 448-row window before the real
//     one), so "settled" is sixty consecutive frames of one value rather than the first frame's
//     reading: priming on a transient would freeze the picture at the size of a window that no
//     longer exists.
static NSInteger s_renderScalePinned;   // 0 = the port still follows the window's height
static NSInteger s_aspectPinned = -1;   // -1 = the port still follows the window's shape
static float s_followScaleSeen;
static unsigned s_followScaleFrames;

static BOOL BallpadStoredSetting(NSString *key, NSInteger *outValue)
{
    NSNumber *value = [NSUserDefaults.standardUserDefaults objectForKey:key];
    if (value == nil)
        return NO;
    *outValue = value.integerValue;
    return YES;
}

// The window's own scale, in the units the setting can hold. The port derives a fractional scale
// from the window height; the vendored control offers four integers, so the nearest one is what the
// setting can carry without pretending to a precision it does not have.
static NSInteger BallpadRenderScaleNearest(float follow)
{
    NSInteger scale = (NSInteger)(follow + 0.5f);
    return scale < 1 ? 1 : (scale > 4 ? 4 : scale);
}

static float BallpadAspectValueForMode(NSInteger mode)
{
    switch (mode)
    {
        case SunPadAspectRatioWidescreen: return 16.0f / 9.0f;
        case SunPadAspectRatioFillScreen: return -1.0f;
        default:                          return 4.0f / 3.0f;
    }
}

// The port's own read-back of what the display rows changed: the render target the renderer is
// configured with, the scale it was asked for, the aspect the picture is being fitted to with
// whether that shape is the window's or a pinned one, and the two numbers that say the aspect
// reached the *renderer* rather than only the store. One helper for the log and for the FPS counter
// because "the row reached the store" and "the row reached the renderer" are different facts, and
// this string is the second one -- it is read back through the same accessors the display bridge
// writes through, so a row that changed the store and nothing else shows up here as a target that
// did not move.
//
// The target's own shape is the window's, at the render scale, which is why the aspect row moves
// `logical` and `blend` and leaves `WxH` alone. That is not a gap in the row; it is where the change
// lands. The port presents one buffer scaled to the surface and fits the picture inside it by moving
// the game's logical frame and camera, so a reader who only had `WxH` would read an aspect change as
// having done nothing -- which is exactly the mistake this field pair exists to prevent.
static NSString *BallpadDisplayReadBack(void)
{
    unsigned int width = 0;
    unsigned int height = 0;
    PortRenderTargetSize(&width, &height);
    return [NSString stringWithFormat:@"%ux%u @%.2fx aspect %.3f %@ logical %u blend %.2f",
            width, height, (double)PortRenderScale(), (double)PortTargetAspect(),
            PortAspectFollowsWindow() ? @"window" : @"pinned",
            PortLogicalFrameWidth(), (double)PortCameraAspectBlend()];
}

// The port's own account of the audio path, in the shape of the display read-back above and for the
// same reason: "MusyX initialised" and "the device was handed the mixer's bytes" are two different
// facts, and only the second one is sound. The numbers are the mixer's own, and they are read
// together because each one alone names a different silence: a studio in state 1 with voices on it
// says the sequencer ran, voices whose sample resolves to memory says the samples were found, a
// peak envelope and pan volume say the voices were driving them, the bus peak says the mix that
// came out the far end was not silent, and the transport's tick and underrun counts say whether the
// device was ever handed it. The dump fields are the recorded-audio row's state, read from the
// mixer rather than remembered here, so the row's checkmark follows the recording and not the tap.
//
// How many frames the port has asked this seam to publish for. It is the loop's own rate measured
// by a clock outside the port, which is the only way to say whether the audio clock and the frame
// clock are the same clock: the transport's ticks are 5 ms of *audio* time and this is one *frame*
// of game time, and a run where the two per-second rates differ is a run where every voice lands
// further from the model that speaks it than the one before.
static unsigned long s_framesPolled;

static NSString *BallpadAudioReadBack(void)
{
    unsigned long buffers = 0;
    unsigned long underruns = 0;
    int everNonSilent = 0;
    PortAudioStats(&buffers, &underruns, &everNonSilent);

    // The transport's queue, which is the half of "are the sounds attached to the models" that
    // voices and bus peaks cannot answer: those say a sound exists, this says how far behind the
    // frame that produced it the speaker still is. Printed with its own spread and its own drain
    // rate, because a queue length is only a length in time if the stream's bytes are leaving at
    // the stream's own rate.
    PortAudioLatencyInfo onset;
    NSString *onsetText = PortAudioLatencyStats(&onset)
        ? [NSString stringWithFormat:@"onset lead %.1f min %.1f max %.1f mean %.1f ms over %lu "
                                   @"frames | devhold %.1f ms | drain %.0f B/s of %u",
                                   onset.leadMs, onset.leadMinMs, onset.leadMaxMs,
                                   onset.leadMeanMs, onset.handovers, onset.deviceMs,
                                   onset.drainBytesPerSec, onset.streamByteRate]
        : @"onset unmeasured (nothing queued yet)";

    // The frame clock beside the audio one, with the line's own timestamp as the third reading.
    // The port's rolling window and this seam's own count are two independent measures of the same
    // rate, and they are printed together because a rate compared only against itself is not a
    // measurement.
    PortBenchLive live;
    PortBenchGetLive(&live);
    NSString *transportText = [NSString stringWithFormat:@"%@ | clock frame %lu fps %.1f",
                                                         onsetText, s_framesPolled, live.fps];

    PortAudioMixInfo mix;
    if (!PortAudioMixStats(&mix))
    {
        // The mixer has not run, which is what an audio-off build and a boot that never reached
        // sndInit() both look like from here. Reported as itself rather than as silence: the
        // transport's own numbers are still worth having, because ticks with no mixer is a
        // different fault from no ticks at all.
        return [NSString stringWithFormat:@"device %d ticks %lu underruns %lu %@ | the mixer has "
                @"not run | %@", PortAudioDeviceOpen(), buffers, underruns,
                everNonSilent ? @"non-silent" : @"silent", transportText];
    }

    return [NSString stringWithFormat:
            @"device %d ticks %lu underruns %lu %@ | studios %d voices %d sample %d env 0x%04x "
            @"pan 0x%04x bus %d | frq %u master %.2f limiter %.3f | dumping %d frames %lu | %@",
            PortAudioDeviceOpen(), buffers, underruns, everNonSilent ? @"non-silent" : @"silent",
            mix.studios, mix.voices, mix.withSample, mix.peakEnv, mix.peakVol, mix.busPeak,
            mix.mixFrq, (double)mix.masterGain, (double)mix.limitGain, mix.dumping,
            mix.dumpFrames, transportText];
}

static void BallpadLogAudioTarget(NSString *what)
{
    BallpadLog(@"audio: %@ -- %@", what, BallpadAudioReadBack());
}

// The audio read-back on a clock, because the question it answers is about a run rather than about
// a tap. A row change alone would miss a device that failed to open before the row existed, and a
// per-frame line would bury the rest of the log. Two seconds is the port's own mixer-report period,
// so the app's line and the port's line pair up when they are read together.
static void BallpadLogAudioIfDue(void)
{
    static CFTimeInterval s_last;
    static BOOL s_written = NO;
    const CFTimeInterval now = CACurrentMediaTime();
    if (s_written && now - s_last < 2.0)
        return;
    BallpadLogAudioTarget(s_written ? @"running" : @"start-up");
    s_written = YES;
    s_last = now;
}

static void BallpadLogDisplayTarget(NSString *what)
{
    BallpadLog(@"display: %@ -- %@", what, BallpadDisplayReadBack());
    // Both read-backs, because a display row can be wrong in two independent ways: the store can
    // hold a value the renderer never got, or the renderer can hold one no surface shows. The line
    // above answers the second question and BallpadLogSettingsSnapshot answers the first, and this
    // is the one place in the run where both answers are known to belong to the same change.
    BallpadLogSettingsSnapshot(what);
}

// The vendored settings panel writes the store itself -- its bytes are the fidelity claim (R1 item
// 1), so Ballpad cannot hook the panel's controls -- which leaves one honest way for the log to
// report a panel change: notice the value that moved. Six numbers compared once a frame is cheap,
// and the line it writes is the same read-back a menu row writes, so a report spells a panel change
// and a row change the same way. Only the settings no menu row also owns are watched here; the
// display settings have their own bridge above, which reports them where they are pinned.
static void BallpadLogSettingsIfPanelChanged(void)
{
    SunPadSettings *settings = [SunPadSettings sharedSettings];
    const struct { const char *name; NSInteger value; } readings[] = {
        { "control opacity",    (NSInteger)(settings.controlOpacity * 100.0 + 0.5) },
        { "control size",       (NSInteger)(settings.controlSizeScale * 100.0 + 0.5) },
        { "hide on controller", settings.hideTouchControlsWhenControllerConnected ? 1 : 0 },
        { "modern c-stick",     settings.modernCStickHorizontal ? 1 : 0 },
        { "fps counter",        settings.showFPSCounter ? 1 : 0 },
        { "layout editing",     settings.editingControlLayout ? 1 : 0 },
    };
    const size_t count = sizeof(readings) / sizeof(readings[0]);
    static NSInteger s_seen[sizeof(readings) / sizeof(readings[0])];
    static BOOL s_primed = NO;

    NSMutableArray<NSString *> *moved = [NSMutableArray array];
    for (size_t index = 0; index < count; ++index)
    {
        // The first pass only records: a run's opening line is the startup state, and it comes from
        // the display bridge rather than from six settings that were never touched.
        if (s_primed && readings[index].value != s_seen[index])
            [moved addObject:[NSString stringWithUTF8String:readings[index].name]];
        s_seen[index] = readings[index].value;
    }
    s_primed = YES;
    if (moved.count > 0)
        BallpadLogSettingsSnapshot([NSString stringWithFormat:@"%@ changed by the settings panel",
                                    [moved componentsJoinedByString:@", "]]);
}

// -- The touch settings, read back from the overlay itself (R1 item 5) --------
// The store and the overlay are different witnesses, and only the second one is what the player
// touches. SunPadSettings can hold an opacity that no control is drawn at: the vendored panel
// writes the store and the overlay reads it back during its own layout pass, so a value that never
// reached a view is exactly the failure this reading has to be able to show. The vendored bytes
// are the fidelity claim and are not instrumented, so the reading is taken from the live view tree
// instead: alpha, bounds and center are public UIView state, they are what UIKit draws from, and
// the identifiers walked here are the overlay's own layout keys -- the same ones it persists a
// moved control under, and the same ones a UI test sees as elements.
//
// Whether a control is hidden is the one drawn fact whose input is not on this machine. The
// vendored `-applyControllerVisibility` compiles the controller half of its resolution out under
// `TARGET_OS_SIMULATOR`, so the count this build can read is *not* the value the overlay resolved
// from, and the line says so by publishing the setting, the count and the drawn hidden count as
// three separate fields rather than one verdict. The hardware merge itself stays F12/NOT_RUN.
static NSArray<UIView *> *BallpadTouchControlsInDrawOrder(SunPadGameOverlay *overlay)
{
    NSArray<NSString *> *order = @[ @"move", @"c", @"D_U", @"D_D", @"D_L", @"D_R",
                                    @"A", @"B", @"X", @"Y", @"Z", @"Start", @"L", @"R" ];
    NSMutableDictionary<NSString *, UIView *> *found = [NSMutableDictionary dictionary];
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:overlay];
    while (pending.count > 0)
    {
        UIView *view = pending.lastObject;
        [pending removeLastObject];
        NSString *identifier = view.accessibilityIdentifier;
        if (identifier.length > 0 && found[identifier] == nil)
            found[identifier] = view;
        [pending addObjectsFromArray:view.subviews];
    }
    NSMutableArray<UIView *> *controls = [NSMutableArray array];
    for (NSString *identifier in order)
        if (found[identifier] != nil)
            [controls addObject:found[identifier]];
    return controls;
}

static NSString *BallpadOverlayTouchReadBack(SunPadGameOverlay *overlay)
{
    NSArray<UIView *> *controls = BallpadTouchControlsInDrawOrder(overlay);
    SunPadSettings *settings = [SunPadSettings sharedSettings];
    NSMutableArray<NSString *> *drawn = [NSMutableArray array];
    NSUInteger hidden = 0;
    for (UIView *control in controls)
    {
        if (control.hidden)
            hidden++;
        // The identifier first and the drawn numbers after it, so a reader can line the reading up
        // with the control it came from. A control the overlay has hidden is named as hidden rather
        // than left with an alpha of zero and no explanation. The trailing k is the *per-control*
        // size override the editor writes, 1.0 when there is none, and it is published because it
        // is the only thing that tells the editor's own resize apart from the panel's global size
        // setting, which moves every control's drawn bounds with it: two different settings that
        // both show up as a drawn size changing, and only one of them is item 5's move/resize pair.
        [drawn addObject:[NSString stringWithFormat:@"%@ %.2f %.0fx%.0f @%.0f,%.0f k%.2f%@",
                          control.accessibilityIdentifier, (double)control.alpha,
                          (double)control.bounds.size.width, (double)control.bounds.size.height,
                          (double)control.center.x, (double)control.center.y,
                          (double)[settings sizeScaleForControl:control.accessibilityIdentifier],
                          control.hidden ? @" hidden" : @""]];
    }

    // The two panel values the drawn numbers above are supposed to follow, published beside them so
    // a reader can tie a drawn alpha or a drawn size to the setting that asked for it. The store's
    // own line is a different witness -- it can hold an opacity no control was ever drawn at -- and
    // these are the values the overlay resolved at the moment it laid the tree out.
    // `hidden` is the count of the drawn controls the overlay has hidden, which is the resolved half
    // of the visibility setting above it: the vendored pass paints a hidden control at an alpha of
    // zero and flags the view, and only a count taken off those views says whether the resolution
    // reached the drawing. The editor paints every control at full alpha while it is open, which is
    // why a reader comparing a drawn alpha with the opacity setting has to allow that one state.
    return [NSString stringWithFormat:@"controllers %lu hide-requested %d opacity %.2f size %.2f drawn %lu hidden %lu | %@",
            (unsigned long)GCController.controllers.count,
            settings.hideTouchControlsWhenControllerConnected ? 1 : 0,
            (double)settings.controlOpacity,
            (double)settings.controlSizeScale,
            (unsigned long)controls.count,
            (unsigned long)hidden,
            drawn.count > 0 ? [drawn componentsJoinedByString:@" | "]
                            : @"no control is drawn"];
}

// A drag or a slider moves the tree every frame, and the value worth keeping is the one it settles
// on: the line is written a third of a second after the tree stops moving, so a touch that ends
// leaves one reading rather than sixty. The overlay is watched by identity, because a lifecycle
// rebuild replaces it and a reading of the old tree would describe controls nobody can touch.
// How often a settled read-back is taken. These samplers each walk the drawn tree and format a
// string naming every control, and they do it to decide whether anything moved -- so at sixty a
// second the app was building and comparing that string every frame of a match, on the thread the
// game runs on, to log a line that can only appear once the reading has been still for 0.35 s.
// Sampling at ten a second is six times less work for the same lines: the settle window is measured
// in time rather than in frames, so a reading that has held for a third of a second still has held
// for a third of a second when it is looked at less often.
static BOOL BallpadSampleIsDue(CFTimeInterval *last)
{
    static CFTimeInterval const kInterval = 0.1;
    const CFTimeInterval now = CACurrentMediaTime();
    if (*last != 0.0 && now - *last < kInterval)
        return NO;
    *last = now;
    return YES;
}

static void BallpadLogOverlayTouchIfSettled(SunPadGameOverlay *overlay)
{
    static __weak SunPadGameOverlay *s_readFrom = nil;
    static NSString *s_logged = nil;
    static NSString *s_pending = nil;
    static CFTimeInterval s_pendingSince = 0.0;
    static CFTimeInterval s_lastSample = 0.0;

    if (!BallpadSampleIsDue(&s_lastSample))
        return;

    if (overlay != s_readFrom)
    {
        s_readFrom = overlay;
        s_logged = nil;
        s_pending = nil;
    }

    NSString *now = BallpadOverlayTouchReadBack(overlay);
    if (s_logged != nil && [now isEqualToString:s_logged])
        return;
    const CFTimeInterval stamp = CACurrentMediaTime();
    if (s_pending == nil || ![now isEqualToString:s_pending])
    {
        s_pending = now;
        s_pendingSince = stamp;
        return;
    }
    if (stamp - s_pendingSince < 0.35)
        return;
    s_logged = now;
    s_pending = nil;
    BallpadLog(@"overlay: the touch controls as drawn -- %@", now);
}

// -- The safe area the controls are drawn inside (doc 34 F06) -----------------
// F06's rotation half asks whether the landscape layout fits the safe areas, and this is the
// reading that answers it: not "the layout ran" but "every control it drew is inside the region the
// surface says is safe". The vendored pass is the only thing that decides where a control goes, and
// it derives its placement from the overlay's own -safeAreaInsets, so the surface's safe rect is
// the reference and the controls' converted frames are the claim. Nothing here is a device
// constant: the numbers come from UIKit and the verdict is a containment test.
//
// This is worth a line of its own rather than a clause on the overlay read-back above because the
// two disagree in the case that matters. Rotating the device from one landscape side to the other
// leaves the surface the same *size* -- so an overlay reading that prints bounds and centres looks
// unchanged -- while the notch and the home indicator swap sides and the safe rect moves under
// every control. The insets are therefore stated in the line, and the runner's F06 clause is that
// two different inset readings were seen (the rotation happened) and that no line in either of them
// put a drawn control outside the safe rect.
//
// Settled rather than immediate, for the reason the overlay read-back is: a rotation animates, and
// the frames sampled during the animation are the ones on their way somewhere. Thirty-five
// hundredths of a second after the tree stops moving is the layout that stayed.
// The counter's own placement, as a field of the reading below. Forward-declared because the counter
// is defined further down the translation unit and this reading is defined here; the note itself is
// written by the placement, so it says which anchor the card was last put on and how many drawn
// things that placement was scored against -- the two numbers that tell a reader whether a card
// sitting over a control is a placement that chose badly or a placement that saw nothing to avoid.
static NSString *BallpadFPSCounterPlacementNote(UIView *overlay);

static NSString *BallpadLayoutReadBack(SunPadGameOverlay *overlay)
{
    const UIEdgeInsets insets = overlay.safeAreaInsets;
    // Half a point of slack, so a control the vendored pass placed exactly on the safe edge is
    // inside it rather than outside by a rounding error.
    const CGRect safe = CGRectInset(UIEdgeInsetsInsetRect(overlay.bounds, insets), -0.5, -0.5);

    NSArray<UIView *> *controls = BallpadTouchControlsInDrawOrder(overlay);
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSMutableArray<NSString *> *outside = [NSMutableArray array];
    NSUInteger judged = 0;
    for (UIView *control in controls)
    {
        // Only what is actually drawn is judged: a control the player has hidden by the
        // controller-connected rule or by the opacity slider is not a layout claim, and counting it
        // would turn a setting into a false failure.
        if (control.hidden || control.alpha == 0.0)
            continue;
        judged++;
        [names addObject:control.accessibilityIdentifier ?: @"?"];
        const CGRect drawn = [control convertRect:control.bounds toView:overlay];
        if (!CGRectContainsRect(safe, drawn))
            [outside addObject:[NSString stringWithFormat:@"%@ %@", control.accessibilityIdentifier ?: @"?",
                                NSStringFromCGRect(drawn)]];
    }

    // The FPS counter is Ballpad's own view rather than one of the vendored controls, and it is
    // placed against the same insets by BallpadPositionFPSCounterLabel -- so it belongs in the same
    // verdict. It is reported separately because it is the one drawn thing whose frame is set once
    // per surface shape, and a rotation that did not re-place it is a defect this line can show.
    //
    // Found by the identifier it publishes rather than held as a reference, for the reason
    // BallpadControlLabelled gives: the reading is of the tree the player has, and this file's
    // counter key is not in scope this early in the translation unit.
    UILabel *counter = nil;
    for (UIView *subview in overlay.subviews)
        if ([subview isKindOfClass:UILabel.class] &&
            [subview.accessibilityIdentifier isEqualToString:@"BallpadFPSCounter"])
            counter = (UILabel *)subview;
    NSString *counterField = @"fps 0";
    if (counter != nil && counter.superview != nil)
    {
        const CGRect drawn = [counter convertRect:counter.bounds toView:overlay];
        counterField = [NSString stringWithFormat:@"fps 1 origin %.1f,%.1f inside %d %@",
                        (double)drawn.origin.x, (double)drawn.origin.y,
                        CGRectContainsRect(safe, drawn) ? 1 : 0,
                        BallpadFPSCounterPlacementNote(overlay)];
    }

    NSString *offenders = outside.count > 0
        ? [NSString stringWithFormat:@" (%@)", [outside componentsJoinedByString:@"; "]]
        : @"";
    return [NSString stringWithFormat:
            @"surface %.0fx%.0f safe %.1f,%.1f,%.1f,%.1f | judged %lu outside %lu%@ | %@ | %@",
            (double)CGRectGetWidth(overlay.bounds), (double)CGRectGetHeight(overlay.bounds),
            (double)insets.left, (double)insets.top, (double)insets.right, (double)insets.bottom,
            (unsigned long)judged, (unsigned long)outside.count, offenders,
            [names componentsJoinedByString:@","], counterField];
}

static void BallpadLogLayoutIfSettled(SunPadGameOverlay *overlay)
{
    static __weak SunPadGameOverlay *s_readFrom = nil;
    static NSString *s_logged = nil;
    static NSString *s_pending = nil;
    static CFTimeInterval s_pendingSince = 0.0;
    static CFTimeInterval s_lastSample = 0.0;

    // Sampled rather than taken every frame, for the reason the touch read-back above gives.
    if (!BallpadSampleIsDue(&s_lastSample))
        return;

    if (overlay != s_readFrom)
    {
        s_readFrom = overlay;
        s_logged = nil;
        s_pending = nil;
    }

    NSString *now = BallpadLayoutReadBack(overlay);
    if (s_logged != nil && [now isEqualToString:s_logged])
        return;
    const CFTimeInterval stamp = CACurrentMediaTime();
    if (s_pending == nil || ![now isEqualToString:s_pending])
    {
        s_pending = now;
        s_pendingSince = stamp;
        return;
    }
    if (stamp - s_pendingSince < 0.35)
        return;
    s_logged = now;
    s_pending = nil;
    BallpadLog(@"layout: %@", now);
}

// The C-stick flip, read back where it is applied: the pad the port is handed. R1 item 5 counts
// this switch among the settings that have to reach the runtime, and this runtime's C-stick is the
// port's, so the value worth publishing is the published one. Only transitions of the setting and
// of the player's own direction are logged, which is what bounds the line count during a drag, and
// both raw and published values are printed so the flip can be checked rather than described.
static void BallpadLogCStickIfTurned(int raw, int published)
{
    const int sign = raw > 0 ? 1 : (raw < 0 ? -1 : 0);
    if (sign == 0)
        return;
    const BOOL modern = [SunPadSettings sharedSettings].modernCStickHorizontal;
    static int s_lastKey = -3;
    const int key = (modern ? 10 : 0) + (sign + 1);
    if (key == s_lastKey)
        return;
    s_lastKey = key;
    BallpadLog(@"c-stick: the mixer's own X %d reached the port as %d (modern c-stick %@)", raw,
               published, modern ? @"on" : @"off");
}

static void BallpadApplyDisplaySettings(void)
{
    NSInteger stored = 0;

    if (s_renderScalePinned != 0)
    {
        NSInteger wanted = [SunPadSettings sharedSettings].renderScale;
        if (wanted != s_renderScalePinned)
        {
            s_renderScalePinned = wanted;
            PortSetRenderScale((float)wanted);
            BallpadLogDisplayTarget([NSString stringWithFormat:@"render scale %ld from the "
                                     @"settings store", (long)wanted]);
        }
    }
    else if (BallpadStoredSetting(@"SunPadRenderScale", &stored))
    {
        s_renderScalePinned = stored;
        PortSetRenderScale((float)stored);
        BallpadLogDisplayTarget([NSString stringWithFormat:@"render scale %ld stored by an "
                                 @"earlier run; the panel and the renderer agree from here",
                                 (long)stored]);
    }
    else
    {
        const float follow = PortRenderScale();
        if (follow <= 0.0f)
        {
            s_followScaleSeen = 0.0f;
            s_followScaleFrames = 0;
        }
        else if (follow != s_followScaleSeen)
        {
            s_followScaleSeen = follow;
            s_followScaleFrames = 0;
        }
        else if (++s_followScaleFrames >= 60)
        {
            NSInteger scale = BallpadRenderScaleNearest(follow);
            [SunPadSettings sharedSettings].renderScale = scale;
            [[SunPadSettings sharedSettings] synchronize];
            s_renderScalePinned = scale;
            PortSetRenderScale((float)scale);
            BallpadLogDisplayTarget([NSString stringWithFormat:@"no render scale stored; the "
                                     @"window settled at %.2fx, so the setting was primed to %ld "
                                     @"and pinned", (double)follow, (long)scale]);
        }
    }

    if (BallpadStoredSetting(@"SunPadAspectRatioMode", &stored))
    {
        if (stored != s_aspectPinned)
        {
            s_aspectPinned = stored;
            PortSetTargetAspect(BallpadAspectValueForMode(stored));
            BallpadLogDisplayTarget([NSString stringWithFormat:@"aspect mode %ld from the "
                                     @"settings store", (long)stored]);
        }
    }
    else if (s_aspectPinned >= 0)
    {
        // The key left the store under a pinned aspect -- a reset or a migration -- so the aspect
        // goes back to the window rather than staying pinned to a setting nothing holds.
        s_aspectPinned = -1;
        PortSetTargetAspect(-1.0f);
        BallpadLogDisplayTarget(@"aspect setting cleared; the port follows the window again");
    }
}

// One presentation route, for the overlay's own rows and for the delegate callbacks the vendored
// menu sends through the bridge alike: same presenter, same style, and a line when there is nothing
// to present from rather than a silent no-op.
static void BallpadPresentOverlayViewController(SunPadGameOverlay *overlay,
                                                UIViewController *viewController)
{
    UIViewController *presenter = overlay.window.rootViewController;
    if (presenter == nil)
    {
        BallpadLog(@"host ui: no presenter for %@", NSStringFromClass(viewController.class));
        return;
    }
    viewController.modalPresentationStyle = UIModalPresentationPageSheet;
    [presenter presentViewController:viewController animated:YES completion:nil];
}

// A vendored control, found by the label SunPad gave it rather than held as an ivar. Reaching into
// the vendored class's storage by name would be a dependency on internals that a byte-for-byte copy
// is not allowed to develop, and the labels are the same strings the UI suite and VoiceOver use, so
// what is found here is what a player can find. Three callers want this: the popover anchor for a
// share sheet, the shoulder whose shape is re-derived below, and the settings read-backs that prove
// a setting landed.
static UIView *BallpadControlLabelled(UIView *root, NSString *label)
{
    if ([root.accessibilityLabel isEqualToString:label])
        return root;
    for (UIView *subview in root.subviews)
    {
        UIView *found = BallpadControlLabelled(subview, label);
        if (found != nil)
            return found;
    }
    return nil;
}

// The three-dot button specifically, for use as a popover anchor on iPad.
static UIButton *BallpadMenuButton(UIView *view)
{
    UIView *found = BallpadControlLabelled(view, @"Menu");
    return [found isKindOfClass:UIButton.class] ? (UIButton *)found : nil;
}

// The vendored menu button is a plain UIButton with a circular layer and an ellipsis image, and
// UIKit drives it through selected and highlighted states while a primary-action menu is being
// dismissed. On current iPadOS that transition can synthesize a rectangular selected appearance
// over the circle, and an app that returns from the background to a rebuilt SDL surface can lose
// the button entirely. Both are the same problem -- the button has no explicit appearance to fall
// back on -- and one explicit configuration is the repair. It is applied from here rather than in
// the vendored file precisely because the vendored bytes are the fidelity claim; KartPad's own note
// on this defect (docs/IOS-THREE-DOT-MENU-FIX.md in that project) documents the same repair from the
// owning layer, with the same capsule, the same fill and the same stroke the vendored code draws.
static void BallpadConfigureMenuButton(UIButton *button)
{
    // Configured once: a configuration set on every layout would fight the highlight UIKit is
    // already driving.
    if (button == nil || button.configuration != nil)
        return;

    UIButtonConfiguration *configuration = [UIButtonConfiguration plainButtonConfiguration];
    configuration.image = [button imageForState:UIControlStateNormal];
    configuration.baseForegroundColor = UIColor.whiteColor;
    configuration.contentInsets = NSDirectionalEdgeInsetsZero;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;

    UIBackgroundConfiguration *background = [UIBackgroundConfiguration clearConfiguration];
    background.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.72];
    background.cornerRadius = 20.0;
    background.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.30];
    background.strokeWidth = 1.0;
    configuration.background = background;

    button.automaticallyUpdatesConfiguration = NO;
    button.configuration = configuration;
    // One owner per visual: the configuration holds the fill and the stroke now, so the layer must
    // not draw a second border over it.
    button.backgroundColor = UIColor.clearColor;
    button.layer.borderWidth = 0.0;
}

// ── Hiding the menu button ────────────────────────────────────────────────────
// The three-dot button is the only piece of this app that is on screen for the whole of a match and
// is not part of the game. Hiding it is a row in its own menu; getting it back is a two-finger tap
// anywhere, held for a few seconds and then taken away again.
//
// Two fingers rather than a corner, because a corner is a place a thumb already goes: the Start
// control sits in the top-left of the phone layout and the shoulder row runs across the top. Two
// simultaneous touches are something the game's own controls never ask for as a pair -- and the
// touches that do land on a control are refused below, so pressing A and B together is not a reveal.
// The recogniser is on the window rather than on the overlay because the overlay's hit test passes
// empty space through to the game, so a tap on nothing never reaches it.
static NSTimeInterval const kBallpadMenuButtonRevealSeconds = 5.0;
static CFTimeInterval s_menuButtonRevealedUntil = 0.0;

// When UIKit last said it was about to put this app's own menu on screen. -buildMenu is asked for
// the menu as it opens, which is the only public moment a UIMenu announces itself: UIKit presents
// it in a window of its own, so there is no presented controller to find and no view of ours to
// watch. Nothing says when it closes, so the deadline here is generous and the frame sharing below
// gives it up early, as soon as the run loop goes quiet. Getting it wrong in either direction costs
// a frame or two of pacing and nothing else.
static CFTimeInterval s_menuInteractionUntil = 0.0;
static NSTimeInterval const kBallpadMenuInteractionSeconds = 10.0;

static BOOL BallpadMenuButtonIsHidden(void)
{
    return [NSUserDefaults.standardUserDefaults boolForKey:BallpadHideMenuButtonKey];
}

// The button's drawn state, which is the hidden preference unless a reveal is still running.
// Alpha and interaction move together: a button faded out that still answered a tap would be a
// control the player cannot see but can press by accident.
static void BallpadApplyMenuButtonVisibility(SunPadGameOverlay *overlay, BOOL animated)
{
    UIButton *button = BallpadMenuButton(overlay);
    if (button == nil)
        return;
    const BOOL revealed = CACurrentMediaTime() < s_menuButtonRevealedUntil;
    const BOOL visible = !BallpadMenuButtonIsHidden() || revealed;
    if (button.userInteractionEnabled == visible && button.alpha == (visible ? 1.0 : 0.0))
        return;
    button.userInteractionEnabled = visible;
    [UIView animateWithDuration:animated ? 0.2 : 0.0
                     animations:^{ button.alpha = visible ? 1.0 : 0.0; }];
}

static void BallpadRevealMenuButton(SunPadGameOverlay *overlay)
{
    if (!BallpadMenuButtonIsHidden())
        return;
    s_menuButtonRevealedUntil = CACurrentMediaTime() + kBallpadMenuButtonRevealSeconds;
    BallpadApplyMenuButtonVisibility(overlay, YES);
    BallpadLog(@"menu button: revealed by a two-finger tap for %.0f s",
               (double)kBallpadMenuButtonRevealSeconds);
}

// Called once a frame. Cheap on every frame but the one the reveal ends on: a comparison against a
// deadline that is zero whenever no reveal is running.
static void BallpadExpireMenuButtonReveal(SunPadGameOverlay *overlay)
{
    if (s_menuButtonRevealedUntil == 0.0 || CACurrentMediaTime() < s_menuButtonRevealedUntil)
        return;
    s_menuButtonRevealedUntil = 0.0;
    BallpadApplyMenuButtonVisibility(overlay, YES);
}

static void BallpadSetMenuButtonHidden(SunPadGameOverlay *overlay, BOOL hidden)
{
    [NSUserDefaults.standardUserDefaults setBool:hidden forKey:BallpadHideMenuButtonKey];
    // Hiding takes effect when the menu that asked for it closes, so the button does not vanish from
    // under the row the player is still looking at; the reveal window is what carries it across.
    s_menuButtonRevealedUntil = hidden ? CACurrentMediaTime() + 1.0 : 0.0;
    BallpadApplyMenuButtonVisibility(overlay, YES);
    BallpadLog(@"menu button: %@ by its own row", hidden ? @"hidden" : @"shown");
}

// ── The right shoulder (the operator's "R has to look like L" item) ───────────
// SunPad's R control is a pressure track built for Sunshine's spray nozzle: it paints a water fill
// up to a detent line and reports a press only in the last quarter of its width. Strikers wants
// neither half of that. The game asks for PAD_TRIGGER_R -- the same bit L sets -- and the console it
// came from has two identical shoulder buttons, which is why the operator's reference is the left
// one. So R here is L's twin: the repair below gives it L's shape, L's border and no artwork, and
// these flags supply the press the detent would otherwise have gated. They are fed from the
// control's own gestures -- the public surface KartPad's owner layer uses for its own shoulder
// adaptation -- and they never touch the control's pressure, which keeps flowing to the port exactly
// as the vendored control produced it.
static BOOL s_rightShoulderHeld = false;
static BOOL s_rightShoulderPressEdge = false;
// While the layout editor is up, every vendored handler returns early, so R has to be inert too.
static BOOL s_rightShoulderInert = false;
// One pending cosmetic repair per layout burst; see -ballpadScheduleShoulderRepair.
static BOOL s_shoulderRepairPending = false;
// The border the two shoulders share at rest, captured once from L rather than re-read on every
// pass, and the reason is the defect that capture removes: see -ballpadApplyShoulderRepair. The
// colour is retained because it is read from a layer and then held across passes; the capture
// happens once per process, so the retain is a single reference and not a leak that grows.
static CGFloat s_shoulderRestBorderWidth = 0.0;
static CGColorRef s_shoulderRestBorderColor = NULL;

// Whether the overlay is raising its layout editor. Decided from the one control that exists only
// while editing -- the done button the UI suite presses to leave -- rather than from the vendored
// class's live flag, which is private, and because that button is the same answer the player and the
// test get.
//
// The editor is hidden by hiding its *bar*, not the button, and a hidden ancestor still leaves a
// view's -window set. So the question is asked of the ancestors: the button is visible only when
// every view between it and the overlay is visible, which is exactly the state the editor bar's own
// -hidden flag decides. Asking the button alone would answer "editing" for the whole session and
// leave the right shoulder permanently inert.
static BOOL BallpadOverlayIsEditingLayout(UIView *overlay)
{
    UIView *done = BallpadControlLabelled(overlay, @"Finish moving touch controls");
    if (done == nil || done.window == nil)
        return NO;
    for (UIView *view = done; view != nil && view != overlay; view = view.superview)
    {
        if (view.hidden || view.alpha == 0.0)
            return NO;
    }
    return YES;
}

// The R press as the port should read it this frame: the control is held, or a tap began and ended
// between two polls. The edge is consumed here for the same reason the vendored mixer latches its
// own -- a tap shorter than a frame would otherwise be lost -- and one asserted frame is exactly what
// a physical tap of that length produces.
static BOOL BallpadRightShoulderPressed(void)
{
    const BOOL pressed = (s_rightShoulderHeld || s_rightShoulderPressEdge) && !s_rightShoulderInert;
    s_rightShoulderPressEdge = false;
    return pressed;
}

// The trigger's own drawing: the water fill and the detent line, both shape sublayers of the
// control's layer. Hiding them is the whole of "L's twin" on the drawing side; the fill, the title,
// the border and the corner radius the vendored button factory gave both shoulders are left alone.
static void BallpadHideTriggerArtwork(UIView *shoulder)
{
    for (CALayer *layer in shoulder.layer.sublayers)
    {
        if ([layer isKindOfClass:CAShapeLayer.class])
            layer.hidden = YES;
    }
}

// L's and R's live geometry side by side, because "R looks like L" is a claim a reader should be
// able to check without a screenshot: the frames and bounds come from the two views after both the
// vendored layout pass and the repair have run, and the corner radius and border are read back from
// the layers that draw them. The one part of R that is deliberately *not* L's twin is the trigger's
// own artwork, so it is reported as the count of shape sublayers still visible -- zero is the
// expected answer, and any other number says the hidden-only pass above missed something.
//
// Written on change rather than per call, because the caller is -layoutSubviews and a UIKit
// animation (the control-hide transition, a rotation, the editor's own bar) drives that method every
// frame. The fingerprint covers what the repair is supposed to control, so the line appears when a
// vendored pass undid something, which is the event worth reading about, and stays quiet when the
// same geometry is applied again.
static void BallpadLogShoulderGeometry(UIView *overlay, NSString *what)
{
    UIView *left = BallpadControlLabelled(overlay, @"L");
    UIView *right = BallpadControlLabelled(overlay, @"R");
    if (left == nil || right == nil)
    {
        BallpadLog(@"shoulder: %@ -- L %@, R %@", what,
                   left != nil ? @"found" : @"missing", right != nil ? @"found" : @"missing");
        return;
    }

    NSUInteger artwork = 0;
    for (CALayer *layer in right.layer.sublayers)
        if ([layer isKindOfClass:CAShapeLayer.class] && !layer.hidden)
            artwork++;

    const BOOL sameBorder = left.layer.borderColor == NULL || right.layer.borderColor == NULL
        ? (left.layer.borderColor == right.layer.borderColor)
        : CGColorEqualToColor(left.layer.borderColor, right.layer.borderColor);

    NSArray<NSNumber *> *fingerprint = @[
        @((long long)(left.bounds.size.width * 100.0)),
        @((long long)(left.bounds.size.height * 100.0)),
        @((long long)(right.bounds.size.width * 100.0)),
        @((long long)(right.bounds.size.height * 100.0)),
        @((long long)(left.frame.origin.x * 100.0)),
        @((long long)(right.frame.origin.x * 100.0)),
        @((long long)(left.frame.origin.y * 100.0)),
        @((long long)(right.frame.origin.y * 100.0)),
        @((long long)(left.layer.cornerRadius * 100.0)),
        @((long long)(right.layer.cornerRadius * 100.0)),
        @((long long)(left.layer.borderWidth * 100.0)),
        @((long long)(right.layer.borderWidth * 100.0)),
        @(sameBorder ? 1 : 0),
        @((long long)artwork),
        // The layout editor is the one state in which the pair is deliberately not kept in step,
        // so it belongs in the fingerprint as well: with it out, opening or closing the editor
        // would change the reading below without changing the key, and the line that says which
        // state the numbers came from would never be written.
        @(BallpadOverlayIsEditingLayout(overlay) ? 1 : 0),
    ];
    static NSArray<NSNumber *> *s_seen = nil;
    if (s_seen != nil && [s_seen isEqualToArray:fingerprint])
        return;
    s_seen = fingerprint;

    // The two numbers that say "one drawn thing, drawn twice" without a picture: how far each
    // shoulder sits from its own edge of the surface, and the row each one is on. They are derived
    // from the live frames rather than reported by the repair, so a repair that stopped mirroring
    // the pair would print the difference here instead of covering it up.
    const CGFloat leftInset = CGRectGetMinX(left.frame);
    const CGFloat rightInset = CGRectGetWidth(overlay.bounds) - CGRectGetMaxX(right.frame);
    const CGFloat rowDelta = CGRectGetMinY(right.frame) - CGRectGetMinY(left.frame);

    BallpadLog(@"shoulder: %@ -- editing %d | L frame %@ bounds %@ R frame %@ bounds %@; "
               @"corner L %.1f R %.1f, border L %.1f R %.1f %@, mirror inset L %.1f R %.1f "
               @"row delta %.1f, R visible shape layers %lu, R class %@, R value %@",
               what, BallpadOverlayIsEditingLayout(overlay) ? 1 : 0,
               NSStringFromCGRect(left.frame), NSStringFromCGSize(left.bounds.size),
               NSStringFromCGRect(right.frame), NSStringFromCGSize(right.bounds.size),
               (double)left.layer.cornerRadius, (double)right.layer.cornerRadius,
               (double)left.layer.borderWidth, (double)right.layer.borderWidth,
               sameBorder ? @"same" : @"differs",
               (double)leftInset, (double)rightInset, (double)rowDelta,
               (unsigned long)artwork, NSStringFromClass(right.class), right.accessibilityValue ?: @"none");
}
// L's and R's press state, sampled every frame rather than on the layout pass the geometry line
// above is written from. The repair runs in -layoutSubviews and a press does not re-lay the overlay
// out, so a press is invisible to that line -- and the two shoulders do not publish a press the
// same way:
//
//   * L is a plain SunPadGameButton, and the vendored pass presses a plain button by scaling it to
//     0.92. Its outline never moves, so that transform is the whole of its press state.
//   * R is the vendored SunPadTriggerButton, the one control with a detent: at or past 0.75 of its
//     width the vendored pass writes a 3.0 outline and below it the at-rest 2.0. Its transform
//     never moves, so that outline is the whole of its press state.
//
// Which is why a width on its own cannot name a press, and why an earlier version of this line
// could not either: it read 3.0 as "at the detent", and while the layout editor is open the
// vendored -updateControlAppearance paints 3.0 on *every* control, both shoulders included. Those
// lines were counted as a press on the wrong shoulder -- a fault that had not happened. So the line
// names the editor, and names each shoulder's own press state beside its width, rather than leaving
// the reader to infer a press from a number that has a second meaning.
static void BallpadLogShoulderOutlineIfChanged(UIView *overlay)
{
    // The two controls are found once and then held, because this sampler does run every frame -- a
    // press is an edge and a sampler that missed it would be reporting a control nobody touched --
    // and BallpadControlLabelled is a recursive walk of the drawn tree comparing an accessibility
    // label at every node. Twice a frame, for the whole of a match, to answer a question whose
    // answer is the same object every time. The cache is keyed on the overlay, so a rebuilt one
    // re-derives them, and a control that has left the tree is re-derived too.
    static __weak UIView *s_readFrom = nil;
    static __weak UIView *s_left = nil;
    static __weak UIView *s_right = nil;
    if (overlay != s_readFrom || s_left == nil || s_right == nil ||
        s_left.superview == nil || s_right.superview == nil)
    {
        s_readFrom = overlay;
        s_left = BallpadControlLabelled(overlay, @"L");
        s_right = BallpadControlLabelled(overlay, @"R");
    }
    UIView *left = s_left;
    UIView *right = s_right;
    if (left == nil || right == nil)
        return;

    const BOOL editing = BallpadOverlayIsEditingLayout(overlay);
    const BOOL leftHeld = !CGAffineTransformIsIdentity(left.transform);
    const BOOL rightHeld = s_rightShoulderHeld;
    const CGFloat lw = left.layer.borderWidth;
    const CGFloat rw = right.layer.borderWidth;

    static BOOL s_editing = NO;
    static BOOL s_leftHeld = NO;
    static BOOL s_rightHeld = NO;
    static CGFloat s_leftWidth = -1.0;
    static CGFloat s_rightWidth = -1.0;
    if (editing == s_editing && leftHeld == s_leftHeld && rightHeld == s_rightHeld &&
        lw == s_leftWidth && rw == s_rightWidth)
        return;
    s_editing = editing;
    s_leftHeld = leftHeld;
    s_rightHeld = rightHeld;
    s_leftWidth = lw;
    s_rightWidth = rw;

    NSString *reading = nil;
    if (editing)
        reading = @"the layout editor is open, so both outlines are the editor's own and neither is "
                  @"a press";
    else if (leftHeld && rightHeld)
        reading = @"both shoulders are held, and each carries its own press state";
    else if (leftHeld)
        reading = @"the left shoulder is held at the at-rest width, which is the whole of what a "
                  @"plain button draws";
    else if (rightHeld && rw > lw)
        reading = @"the right trigger is held past its detent, the one press a shoulder draws as a "
                  @"wider outline";
    else if (rightHeld)
        reading = @"the right trigger is held below its detent, so it keeps the at-rest width";
    else
        reading = @"neither shoulder is held, so both are at rest";

    BallpadLog(@"shoulder outline: editing %d | L held %d border %.1f | R held %d border %.1f -- %@",
               editing ? 1 : 0, leftHeld ? 1 : 0, (double)lw, rightHeld ? 1 : 0, (double)rw,
               reading);
}


// ── The planted stick zone ("your thumb becomes the analog stick") ────────────
//
// SunPad's stick is absolute and its own face is the whole of the place a thumb may land: the touch
// is read as an offset from the stick's centre, so where it lands on that circle *is* the value. That
// is right for a thumb already resting there and wrong for the first frame of every touch, when the
// hand is coming down on a picture it is looking at rather than on a control it can see. On this
// surface a thumb that lands 6pt off the centre reads as a small kick and a thumb that lands on the
// rim reads as full deflection -- from the same intent, because the intent is "somewhere on the
// stick" and the circle is not what the player is aiming at.
//
// The fix is the shape KartPad uses: the stick gets an area larger than its own face, and the touch
// *is* the stick. A thumb that lands anywhere in that area moves the stick under itself and starts
// it centred, so the value is read from how far the thumb has travelled since it landed rather than
// from where it happened to land. That is the accuracy the picture needs -- a thumb knows its own
// displacement far better than it knows a circle it cannot see -- and it costs nothing on the ports
// side, because the value still leaves through the stick's own valueChanged block: the mixer, the
// port's pad and the engine see exactly what they saw before, from a stick that happens to be
// somewhere else on the screen.
//
// The zone is a plain view that sits directly above the stick it serves and below every button, so
// it owns the touches that begin on or near that stick and none that begin on a button -- the
// vendored face cluster keeps its own taps and the editor keeps its own gestures. The vendored class
// is reached by two selectors and only two, -reset and -setValueX:y:, both of which it declares; no
// vendored byte changes and no control is re-created.
static const CGFloat kBallpadPlantedZoneMarginRatio = 0.30;
static const void *BallpadPlantedZonesKey = &BallpadPlantedZonesKey;

// The vendored value path, declared and then called through, and the one part of the stick's
// interface this file cannot reach by name. The stick's setter moves its thumb; the value the engine
// reads is published from the stick's own valueChanged block, which the overlay turns into
// -stickChanged:x:y: and which is what feeds the mixer and the port's pad. So the zone publishes
// through the overlay exactly as the stick would have, and what the mixer and the engine receive is
// the same message from the same method they have always received -- from a stick that is somewhere
// else on the screen rather than under the thumb.
@interface SunPadGameOverlay (BallpadStickHooks)
- (void)stickChanged:(UIView *)stick x:(float)x y:(float)y;
@end

// The other selector of the vendored stick's private interface that this file drives it through. It
// is sent by name rather than declared, because declaring it would mean declaring the class, and the
// class is a detail of the vendored file: the two identifiers "move" and "c" are what the overlay
// and the UI suite both address the sticks by, and the zone is found from the stick rather than the
// other way round.
static void BallpadStickPublishValue(UIView *stick, float x, float y)
{
    SEL selector = NSSelectorFromString(@"setValueX:y:");
    if (stick == nil || ![stick respondsToSelector:selector])
        return;
    ((void (*)(id, SEL, float, float))objc_msgSend)(stick, selector, x, y);
}

static void BallpadStickReset(UIView *stick)
{
    SEL selector = NSSelectorFromString(@"reset");
    if (stick == nil || ![stick respondsToSelector:selector])
        return;
    ((void (*)(id, SEL))objc_msgSend)(stick, selector);
}

@interface BallpadPlantedZoneView : UIView
@property(nonatomic, weak) UIView *stick;
// The overlay the value leaves through. Weak like the stick, and for the same reason: the overlay
// owns the zone -- it is a subview of it -- so the zone must not be what keeps either alive.
@property(nonatomic, weak) SunPadGameOverlay *host;
@property(nonatomic) CGFloat stickRadius;
@property(nonatomic) BOOL invisibleAtRest;
@property(nonatomic, readonly) BOOL owning;
- (void)restorePlantedPosition;
- (void)ballpadEndTouch;
@end

@implementation BallpadPlantedZoneView
{
    // Where the thumb landed and where the stick sits when nothing is holding it, both in the
    // overlay's coordinates. Captured together in -ballpadPlantAt:, and together they are what makes
    // the reading relative: the value is the displacement from the plant, not from the stick's own
    // centre, so a thumb that lands anywhere reads the same for the same travel.
    CGPoint _plantPoint;
    CGPoint _restCentre;
    BOOL _owning;
    BOOL _planted;
    NSUInteger _moveSamples;
    float _lastX, _lastY;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame]))
    {
        self.backgroundColor = UIColor.clearColor;
        self.multipleTouchEnabled = NO;
        // An input surface and never a thing to read: it draws nothing, and a VoiceOver user has the
        // stick itself, which is the control this view moves. Hiding it from the tree is also what
        // keeps the stick under it hittable for the UI suite, whose hit test resolves to the topmost
        // element *in the tree* at that point.
        self.accessibilityElementsHidden = YES;
    }
    return self;
}

- (BOOL)owning { return _owning; }

- (void)restorePlantedPosition
{
    if (_owning && self.stick.superview != nil)
        self.stick.center = [self.superview convertPoint:_plantPoint toView:self.stick.superview];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    (void)event;
    if (_owning || self.stick == nil)
        return;
    _owning = YES;
    [self ballpadPlantAt:[touches.anyObject locationInView:self.superview]];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    (void)event;
    if (!_owning || self.stick == nil)
        return;
    if (!_planted)
    {
        [self ballpadPlantAt:[touches.anyObject locationInView:self.superview]];
        return;
    }
    [self ballpadDriveTo:[touches.anyObject locationInView:self.superview]];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    (void)touches;
    (void)event;
    [self ballpadEndTouch];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    (void)touches;
    (void)event;
    [self ballpadEndTouch];
}

// Touch-down becomes the exact neutral origin, including at the screen edges.
- (void)ballpadPlantAt:(CGPoint)point
{
    UIView *overlay = self.superview;
    UIView *stick = self.stick;
    if (overlay == nil || stick == nil || stick.superview == nil)
        return;

    const CGRect rest = [stick convertRect:stick.bounds toView:overlay];
    // Input starts exactly at the finger, including along screen edges.
    _plantPoint = point;
    stick.alpha = [SunPadSettings sharedSettings].controlOpacity;
    _restCentre = CGPointMake(CGRectGetMidX(rest), CGRectGetMidY(rest));
    _planted = YES;
    _moveSamples = 0;
    self.accessibilityValue = @"active";

    stick.center = [overlay convertPoint:_plantPoint toView:stick.superview];
    // Down and centred: the plant is the origin the value is read from, so the value it starts from
    // is the middle of the pad however far from the stick's own centre the thumb came down.
    [self ballpadPublishX:0.0f y:0.0f];

    // The plant is the whole of the ask, so it is a line of its own rather than a clause on another
    // read-back: where the thumb landed, how far that is from the stick's own centre, whether the
    // zone's edge had to pull the plant in toward the middle, and what the reading started from.
    // The last is the accuracy half -- a thumb that comes down off-centre starts the axis at the
    // middle rather than at the deflection a distance from the stick's own centre would have given
    // it, which is the difference between this and the stick it replaced. The size is published
    // beside the offsets so a reader can put the offset in the units it matters in, the stick's own
    // side rather than points.
    const CGFloat side = MIN(CGRectGetWidth(rest), CGRectGetHeight(rest));
    BallpadLog(@"plant: %@ side %.0f landed %.1f,%.1f offset %.1f,%.1f planted %.1f,%.1f "
               @"clamped %d reading 0.00,0.00 -- planted under the thumb and read from there",
               self.stick.accessibilityIdentifier ?: @"?", (double)side,
               (double)point.x, (double)point.y,
               (double)(point.x - CGRectGetMidX(rest)), (double)(point.y - CGRectGetMidY(rest)),
               (double)_plantPoint.x, (double)_plantPoint.y,
               CGPointEqualToPoint(point, _plantPoint) ? 0 : 1);
}

// The value, out the way the stick's own value goes. Both halves are owed because the zone has taken
// over the touch that would have produced them: the overlay's method is what reaches the mixer and
// the port, and the setter is what reaches the drawing, so the thumb on screen travels with the
// number the engine reads.
- (void)ballpadPublishX:(float)x y:(float)y
{
    UIView *stick = self.stick;
    if (stick == nil)
        return;
    BallpadStickPublishValue(stick, x, -y);
    [self.host stickChanged:stick x:x y:y];
}

- (void)ballpadDriveTo:(CGPoint)point
{
    UIView *stick = self.stick;
    if (stick == nil)
        return;
    // The vendored radius, so the travel between the middle and full deflection is the stick's own
    // and only the origin has moved. Positive Y is up, hence the negation, exactly as in the
    // vendored handler -- the only difference between the two is which point the offset is taken
    // from.
    const CGFloat radius = MAX(1.0, self.stickRadius);
    CGFloat dx = (point.x - _plantPoint.x) / radius;
    CGFloat dy = (point.y - _plantPoint.y) / radius;
    const CGFloat length = hypot(dx, dy);
    if (length > 1.0)
    {
        dx /= length;
        dy /= length;
    }
    _moveSamples++;
    _lastX = dx;
    _lastY = -dy;
    [self ballpadPublishX:(float)dx y:(float)-dy];
}

// Letting go puts the stick back where the layout put it. The put-back is a no-op when a layout pass
// has already restored it -- which is what happens if the surface turned or a setting changed
// mid-hold -- so it is one assignment that can never fight the vendored pass for the position.
- (void)ballpadEndTouch
{
    if (!_owning)
        return;
    _owning = NO;
    BallpadLog(@"floating release: %@ samples %lu last %.3f,%.3f -> neutral; hidden %d",
               self.stick.accessibilityIdentifier, (unsigned long)_moveSamples,
               _lastX, _lastY, self.invisibleAtRest);
    self.accessibilityValue = @"idle";
    UIView *stick = self.stick;
    if (stick != nil)
    {
        BallpadStickReset(stick);
        if (_planted && self.superview != nil && stick.superview != nil)
            stick.center = [self.superview convertPoint:_restCentre toView:stick.superview];
    }
    if (self.invisibleAtRest)
        stick.alpha = 0.0;
    _planted = NO;
}

@end

// A vendored control by the identifier it publishes, for the callers that need the control *and* the
// identifier the store names it by. Recursive for the same reason BallpadControlLabelled is: this
// tree is a dozen controls deep at most, and the walk is once per layout pass rather than per frame.
static UIView *BallpadControlWithIdentifier(UIView *root, NSString *identifier)
{
    if (identifier.length > 0 && [root.accessibilityIdentifier isEqualToString:identifier])
        return root;
    for (UIView *subview in root.subviews)
    {
        UIView *found = BallpadControlWithIdentifier(subview, identifier);
        if (found != nil)
            return found;
    }
    return nil;
}

// One zone per stick, made on demand and kept on the overlay. Inserted directly above its stick,
// which is where it must be and stays: everything the overlay draws over the sticks is added after
// them, so a zone placed here is under the whole face cluster and over its own stick alone.
static BallpadPlantedZoneView *BallpadPlantedZoneForStick(SunPadGameOverlay *overlay, UIView *stick)
{
    NSString *identifier = stick.accessibilityIdentifier;
    if (identifier.length == 0)
        return nil;

    NSMutableDictionary<NSString *, BallpadPlantedZoneView *> *zones =
        objc_getAssociatedObject(overlay, BallpadPlantedZonesKey);
    if (zones == nil)
    {
        zones = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(overlay, BallpadPlantedZonesKey, zones,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    BallpadPlantedZoneView *zone = zones[identifier];
    if (zone == nil)
    {
        zone = [[BallpadPlantedZoneView alloc] initWithFrame:stick.frame];
        zone.stick = stick;
        zone.host = overlay;
        zones[identifier] = zone;
        [overlay insertSubview:zone aboveSubview:stick];
    }
    return zone;
}

// The zone as drawn, beside the stick it serves and the numbers a reader needs to check that it is
// larger than the stick and that it is not swallowing a control: the four distances a thumb may land
// from the stick's own centre (left, up, right, down) before the zone's edge clamps the plant, and
// every drawn control whose frame shares the zone's. A shared frame is not by itself a defect -- a
// button drawn over the zone is above it and keeps its own taps -- which is why this is reported
// rather than judged, and why the sentence says which way the precedence runs.
static void BallpadLogPlantedZonesIfChanged(SunPadGameOverlay *overlay)
{
    NSMutableArray<NSString *> *segments = [NSMutableArray array];
    NSMutableArray<NSString *> *covered = [NSMutableArray array];
    NSMutableDictionary<NSString *, BallpadPlantedZoneView *> *zones =
        objc_getAssociatedObject(overlay, BallpadPlantedZonesKey);

    for (NSString *identifier in @[ @"move", @"c" ])
    {
        UIView *stick = BallpadControlWithIdentifier(overlay, identifier);
        BallpadPlantedZoneView *zone = zones[identifier];
        if (stick == nil || zone == nil)
        {
            [segments addObject:[NSString stringWithFormat:@"%@ no zone", identifier]];
            continue;
        }

        const CGRect rest = [stick convertRect:stick.bounds toView:overlay];
        const CGRect drawn = [zone convertRect:zone.bounds toView:overlay];
        const CGFloat halfWidth = MIN(CGRectGetWidth(rest) * 0.5, CGRectGetWidth(drawn) * 0.5);
        const CGFloat halfHeight = MIN(CGRectGetHeight(rest) * 0.5, CGRectGetHeight(drawn) * 0.5);
        const CGFloat side = MIN(CGRectGetWidth(rest), CGRectGetHeight(rest));
        [segments addObject:[NSString stringWithFormat:
            @"%@ zone %.0fx%.0f @%.0f,%.0f stick %.0fx%.0f @%.0f,%.0f radius %.0f margin %.0f "
            @"plant l%.0f u%.0f r%.0f d%.0f inert %d",
            identifier, (double)CGRectGetWidth(drawn), (double)CGRectGetHeight(drawn),
            (double)CGRectGetMinX(drawn), (double)CGRectGetMinY(drawn),
            (double)CGRectGetWidth(rest), (double)CGRectGetHeight(rest),
            (double)CGRectGetMinX(rest), (double)CGRectGetMinY(rest),
            (double)zone.stickRadius, (double)(side * kBallpadPlantedZoneMarginRatio),
            (double)(CGRectGetMidX(rest) - (CGRectGetMinX(drawn) + halfWidth)),
            (double)(CGRectGetMidY(rest) - (CGRectGetMinY(drawn) + halfHeight)),
            (double)((CGRectGetMaxX(drawn) - halfWidth) - CGRectGetMidX(rest)),
            (double)((CGRectGetMaxY(drawn) - halfHeight) - CGRectGetMidY(rest)),
            zone.userInteractionEnabled ? 0 : 1]];

        for (UIView *other in BallpadTouchControlsInDrawOrder(overlay))
        {
            if (other == stick || other.hidden || other.alpha == 0.0)
                continue;
            const CGRect frame = [other convertRect:other.bounds toView:overlay];
            if (CGRectIntersectsRect(frame, drawn))
                [covered addObject:[NSString stringWithFormat:@"%@ is under %@",
                                    identifier, other.accessibilityIdentifier ?: @"?"]];
        }
    }

    NSString *line = [NSString stringWithFormat:@"%@ | %@",
                      [segments componentsJoinedByString:@" | "],
                      covered.count > 0 ? [covered componentsJoinedByString:@"; "]
                                        : @"no drawn control shares a stick's zone"];
    static NSString *s_seen = nil;
    if ([line isEqualToString:s_seen])
        return;
    s_seen = line;
    // Written on change for the reason the other read-backs are: the caller is -layoutSubviews, and
    // this line's whole value is that it is the state a reader can line up with a turn, a resize or a
    // hide rather than a copy of the same numbers every pass.
    BallpadLog(@"planted zone: editing %d %@ -- a stick's zone is its own face plus that margin, a "
               @"thumb that lands anywhere in it moves the stick under itself and reads from there, "
               @"and the four plant distances are how far from the stick's own centre it may land "
               @"before the zone's edge clamps the plant (left, up, right, down)",
               BallpadOverlayIsEditingLayout(overlay) ? 1 : 0, line);
}


// ── Hiding a control ("easily hide and rearrange all buttons") ────────────────
//
// Rearranging is the vendored editor's own drag and resizing is its own slider, but the vendored file
// has no answer for taking a control out of the picture. Its one visibility control is global -- every
// control, when a physical controller is connected -- which is the wrong shape for the question a
// player asks here: this device is held one way, this game wants six buttons, and the four that are
// not being used are in the way of the thumb that is.
//
// So the editor's bar gains one toggle, beside the size slider and Done, that hides or shows the
// control the player last selected. The set is Ballpad's own store entry because the feature is
// Ballpad's own and the vendored file must not learn about it; and the vendored reset clears it, so a
// player who hides a control and then forgets which one has one place to look -- the settings panel's
// own "Reset This Device Layout", which the UI suite already drives through its own confirmation
// alert.
//
// The D-pad is one entry under the group's own name rather than four, because the vendored editor
// already governs the four directional buttons as one control: their frames are the group's and the
// editor enables no gesture on them individually. Hiding them one at a time would leave a cross with
// a hole in it, which is not a thing a player can press either way.
static NSString * const kBallpadHiddenControlsKey = @"BallpadHiddenTouchControls";
static NSString * const kBallpadDPadGroupIdentifier = @"D-pad";
// What a hidden control is drawn at while the editor is up. Faint rather than absent, because a
// control the player cannot see is a control they cannot select, and selecting one is how it comes
// back -- the toggle acts on the selection, so the selection has to be reachable.
static const CGFloat kBallpadHiddenControlEditingAlpha = 0.30;
static const CGFloat kBallpadHideButtonHeight = 40.0;
static const CGFloat kBallpadHideButtonMinWidth = 82.0;

static NSMutableSet<NSString *> *s_ballpadHiddenControls = nil;

// The control the editor is working on, which is the one the toggle acts on. The vendored ivar is
// private and is not readable from here, so this is the same fact kept again rather than borrowed --
// weak, and set from the vendored selection, which both of the editor's gestures route through. It
// is cleared whenever the editor is not up, so a selection can never outlive the bar it was made in.
static __weak UIView *s_selectedControl = nil;

static NSMutableSet<NSString *> *BallpadHiddenControls(void)
{
    if (s_ballpadHiddenControls == nil)
    {
        s_ballpadHiddenControls = [NSMutableSet set];
        for (id entry in [[NSUserDefaults standardUserDefaults]
                             arrayForKey:kBallpadHiddenControlsKey])
            if ([entry isKindOfClass:NSString.class] && [entry length] > 0)
                [s_ballpadHiddenControls addObject:entry];
    }
    return s_ballpadHiddenControls;
}

// Written on every change rather than at exit: this is a preference a player sets and then expects
// to hold, and a control that came back on the next launch would be a control they hid twice.
static void BallpadWriteHiddenControls(void)
{
    [[NSUserDefaults standardUserDefaults] setObject:BallpadHiddenControls().allObjects
                                              forKey:kBallpadHiddenControlsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

// The store entry a control is hidden under, or nil for a control that has none to be hidden under.
// The four directional buttons and their container are one entry, for the reason above; every other
// control is hidden under the identifier it already publishes.
static NSString *BallpadHiddenIdentifierForControl(UIView *control)
{
    NSString *identifier = control.accessibilityIdentifier;
    if (identifier.length == 0)
        return nil;
    if ([identifier hasPrefix:@"D_"] || [identifier isEqualToString:@"ExperimentalDPad"])
        return kBallpadDPadGroupIdentifier;
    return identifier;
}

static NSArray<UIView *> *BallpadControlsForHiddenIdentifier(UIView *overlay, NSString *identifier)
{
    if ([identifier isEqualToString:kBallpadDPadGroupIdentifier])
    {
        NSMutableArray<UIView *> *group = [NSMutableArray array];
        for (NSString *direction in @[ @"D_U", @"D_D", @"D_L", @"D_R" ])
        {
            UIView *button = BallpadControlWithIdentifier(overlay, direction);
            if (button != nil)
                [group addObject:button];
        }
        UIView *container = BallpadControlLabelled(overlay, kBallpadDPadGroupIdentifier);
        if (container != nil)
            [group addObject:container];
        return group;
    }
    UIView *control = BallpadControlWithIdentifier(overlay, identifier);
    return control != nil ? @[ control ] : @[];
}


// ── SunPad's menu, under a Ballpad header ─────────────────────────────────────
// Declaring the vendored class's private methods is what makes the overrides below legal while the
// vendored file keeps its bytes. -buildMenu, -refreshMenuButton, -confirmGameDataRemoval and
// -reportProblem are the four this file reaches; each is overridden or called, never redefined.
@interface SunPadGameOverlay (BallpadMenuHooks)
- (UIMenu *)buildMenu;
- (void)refreshMenuButton;
- (void)updateControlAppearance;
- (void)confirmGameDataRemoval;
- (void)reportProblem;
@end

// The vendored editor's own ends, declared for the same reason and used the same way: the hide
// toggle acts on the control the editor has selected, so the selection and the two ends of an edit
// session are the three places this file has to hear about. Each of the three below calls through to
// the vendored method and adds one thing after it -- a remembered selection, the layout pass the
// exit does not run for itself, and the clearing of Ballpad's own layout store -- so the vendored
// editor keeps deciding how an edit behaves and this file only learns when one happened.
@interface SunPadGameOverlay (BallpadEditorHooks)
- (void)selectControlForEditing:(UIView *)control;
- (void)beginLayoutEditing;
- (void)endLayoutEditing;
- (void)resetLayout;
@end

// A full sheet keeps the report readable when the iPad keyboard is visible.
@interface BallpadReportViewController : UIViewController <UITextFieldDelegate, UITextViewDelegate>
@property(nonatomic, strong) UIScrollView *formScroll;
@property(nonatomic, strong) UITextField *summaryField;
@property(nonatomic, strong) UITextView *detailsField;
@property(nonatomic, strong) UISegmentedControl *frequency;
@property(nonatomic, copy) void (^completion)(NSDictionary<NSString *, NSString *> *, NSInteger);
@end

@implementation BallpadReportViewController
- (void)viewDidLoad
{
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    UINavigationBar *bar = [UINavigationBar new];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    UINavigationItem *item = [[UINavigationItem alloc] initWithTitle:@"Report a Problem"];
    item.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
        target:self action:@selector(cancel)];
    item.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Continue"
        style:UIBarButtonItemStyleDone target:self action:@selector(prepare)];
    item.rightBarButtonItem.accessibilityIdentifier = @"Prepare GitHub Report";
    [bar setItems:@[item]];
    [self.view addSubview:bar];
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    scroll.accessibilityIdentifier = @"BallpadReportForm";
    self.formScroll = scroll;
    [self.view addSubview:scroll];
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [bar.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [bar.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:bar.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-48],
    ]];
    [stack addArrangedSubview:[self label:@"Help us reproduce the problem" style:UIFontTextStyleTitle2]];
    [stack addArrangedSubview:[self label:@"Your report opens in the BallPad GitHub repository. A diagnostic log is saved on this device for you to attach. Nothing is submitted automatically." style:UIFontTextStyleBody]];
    [stack addArrangedSubview:[self label:@"Summary" style:UIFontTextStyleHeadline]];
    self.summaryField = [UITextField new];
    self.summaryField.borderStyle = UITextBorderStyleRoundedRect;
    self.summaryField.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.summaryField.adjustsFontForContentSizeCategory = YES;
    self.summaryField.delegate = self;
    self.summaryField.returnKeyType = UIReturnKeyNext;
    self.summaryField.placeholder = @"What went wrong?";
    self.summaryField.accessibilityLabel = @"What went wrong?";
    [self.summaryField.heightAnchor constraintGreaterThanOrEqualToConstant:48].active = YES;
    [stack addArrangedSubview:self.summaryField];
    [stack addArrangedSubview:[self label:@"Steps and details" style:UIFontTextStyleHeadline]];
    self.detailsField = [UITextView new];
    self.detailsField.delegate = self;
    self.detailsField.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.detailsField.adjustsFontForContentSizeCategory = YES;
    self.detailsField.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    self.detailsField.layer.cornerRadius = 12;
    self.detailsField.textContainerInset = UIEdgeInsetsMake(12, 12, 12, 12);
    self.detailsField.accessibilityLabel = @"Steps and details";
    [self.detailsField.heightAnchor constraintEqualToConstant:160].active = YES;
    [stack addArrangedSubview:self.detailsField];
    [stack addArrangedSubview:[self label:@"Include the game mode, stadium, and what happened before the problem." style:UIFontTextStyleFootnote]];
    [stack addArrangedSubview:[self label:@"How often?" style:UIFontTextStyleHeadline]];
    self.frequency = [[UISegmentedControl alloc] initWithItems:@[@"Always", @"Sometimes", @"Once", @"Not sure"]];
    self.frequency.selectedSegmentIndex = 3;
    self.frequency.accessibilityLabel = @"Problem frequency";
    [self.frequency.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [stack addArrangedSubview:self.frequency];
    [stack addArrangedSubview:[self label:@"github.com/chrissotraidis/ballpad" style:UIFontTextStyleFootnote]];
    for (NSInteger tag = 1; tag <= 2; tag++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        UIButtonConfiguration *config = UIButtonConfiguration.tintedButtonConfiguration;
        config.title = tag == 1 ? @"Share Report…" : @"Save to Files";
        button.configuration = config;
        button.tag = tag;
        [button addTarget:self action:@selector(exportReport:) forControlEvents:UIControlEventTouchUpInside];
        [stack addArrangedSubview:button];
    }
}
- (UILabel *)label:(NSString *)text style:(UIFontTextStyle)style
{
    UILabel *label = [UILabel new];
    label.text = text;
    label.numberOfLines = 0;
    label.font = [UIFont preferredFontForTextStyle:style];
    label.adjustsFontForContentSizeCategory = YES;
    label.textColor = [style isEqualToString:UIFontTextStyleFootnote] ? UIColor.secondaryLabelColor : UIColor.labelColor;
    return label;
}
- (void)revealEditor:(UIView *)editor
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.view layoutIfNeeded];
        CGRect rect = [editor convertRect:editor.bounds toView:self.formScroll];
        [self.formScroll scrollRectToVisible:CGRectInset(rect, 0, -12) animated:YES];
    });
}
- (void)textViewDidBeginEditing:(UITextView *)textView { [self revealEditor:textView]; }
- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    [self.detailsField becomeFirstResponder];
    return NO;
}
- (void)cancel { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)prepare { [self finish:0]; }
- (void)exportReport:(UIButton *)sender { [self finish:sender.tag]; }
- (void)finish:(NSInteger)destination
{
    NSDictionary *answers = @{@"problem": self.summaryField.text ?: @"",
        @"context": self.detailsField.text ?: @"",
        @"frequency": [self.frequency titleForSegmentAtIndex:self.frequency.selectedSegmentIndex] ?: @"Not sure"};
    [self.view endEditing:YES];
    void (^completion)(NSDictionary *, NSInteger) = self.completion;
    [self dismissViewControllerAnimated:YES completion:^{ if (completion) completion(answers, destination); }];
}
@end

@interface BallpadGameOverlay : SunPadGameOverlay
@property(nonatomic, strong) UILongPressGestureRecognizer *ballpadRightPress;
// The right shoulder's own press and appearance, wired and applied from -layoutSubviews; the flags
// they read and set are above, next to the reason they exist.
- (void)ballpadRightShoulderGesture:(UILongPressGestureRecognizer *)gesture;
- (void)ballpadApplySafeAreaContainment;
- (void)ballpadApplyShoulderRepair;
- (void)ballpadScheduleShoulderRepair;
- (void)ballpadWireRightShoulder:(UIView *)right;
@end

@implementation BallpadGameOverlay

#pragma mark - The menu

// Retain the existing actions and their handlers, grouped by what the player changes.
// A menu element that contributes no rows and exists to be *asked*. The vendored button holds its
// menu in `_menuButton.menu`, a built object UIKit displays without calling back into the app, so
// -buildMenu running is a menu being rebuilt rather than a menu being opened -- and opened is the
// moment the frame sharing needs. An uncached deferred element is the documented way to be called
// at that moment: UIKit asks its provider every time the menu is presented, and a provider that
// completes immediately with nothing adds no row and no delay.
- (UIDeferredMenuElement *)ballpadMenuOpenNotice
{
    return [UIDeferredMenuElement elementWithUncachedProvider:
        ^(void (^completion)(NSArray<UIMenuElement *> *elements)) {
            s_menuInteractionUntil = CACurrentMediaTime() + kBallpadMenuInteractionSeconds;
            completion(@[]);
        }];
}

- (UIMenu *)buildMenu
{
    // A rebuild follows a row being tapped, which is also a moment UIKit is busy -- presenting a
    // sheet, or animating the menu away. The notice above is what catches the menu being opened.
    s_menuInteractionUntil = CACurrentMediaTime() + kBallpadMenuInteractionSeconds;

    UIMenu *vendored = [super buildMenu];
    if (vendored == nil)
        return nil;
    NSMutableArray<UIMenuElement *> *display = [NSMutableArray arrayWithArray:@[
        [self ballpadRenderMenu], [self ballpadAspectMenu]]];
    NSMutableArray<UIMenuElement *> *controls = [NSMutableArray array];
    NSMutableArray<UIMenuElement *> *other = [NSMutableArray array];
    for (UIMenuElement *element in vendored.children)
    {
        NSString *title = element.title;
        if ([title isEqualToString:@"Show FPS Counter"])
            [display addObject:element];
        else if ([title isEqualToString:@"Controller Button Mapping…"] ||
                 [title isEqualToString:@"Touch Control Settings…"])
            [controls addObject:element];
        else if ([title isEqualToString:@"Game Data & Saves"])
            [other addObject:[self ballpadGameDataMenu]];
        else if (![title isEqualToString:@"Render Resolution"] &&
                 ![title isEqualToString:@"Aspect Ratio"] &&
                 ![title hasPrefix:@"Experimental"])
            [other addObject:element];
    }
    [controls addObject:[self ballpadHideMenuButtonAction]];
    NSMutableArray<UIMenuElement *> *children = [NSMutableArray arrayWithArray:@[
        [self ballpadMenuOpenNotice],
        [UIMenu menuWithTitle:@"Display" children:display],
        [UIMenu menuWithTitle:@"Controls" children:controls],
        [self ballpadExperimentalMenu]]];
    [children addObjectsFromArray:other];
    [children addObject:[self ballpadAboutAction]];
    return [UIMenu menuWithTitle:BallpadAppDisplayName() children:children];
}

// The one control on screen for a whole match that is not part of the game. The row is a toggle
// rather than a one-way hide, and it carries its own way back in the subtitle, because a button that
// can be hidden with no stated way to return is a setting a player cannot undo.
- (UIAction *)ballpadHideMenuButtonAction
{
    __weak BallpadGameOverlay *weakSelf = self;
    const BOOL hidden = BallpadMenuButtonIsHidden();
    UIAction *action = [UIAction actionWithTitle:@"Hide Menu Button"
                                           image:[UIImage systemImageNamed:@"eye.slash"]
                                      identifier:nil
                                         handler:^(__kindof UIAction *selected) {
        (void)selected;
        BallpadSetMenuButtonHidden(weakSelf, !BallpadMenuButtonIsHidden());
        [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
        BallpadLogSettingsSnapshot(@"menu hide menu button");
        [weakSelf refreshMenuButton];
    }];
    action.subtitle = @"Two-finger tap anywhere to bring it back";
    action.state = hidden ? UIMenuElementStateOn : UIMenuElementStateOff;
    return action;
}

#pragma mark - Render resolution (item 5)

// Same title, same rows, same order, same "N×" labels as the vendored submenu. What changes is what
// a row does: the vendored body stops at the setting, this one also pins the port's render scale,
// so the row is the one place a resolution can be chosen from and the choice reaches the renderer.
- (UIMenu *)ballpadRenderMenu
{
    return [UIMenu menuWithTitle:@"Render Resolution" children:@[
        [self ballpadRenderAction:@"1× (Native)" scale:1],
        [self ballpadRenderAction:@"2×" scale:2],
        [self ballpadRenderAction:@"3×" scale:3],
        [self ballpadRenderAction:@"4×" scale:4],
    ]];
}

- (UIAction *)ballpadRenderAction:(NSString *)title scale:(NSInteger)scale
{
    __weak BallpadGameOverlay *weakSelf = self;
    UIAction *action = [UIAction actionWithTitle:title
                                          image:nil
                                     identifier:nil
                                        handler:^(__kindof UIAction *selected) {
        (void)selected;
        [SunPadSettings sharedSettings].renderScale = scale;
        [[SunPadSettings sharedSettings] synchronize];
        [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
        // The read-back is the point: "the setting reached the renderer" is a logged fact here
        // rather than an assumption. The new target lands on the next frame, where main() turns the
        // change into the swapchain resize that Aurora's own window-resize path never sees.
        PortSetRenderScale((float)scale);
        BallpadLog(@"menu: render scale %ld; port pin now %.2f",
                   (long)scale, (double)PortRenderScale());
        BallpadLogSettingsSnapshot(@"menu render scale");
        [weakSelf refreshMenuButton];
    }];
    action.state = [SunPadSettings sharedSettings].renderScale == scale ?
        UIMenuElementStateOn : UIMenuElementStateOff;
    return action;
}

#pragma mark - Aspect ratio (item 5)

- (UIMenu *)ballpadAspectMenu
{
    return [UIMenu menuWithTitle:@"Aspect Ratio" children:@[
        [self ballpadAspectAction:@"Original 4:3" mode:SunPadAspectRatioOriginal],
        [self ballpadAspectAction:@"16:9 (Experimental)" mode:SunPadAspectRatioWidescreen],
        [self ballpadAspectAction:@"Fill Screen (Experimental)" mode:SunPadAspectRatioFillScreen],
    ]];
}

- (UIAction *)ballpadAspectAction:(NSString *)title mode:(SunPadAspectRatioMode)mode
{
    __weak BallpadGameOverlay *weakSelf = self;
    UIAction *action = [UIAction actionWithTitle:title
                                          image:nil
                                     identifier:nil
                                        handler:^(__kindof UIAction *selected) {
        (void)selected;
        [SunPadSettings sharedSettings].aspectRatioMode = mode;
        [[SunPadSettings sharedSettings] synchronize];
        [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
        // Three rows, three different destinations, because pinning all three to one value would
        // make two of them a lie. 4:3 pins the shape the game was tuned at; 16:9 pins the wide
        // value the port's own aspect code knows (640 -> 854 logical pixels, with the gameplay
        // camera blend, the locked aspect and the front end moving together); Fill Screen hands the
        // aspect back to the window, which is what filling the screen means on a device whose
        // window is not 16:9 -- an iPad, or a phone at its own corner radius.
        switch (mode)
        {
            case SunPadAspectRatioOriginal:
                PortSetTargetAspect(4.0f / 3.0f);
                break;
            case SunPadAspectRatioWidescreen:
                PortSetTargetAspect(16.0f / 9.0f);
                break;
            case SunPadAspectRatioFillScreen:
                PortSetTargetAspect(-1.0f);
                break;
        }
        // The pinned value, not the framebuffer width: the width is re-derived from the new aspect
        // on the next frame, so reading it here would log the value that is on its way out.
        BallpadLog(@"menu: aspect %@; port pin now %.3f, follows window %d",
                   title, (double)PortTargetAspect(), PortAspectFollowsWindow());
        BallpadLogSettingsSnapshot(@"menu aspect ratio");
        [weakSelf refreshMenuButton];
    }];
    action.state = [SunPadSettings sharedSettings].aspectRatioMode == mode ?
        UIMenuElementStateOn : UIMenuElementStateOff;
    return action;
}

#pragma mark - The Experimental submenu

// Advanced frame-rate control stays separate from everyday display settings.
- (UIMenu *)ballpadExperimentalMenu
{
    return [UIMenu menuWithTitle:@"Experimental" children:@[
        [self ballpadFrameLimitAction],
    ]];
}

#pragma mark - Frame rate limit (items 11 and 12)

// Item 12 is why there is no performance row here: the vendored one toggled a 90% emulated CPU
// clock, and a native port has no emulated clock to slow, so the row would be a switch that does
// nothing -- the placeholder doc 33 forbids shipping. The one action below is what stands where
// item 11's row was, and it is named for what it does on this runtime.
- (UIAction *)ballpadFrameLimitAction
{
    __weak BallpadGameOverlay *weakSelf = self;
    UIAction *action =
        [UIAction actionWithTitle:@"Uncapped Frame Rate"
                            image:[UIImage systemImageNamed:@"speedometer"]
                       identifier:nil
                          handler:^(__kindof UIAction *selected) {
        (void)selected;
        BOOL unlimited = !BallpadFrameLimitIsUnlimited();
        [NSUserDefaults.standardUserDefaults setBool:unlimited
                                             forKey:BallpadFrameLimitUnlimitedKey];
        [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];
        [weakSelf refreshMenuButton];

        // No "Restart Required" in here, because nothing restarts: the limiter re-derives its period
        // on the next frame. And no promise of a faster game either -- the port's logic still
        // advances once per retrace, so lifting the cap lets frames be produced as fast as they can
        // be, which is a property of the machine, not a speed-up of the game. The alert therefore
        // reports what the port reports rather than restating the title.
        PortSetFrameLimit(unlimited ? 0.0 : -1.0);
        double limitHz = 0.0;
        double displayHz = 0.0;
        int vsync = 0;
        int pinned = 0;
        PortFrameLimitInfo(&limitHz, &displayHz, &vsync, &pinned);
        NSString *now = limitHz > 0.0
            ? [NSString stringWithFormat:@"capped to %.0f Hz", limitHz]
            : @"uncapped";
        BallpadLog(@"menu: frame limit %@; port reports %@ (display %.1f Hz, vsync %d, pinned %d)",
                   unlimited ? @"uncapped" : @"display-following", now, displayHz, vsync, pinned);
        BallpadLogSettingsSnapshot(@"menu frame rate limit");

        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"Frame Rate Limit"
                                               message:[NSString stringWithFormat:
                @"The port's own limiter is now %@. Frames are still produced once per retrace, so "
                 "this changes what the limiter allows rather than the game's speed; the display "
                 "reports %.1f Hz%@.",
                now, displayHz, vsync ? @" and is paced by vsync as well" : @" with no vsync reported"]
                                        preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [weakSelf.window.rootViewController presentViewController:alert
                                                         animated:YES
                                                       completion:nil];
    }];
    action.state = BallpadFrameLimitIsUnlimited() ? UIMenuElementStateOn : UIMenuElementStateOff;
    return action;
}

#pragma mark - Game data & saves (item 9)

// The three rows are the vendored ones with the vendored handlers and the vendored icons; the
// submenu is rebuilt rather than edited because a UIMenu's children cannot be replaced in place and
// the second row's title is what item 9 changes. "SunPad Folder" becomes "BallPad Folder" and the
// handler behind it is the same one, which is the whole of that item: the row names the app it is
// in.
- (UIMenu *)ballpadGameDataMenu
{
    __weak BallpadGameOverlay *weakSelf = self;
    return [UIMenu menuWithTitle:@"Game Data & Saves" children:@[
        [UIAction actionWithTitle:@"Import or Reimport Game Data"
                            image:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath"]
                       identifier:nil
                          handler:^(__kindof UIAction *action) {
            (void)action;
            [weakSelf.delegate gameOverlayRequestsGameDataChange:weakSelf];
        }],
        [UIAction actionWithTitle:@"Import from BallPad Folder"
                            image:[UIImage systemImageNamed:@"folder"]
                       identifier:nil
                          handler:^(__kindof UIAction *action) {
            (void)action;
            [weakSelf.delegate gameOverlayRequestsGameDataFolderImport:weakSelf];
        }],
        [UIAction actionWithTitle:@"Remove Stored Game Data"
                            image:[UIImage systemImageNamed:@"trash"]
                       identifier:nil
                          handler:^(__kindof UIAction *action) {
            (void)action;
            [weakSelf confirmGameDataRemoval];
        }],
    ]];
}

#pragma mark - About & Credits (item 15)

- (UIAction *)ballpadAboutAction
{
    __weak BallpadGameOverlay *weakSelf = self;
    return [UIAction actionWithTitle:@"About & Credits…"
                               image:[UIImage systemImageNamed:@"info.circle"]
                          identifier:nil
                             handler:^(__kindof UIAction *selected) {
        (void)selected;
        BallpadLog(@"menu: about & credits opened");
        BallpadPresentOverlayViewController(weakSelf,
            [BallpadCreditsViewController creditsViewController]);
    }];
}

#pragma mark - Report a problem (item 10)

- (void)reportProblem
{
    NSString *reportID = BallpadNewReportID();
    BallpadReportViewController *form = [BallpadReportViewController new];
    __weak BallpadGameOverlay *weakSelf = self;
    form.completion = ^(NSDictionary *answers, NSInteger destination) {
        if (destination == 1) [weakSelf ballpadShareReportFromPrompt:answers reportID:reportID];
        else if (destination == 2) [weakSelf ballpadExportReportFromPrompt:answers reportID:reportID];
        else [weakSelf ballpadPrepareGitHubReportFromPrompt:answers reportID:reportID];
    };
    BallpadPresentOverlayViewController(self, form);
    form.sheetPresentationController.detents = @[UISheetPresentationControllerDetent.largeDetent];
}

// One report, built the same way for both endings so the two buttons differ only in destination.
// Returns nil after saying why, because a nil report is a failure the player has to be told about
// rather than a share sheet with nothing in it.
- (NSURL *)ballpadReportURLFromPrompt:(NSDictionary<NSString *, NSString *> *)answers reportID:(NSString *)reportID
{
    // Both delegate answers, because a report a reader cannot tell a Simulator run from a device run
    // is a report that cannot be acted on.
    NSString *technical = [NSString stringWithFormat:@"%@\nperformance=%@",
        [self.delegate gameOverlayDiagnosticContext:self],
        [self.delegate gameOverlayPerformanceProfile:self]];
    NSError *error = nil;
    NSURL *url = BallpadDiagnosticsReportURL(reportID, answers, technical, &error);
    BallpadLog(@"report %@ written=%@ file=%@", reportID, url != nil ? @"yes" : @"no",
               url.lastPathComponent ?: (error.localizedDescription ?: @"unknown error"));
    if (url != nil)
        return url;

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Diagnostic Report Unavailable"
                                            message:error.localizedDescription
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self.window.rootViewController presentViewController:alert animated:YES completion:nil];
    return nil;
}

- (void)ballpadPrepareGitHubReportFromPrompt:(NSDictionary<NSString *, NSString *> *)answers reportID:(NSString *)reportID
{
    NSURL *report = [self ballpadReportURLFromPrompt:answers reportID:reportID];
    if (report == nil)
        return;
    NSString *problem = answers[@"problem"] ?: @"";
    NSString *context = answers[@"context"] ?: @"";
    NSString *frequency = answers[@"frequency"] ?: @"";
    NSString *body = [NSString stringWithFormat:
        @"## Problem\n%@\n\n## Steps / context\n%@\n\n## Frequency\n%@\n\n"
         "## App\n%@\n%@\n\n## Diagnostic log\nReport: %@\n"
         "Attach `%@` from Files → BallPad → Diagnostics before submitting.\n",
        problem, context ?: @"", frequency ?: @"",
        [self.delegate gameOverlayDiagnosticContext:self],
        [self.delegate gameOverlayPerformanceProfile:self], reportID, report.lastPathComponent];
    NSURLComponents *issue = [NSURLComponents componentsWithString:
        @"https://github.com/chrissotraidis/ballpad/issues/new"];
    issue.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"title" value:problem.length > 0 ? problem : @"BallPad issue"],
        [NSURLQueryItem queryItemWithName:@"body" value:body]];
    UIAlertController *ready = [UIAlertController alertControllerWithTitle:@"Report Ready"
        message:[NSString stringWithFormat:@"Log saved in Files → BallPad → Diagnostics:\n%@\n\n"
            "Open GitHub, attach this log, then submit your issue.", report.lastPathComponent]
        preferredStyle:UIAlertControllerStyleAlert];
    [ready addAction:[UIAlertAction actionWithTitle:@"Open GitHub" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
            [UIApplication.sharedApplication openURL:issue.URL options:@{} completionHandler:^(BOOL success) {
                if (!success) BallpadLog(@"report: could not open the BallPad issue tracker");
            }];
        }]];
    [ready addAction:[UIAlertAction actionWithTitle:@"Share Log…" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
            UIActivityViewController *share = [[UIActivityViewController alloc]
                initWithActivityItems:@[report] applicationActivities:nil];
            share.popoverPresentationController.sourceView = self;
            share.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.bounds), 40, 1, 1);
            [self.window.rootViewController presentViewController:share animated:YES completion:nil];
        }]];
    [ready addAction:[UIAlertAction actionWithTitle:@"Done" style:UIAlertActionStyleCancel handler:nil]];
    [self.window.rootViewController presentViewController:ready animated:YES completion:nil];
}

- (void)ballpadShareReportFromPrompt:(NSDictionary<NSString *, NSString *> *)answers reportID:(NSString *)reportID
{
    NSURL *url = [self ballpadReportURLFromPrompt:answers reportID:reportID];
    if (url == nil)
        return;

    UIActivityViewController *share =
        [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    // The popover has to point at something on iPad; the three-dot button is what the vendored flow
    // used and it is still the control this came from.
    UIButton *anchor = BallpadMenuButton(self);
    UIPopoverPresentationController *popover = share.popoverPresentationController;
    popover.sourceView = anchor ?: self;
    popover.sourceRect = anchor != nil ? anchor.bounds
                                       : CGRectMake(CGRectGetMidX(self.bounds),
                                                    CGRectGetMinY(self.bounds) + 24.0, 1.0, 1.0);
    [self.window.rootViewController presentViewController:share animated:YES completion:nil];
}

- (void)ballpadExportReportFromPrompt:(NSDictionary<NSString *, NSString *> *)answers reportID:(NSString *)reportID
{
    NSURL *url = [self ballpadReportURLFromPrompt:answers reportID:reportID];
    if (url == nil)
        return;

    // A copy, not a move: the report stays in Ballpad's own folder as the record of the report, and
    // what lands in Files is the player's to keep or send.
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForExportingURLs:@[url] asCopy:YES];
    [self.window.rootViewController presentViewController:picker animated:YES completion:nil];
}

#pragma mark - Layout

// SunPad lays its own controls out here, from its own bounds and insets, and that stays the only
// thing that decides where a control goes. Four of its decisions are Ballpad's to make on this
// game's behalf, and all of them are applied after the vendored pass so the vendored layout math
// keeps its authority:
//
//   * the three-dot button gets one explicit appearance, so dismissing a primary-action menu cannot
//     synthesize a rectangular highlight over it and a rebuilt surface cannot leave it with none;
//   * the iPad defaults, which draw seven of the eleven controls on top of each other, are replaced
//     by the vendored file's own arithmetic set, for the reason -ballpadApplyPadDefaultLayout gives;
//   * a control the vendored default pass drew outside the safe rect is put back inside it, for the
//     reason -ballpadApplySafeAreaContainment gives;
//   * the right shoulder is made L's twin, for the reason its flags are documented above;
//   * each stick is given the planting zone its thumb lands in, for the reason the zone section
//     above gives;
//   * and a control the player hid in the editor stays hidden, for the reason the hide section
//     above gives. The editor's own toggle is placed from what those two decided, so it is
//     refreshed in the same pass.
- (void)updateControlAppearance
{
    [super updateControlAppearance];
    [self ballpadApplyPlantedZones];
}

- (void)layoutSubviews
{
    [super layoutSubviews];

    BallpadConfigureMenuButton(BallpadMenuButton(self));

    // The editor, where every vendored handler returns early. R follows them, and a press already in
    // flight when the editor opens is not held into it.
    const BOOL editing = BallpadOverlayIsEditingLayout(self);
    if (editing)
        s_rightShoulderHeld = false;
    s_rightShoulderInert = editing;

    [self ballpadApplyPadDefaultLayout];
    [self ballpadApplySafeAreaContainment];
    [self ballpadApplyShoulderRepair];

    // Placed from the sticks the vendored pass just placed, applied over the appearance it just
    // gave them, and -- last, because it reads both -- the editor's toggle, which is what a player
    // hides and shows a control with while the editor is open.
    [self ballpadApplyPlantedZones];
    [self ballpadApplyHiddenControlVisibility];
    [self ballpadConfigureEditorHideButton];
    [self ballpadUpdateEditorHideButton];

    [self ballpadScheduleShoulderRepair];
}

// SunPad re-lays out a control whose bounds changed after this method returns, and the trigger's own
// layout pass re-derives its border and its accessibility value when it runs -- so a repair applied
// only here would be undone by the very pass it provoked. One turn later is when that pass has
// certainly happened, and the flag coalesces a burst of layouts into one pending turn.
- (void)ballpadScheduleShoulderRepair
{
    if (s_shoulderRepairPending)
        return;
    s_shoulderRepairPending = true;
    __weak BallpadGameOverlay *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        s_shoulderRepairPending = false;
        [weakSelf ballpadApplyShoulderRepair];
    });
}

// A control the vendored default pass drew outside the surface's safe rect. -placeControl: clamps a
// *saved* origin and does not clamp its own default, and the phone defaults are normalized centres
// captured at a control size scale of 1.0 -- Z's 0.97125 is one, and it sits exactly on the safe
// rect's right edge at that scale, which is why the constant has the value it has. The scale runs to
// 1.35 globally and to 1.75 for a single control, and a control already on the edge at 1.0 grows
// straight out of the rect when the scale is raised: on the iPhone 17e the layout read-back caught
// `judged 14 outside 1 (Z {{746.328125, 131.87}, {58.21875, 58.21875}})` against a safe rect ending
// at 797, which is 7.5pt of that button under the display's rounded corner. It survived a relaunch,
// because the scale that grew the control is persisted and nothing in the default pass puts a
// default back inside.
//
// The policy applied here is the vendored file's own rather than one invented for Ballpad:
// -controlDragged: and the saved-origin branch of -placeControl: both clamp a centre into the safe
// rect with these same half-extent numbers. A control the player placed is therefore already inside
// and is left alone, the vendored pass keeps deciding where every control goes, and the only thing
// this moves is a control the vendored default pass itself put outside -- by exactly as much as it
// takes to bring it back. It runs before the shoulders are repaired, so the right shoulder mirrors a
// left shoulder that has already been brought inside.
//
// The four directional buttons are governed as one control, by their group: the vendored pass lays
// them out around the group's clamped centre and their extent *is* the group's bounds, so clamping
// one button on its own would break the cross rather than fix it.
- (void)ballpadApplySafeAreaContainment
{
    CGRect safe = self.bounds;
    if (@available(iOS 11.0, *))
        safe = UIEdgeInsetsInsetRect(safe, self.safeAreaInsets);
    if (safe.size.width <= 0.0 || safe.size.height <= 0.0)
        return;

    NSMutableArray<UIView *> *judged = [NSMutableArray array];
    for (UIView *control in BallpadTouchControlsInDrawOrder(self))
        if (![control.accessibilityIdentifier hasPrefix:@"D_"])
            [judged addObject:control];
    UIView *dPad = BallpadControlLabelled(self, @"D-pad");
    if (dPad != nil)
        [judged addObject:dPad];

    NSMutableArray<NSString *> *moved = [NSMutableArray array];
    for (UIView *control in judged)
    {
        const CGRect drawn = [control convertRect:control.bounds toView:self];
        if (CGRectContainsRect(safe, drawn))
            continue;
        // MIN against half the safe rect as well as half the control, which is the vendored editor's
        // own guard: a control larger than the whole safe rect is centred on it rather than given a
        // clamp range that has crossed over itself.
        const CGFloat halfWidth = MIN(CGRectGetWidth(drawn) * 0.5, safe.size.width * 0.5);
        const CGFloat halfHeight = MIN(CGRectGetHeight(drawn) * 0.5, safe.size.height * 0.5);
        const CGFloat minX = CGRectGetMinX(safe) + halfWidth, maxX = CGRectGetMaxX(safe) - halfWidth;
        const CGFloat minY = CGRectGetMinY(safe) + halfHeight, maxY = CGRectGetMaxY(safe) - halfHeight;
        const CGPoint centre = CGPointMake(MIN(MAX(CGRectGetMidX(drawn), minX), maxX),
                                           MIN(MAX(CGRectGetMidY(drawn), minY), maxY));
        // A control that is outside by a rounding error is inside for every purpose that matters
        // here, and re-centring it every pass would be churn without a picture to show for it.
        if (fabs(centre.x - CGRectGetMidX(drawn)) < 0.01 &&
            fabs(centre.y - CGRectGetMidY(drawn)) < 0.01)
            continue;
        [moved addObject:[NSString stringWithFormat:@"%@ %.1f,%.1f to %.1f,%.1f",
                          control.accessibilityIdentifier ?: @"?",
                          (double)CGRectGetMidX(drawn), (double)CGRectGetMidY(drawn),
                          (double)centre.x, (double)centre.y]];
        control.center = [control.superview convertPoint:centre fromView:self];
    }

    // Only a control that actually moved is written, and only when the set of them changes: this is
    // the line that says the defect was live, so on a layout that respects the safe rect it is
    // absent rather than repeating every pass.
    if (moved.count == 0)
        return;
    NSString *line = [moved componentsJoinedByString:@"; "];
    static NSString *s_lastMoved = nil;
    if ([line isEqualToString:s_lastMoved])
        return;
    s_lastMoved = line;
    BallpadLog(@"safe area: %lu control(s) were drawn outside the surface's safe rect and are back "
               @"inside it -- %@ | insets %.1f,%.1f,%.1f,%.1f",
               (unsigned long)moved.count, line, (double)self.safeAreaInsets.left,
               (double)self.safeAreaInsets.top, (double)self.safeAreaInsets.right,
               (double)self.safeAreaInsets.bottom);
}


// -- The iPad default pass ---------------------------------------------------
//
// iPad defaults use the live control sizes to keep the lower clusters separated.
// Saved positions take priority. The same defaults apply in and out of the editor.
static BOOL BallpadPlacePadControl(UIView *control, NSDictionary *saved, CGPoint centre)
{
    if (control == nil || control.accessibilityIdentifier.length == 0)
        return NO;
    if (saved[control.accessibilityIdentifier] != nil)
        return NO;
    // The centre rather than the frame, which is what the vendored pass sets: a control mid-press
    // carries a transform, and the frame of a transformed view is not where it is drawn.
    const BOOL moved = fabs(control.center.x - centre.x) > 0.01 ||
                       fabs(control.center.y - centre.y) > 0.01;
    control.center = centre;
    return moved;
}

- (void)ballpadApplyPadDefaultLayout
{
    if (self.traitCollection.userInterfaceIdiom != UIUserInterfaceIdiomPad)
        return;

    CGRect safe = self.bounds;
    if (@available(iOS 11.0, *))
        safe = UIEdgeInsetsInsetRect(safe, self.safeAreaInsets);
    // The vendored pass takes the tablet constants under this exact condition, so this replaces that
    // set and reaches no other layout.
    if (safe.size.width <= 0.0 || safe.size.height <= 0.0)
        return;

    const CGFloat margin = 34.0;
    const CGFloat scale = [SunPadSettings sharedSettings].controlSizeScale;

    NSMutableDictionary<NSString *, UIView *> *controls = [NSMutableDictionary dictionary];
    for (UIView *control in BallpadTouchControlsInDrawOrder(self))
        if (control.accessibilityIdentifier.length > 0)
            controls[control.accessibilityIdentifier] = control;
    NSDictionary *saved = [[NSUserDefaults standardUserDefaults]
        dictionaryForKey:@"SunPadControlOrigins"];

    UIView *move = controls[@"move"];
    UIView *camera = controls[@"c"];
    UIView *a = controls[@"A"];
    UIView *b = controls[@"B"];
    UIView *x = controls[@"X"];
    UIView *y = controls[@"Y"];
    UIView *l = controls[@"L"];
    UIView *z = controls[@"Z"];
    UIView *start = controls[@"Start"];
    if (move == nil || camera == nil || a == nil || b == nil || x == nil || y == nil ||
        l == nil || z == nil || start == nil)
        return;

    const CGSize m = move.bounds.size, cam = camera.bounds.size;
    const CGSize as = a.bounds.size, bs = b.bounds.size;
    const CGSize xs = x.bounds.size, ys = y.bounds.size;
    const CGSize ls = l.bounds.size, zs = z.bounds.size, ss = start.bounds.size;

    // The camera stick first, because the face cluster is placed against it, and the cluster in the
    // order the vendored arithmetic places it: A above the camera stick, B left of A, X above A, Y
    // above and left of A. The gaps are the arithmetic set's own, scaled the way that set scales them.
    NSMutableArray<NSString *> *placed = [NSMutableArray array];
    if (BallpadPlacePadControl(move, saved,
                              CGPointMake(CGRectGetMinX(safe) + margin + m.width * 0.5,
                                          CGRectGetMaxY(safe) - margin - m.height * 0.5)))
        [placed addObject:@"move"];
    if (BallpadPlacePadControl(camera, saved,
                              CGPointMake(CGRectGetMaxX(safe) - margin - cam.width * 0.5,
                                          CGRectGetMaxY(safe) - margin - cam.height * 0.5)))
        [placed addObject:@"c"];

    const CGPoint aCentre = CGPointMake(CGRectGetMaxX(safe) - margin - as.width * 0.5,
        CGRectGetMaxY(safe) - margin - cam.height - 18.0 * scale - as.height * 0.5);
    if (BallpadPlacePadControl(a, saved, aCentre))
        [placed addObject:@"A"];
    if (BallpadPlacePadControl(b, saved,
            CGPointMake(aCentre.x - as.width * 0.5 - 12.0 * scale - bs.width * 0.5,
                        aCentre.y + 8.0 + bs.height * 0.5)))
        [placed addObject:@"B"];
    if (BallpadPlacePadControl(x, saved,
            CGPointMake(aCentre.x,
                        aCentre.y - as.height * 0.5 - 10.0 * scale - xs.height * 0.5)))
        [placed addObject:@"X"];
    if (BallpadPlacePadControl(y, saved,
            CGPointMake(aCentre.x - as.width * 0.5 - 8.0 * scale - ys.width * 0.5,
                        aCentre.y - as.height * 0.5 + 8.0 - ys.height * 0.5)))
        [placed addObject:@"Y"];

    // Shoulders sit immediately above the face-button cluster, within thumb reach.
    // R mirrors L in the shoulder repair below.
    const CGFloat shoulderY = CGRectGetMinY(x.frame) - 18.0 * scale - ls.height;
    if (BallpadPlacePadControl(l, saved,
            CGPointMake(CGRectGetMinX(safe) + margin + ls.width * 0.5,
                        shoulderY + ls.height * 0.5)))
        [placed addObject:@"L"];
    UIView *right = controls[@"R"];
    if (BallpadPlacePadControl(right, saved,
            CGPointMake(CGRectGetMaxX(safe) - margin - ls.width * 0.5,
                        shoulderY + ls.height * 0.5)))
        [placed addObject:@"R"];
    if (BallpadPlacePadControl(z, saved,
            CGPointMake(CGRectGetMaxX(safe) - margin - ls.width - 12.0 * scale - zs.width * 0.5,
                        shoulderY + zs.height * 0.5)))
        [placed addObject:@"Z"];
    if (BallpadPlacePadControl(start, saved,
            CGPointMake(CGRectGetMidX(safe), CGRectGetMinY(safe) + margin + ss.height * 0.5)))
        [placed addObject:@"Start"];

    if (placed.count == 0)
        return;
    NSString *line = [placed componentsJoinedByString:@", "];
    static NSString *s_lastPlaced = nil;
    if ([line isEqualToString:s_lastPlaced])
        return;
    s_lastPlaced = line;
    // Deliberately not spelled "... layout: ...": the acceptance runner reads the app's own
    // `layout:` family for S.f06.safe-area, and a line containing that token is parsed as one of
    // those readings and reported as a field it could not read. `pad defaults:` is the same claim
    // under a token nothing else in the log uses. Measured: the first draft of this line, spelled
    // with `layout:`, turned 38 clean readings into 35 unreadable ones in uitest-pad-pad-final-r1.
    BallpadLog(@"pad defaults: %lu control(s) the vendored iPad defaults had drawn on top of each "
               @"other are on the vendored arithmetic set -- %@ | safe %.0fx%.0f",
               (unsigned long)placed.count, line,
               (double)safe.size.width, (double)safe.size.height);
}

// R as L's twin. The vendored width is 2*small + 24*scale wider than L's, which is the spray track's
// own geometry, and its border is re-derived on every layout pass; both are undone here from L's live
// values rather than from copies of them, so the two shoulders cannot drift apart as the vendored
// numbers change.
- (void)ballpadApplyShoulderRepair
{
    UIView *left = BallpadControlLabelled(self, @"L");
    UIView *right = BallpadControlLabelled(self, @"R");
    if (left == nil || right == nil)
        return;

    if (!CGSizeEqualToSize(right.bounds.size, left.bounds.size))
        right.bounds = (CGRect){ .origin = CGPointZero, .size = left.bounds.size };
    // The inherited spray-trigger width clamps a saved center too far inward.
    // Reapply the saved center after restoring BallPad's actual button width.
    id savedRight = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"SunPadControlOrigins"][@"R"];
    BOOL draggingRight = NO;
    for (UIGestureRecognizer *gesture in right.gestureRecognizers)
        if ([gesture isKindOfClass:UIPanGestureRecognizer.class] &&
            (gesture.state == UIGestureRecognizerStateBegan || gesture.state == UIGestureRecognizerStateChanged))
            draggingRight = YES;
    if (!draggingRight && [savedRight isKindOfClass:NSString.class])
    {
        CGPoint normalized = CGPointFromString(savedRight);
        CGRect safe = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
        CGFloat halfW = right.bounds.size.width * 0.5;
        CGFloat halfH = right.bounds.size.height * 0.5;
        right.center = CGPointMake(
            MIN(MAX(safe.origin.x + normalized.x * safe.size.width, CGRectGetMinX(safe) + halfW), CGRectGetMaxX(safe) - halfW),
            MIN(MAX(safe.origin.y + normalized.y * safe.size.height, CGRectGetMinY(safe) + halfH), CGRectGetMaxY(safe) - halfH));
    }
    right.layer.cornerRadius =
        MIN(CGRectGetWidth(right.bounds), CGRectGetHeight(right.bounds)) * 0.5;
    right.layer.masksToBounds = YES;
    if (!BallpadOverlayIsEditingLayout(self))
    {
        // The border is copied only at rest, and "at rest" is decided two ways, because copying a
        // *live* border was this repair's own defect.
        //
        //   * The pair comes from L once -- captured on the first pass, which runs when the overlay
        //     is built and before any touch can reach it -- and every later pass applies that
        //     captured pair. Re-reading L on each pass copies whatever L is doing at that instant,
        //     and a pass during a press on L painted L's full-press outline onto R: the read-back
        //     caught exactly that as `border L 3.0 R 3.0` with only the left shoulder touched.
        //   * A held right shoulder keeps its own border. That outline *is* the trigger's press
        //     indicator, and a layout pass during a press (a rotation, the control-hide transition,
        //     the editor's own bar) would otherwise repaint R at the at-rest width on every pass --
        //     the same defect from the other side, R pressed and drawn as if it were not.
        //
        // The editor keeps its own outline for the reason it always did: the vendored pass draws a
        // wider one on whichever shoulder is selected, and copying over it would erase the answer
        // to "which control am I resizing". Both the direct and the deferred pass ask the same
        // question, so the editor also keeps the border it draws after a bounds change.
        if (s_shoulderRestBorderColor == NULL && left.layer.borderColor != NULL &&
            left.layer.borderWidth > 0.0)
        {
            s_shoulderRestBorderWidth = left.layer.borderWidth;
            s_shoulderRestBorderColor = CGColorRetain(left.layer.borderColor);
        }
        if (s_shoulderRestBorderColor != NULL && !s_rightShoulderHeld)
        {
            right.layer.borderColor = s_shoulderRestBorderColor;
            right.layer.borderWidth = s_shoulderRestBorderWidth;
        }
    }
    BallpadHideTriggerArtwork(right);
    // The nozzle's guidance is not this button's guidance, and L carries none.
    right.accessibilityHint = nil;
    right.accessibilityValue = nil;

    // Mirror only the default. A saved R position belongs to the player.
    if (!BallpadOverlayIsEditingLayout(self) && savedRight == nil)
    {
        CGRect mirrored = right.frame;
        mirrored.origin.x = CGRectGetWidth(self.bounds) - CGRectGetMinX(left.frame)
                            - CGRectGetWidth(mirrored);
        mirrored.origin.y = CGRectGetMinY(left.frame);
        if (!CGRectEqualToRect(mirrored, right.frame))
            right.frame = mirrored;
    }

    [self ballpadWireRightShoulder:right];

    // From this pass rather than from -layoutSubviews: the repair has just run and no vendored pass
    // has run since, so the numbers read back here are the ones that were applied. The helper writes
    // only when the geometry moved, which is what makes it safe to ask on every pass.
    BallpadLogShoulderGeometry(self, @"after the repair");
}

// Wired once. A long-press recognizer with no delay, no movement limit and no touch cancellation:
// it fires on touch-down and on release wherever on the control the finger lands, and it leaves the
// vendored pressure tracking underneath it receiving every touch, which is what keeps the two
// mechanisms from fighting each other.
- (void)ballpadWireRightShoulder:(UIView *)right
{
    if (self.ballpadRightPress != nil)
    {
        self.ballpadRightPress.enabled = !BallpadOverlayIsEditingLayout(self);
        return;
    }

    UILongPressGestureRecognizer *press =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                     action:@selector(ballpadRightShoulderGesture:)];
    press.minimumPressDuration = 0.0;
    press.allowableMovement = CGFLOAT_MAX;
    press.cancelsTouchesInView = NO;
    press.delaysTouchesBegan = NO;
    press.delaysTouchesEnded = NO;
    self.ballpadRightPress = press;
    press.enabled = !BallpadOverlayIsEditingLayout(self);
    [right addGestureRecognizer:press];
}

- (void)ballpadRightShoulderGesture:(UILongPressGestureRecognizer *)gesture
{
    if (gesture.state == UIGestureRecognizerStateBegan)
    {
        s_rightShoulderHeld = true;
        s_rightShoulderPressEdge = true;
        BallpadLogShoulderGeometry(self, @"R pressed");
    }
    else if (gesture.state == UIGestureRecognizerStateEnded ||
             gesture.state == UIGestureRecognizerStateCancelled ||
             gesture.state == UIGestureRecognizerStateFailed)
    {
        s_rightShoulderHeld = false;
        // A release is one of the two moments the vendored control re-derives its own border and
        // accessibility value, so it is one of the two moments the repair has to follow.
        [self ballpadScheduleShoulderRepair];
    }
}

#pragma mark - The planted stick zone

// Movement accepts touches across the lower-left area; buttons above it retain
// their hit targets. The C-stick keeps its smaller local zone. Editing and hiding
// controls disable the zones and release any held input.
- (void)ballpadApplyPlantedZones
{
    const BOOL editing = BallpadOverlayIsEditingLayout(self);
    NSSet<NSString *> *hidden = BallpadHiddenControls();
    for (NSString *identifier in @[ @"move", @"c" ])
    {
        UIView *stick = BallpadControlWithIdentifier(self, identifier);
        if (stick == nil || stick.superview == nil)
            continue;
        BallpadPlantedZoneView *zone = BallpadPlantedZoneForStick(self, stick);
        if (zone == nil)
            continue;

        const CGRect face = [stick convertRect:stick.bounds toView:self];
        const CGFloat side = MIN(CGRectGetWidth(face), CGRectGetHeight(face));
        const BOOL movement = [identifier isEqualToString:@"move"];
        CGRect safe = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
        CGRect frame = CGRectInset(face, -side * kBallpadPlantedZoneMarginRatio,
                                         -side * kBallpadPlantedZoneMarginRatio);
        if (movement)
            frame = CGRectMake(CGRectGetMinX(safe), CGRectGetMidY(safe),
                               safe.size.width * 0.42, safe.size.height * 0.5);
        const BOOL enabled = !editing && !stick.hidden && ![hidden containsObject:identifier];
        if (!enabled || (zone.owning && !CGRectEqualToRect(zone.frame, frame) && movement))
            [zone ballpadEndTouch];
        if (!zone.owning)
            zone.frame = frame;
        zone.stickRadius = MAX(1.0, side * (movement ? 0.30 : 0.5));
        zone.invisibleAtRest = movement;
        zone.isAccessibilityElement = movement;
        zone.accessibilityElementsHidden = !movement;
        zone.accessibilityIdentifier = movement ? @"MovementTouchArea" : nil;
        zone.accessibilityLabel = movement ? @"Movement area" : nil;
        if (!zone.owning)
            zone.accessibilityValue = @"idle";
        zone.hidden = !enabled;
        zone.userInteractionEnabled = enabled;
        if (enabled)
        {
            [zone restorePlantedPosition];
            if (movement && !zone.owning)
                stick.alpha = 0.0;
        }
    }

    // The reading is of the pass that just placed the zones, which is the whole of when it can have
    // changed -- and it is written on change only, for the reason it gives.
    BallpadLogPlantedZonesIfChanged(self);
}

#pragma mark - Hiding a control

// Ballpad's own layer over the vendored appearance, applied after the vendored pass so it is the
// last word on whether a control is drawn. Outside the editor a hidden control is gone from the
// picture and from the touch path; inside it, the same control is drawn faint and stays hittable,
// because the only way back is to select it and press the toggle, and a control the player cannot
// see is a control they cannot select.
- (void)ballpadApplyHiddenControlVisibility
{
    const BOOL editing = BallpadOverlayIsEditingLayout(self);
    for (NSString *identifier in BallpadHiddenControls())
    {
        for (UIView *control in BallpadControlsForHiddenIdentifier(self, identifier))
        {
            control.hidden = !editing;
            control.alpha = editing ? kBallpadHiddenControlEditingAlpha : 0.0;
            control.userInteractionEnabled = editing;
        }
    }

    // The control the editor is working on is drawn whole even when it is hidden: it is the subject
    // of the question the toggle is about to ask, and "Show selected control" has to be something
    // the player can see what it is about.
    if (editing && s_selectedControl != nil)
    {
        s_selectedControl.hidden = NO;
        s_selectedControl.alpha = 1.0;
    }
}

// The editor's one Ballpad row. It is inserted into the vendored bar's own stack rather than hung
// beside the bar, because the bar is sized by that stack's constraints and the row belongs to the
// same sentence as the slider and the done button: pick a control, size it, hide it, finish.
- (void)ballpadConfigureEditorHideButton
{
    UIView *done = BallpadControlLabelled(self, @"Finish moving touch controls");
    UIStackView *stack = [done.superview isKindOfClass:UIStackView.class]
        ? (UIStackView *)done.superview : nil;
    if (stack == nil || BallpadControlLabelled(stack, @"Hide selected control") != nil)
        return;

    UIButton *hide = [UIButton buttonWithType:UIButtonTypeSystem];
    // Pinned, because the title flips with the selected control's state and this label is the handle
    // the player's VoiceOver and the UI suite both find the row by.
    hide.accessibilityLabel = @"Hide selected control";
    hide.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    [hide setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [hide setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.45] forState:UIControlStateDisabled];
    hide.backgroundColor = [UIColor colorWithWhite:0.18 alpha:0.88];
    hide.layer.cornerRadius = 10.0;
    [hide addTarget:self action:@selector(ballpadToggleSelectedControlHidden:)
   forControlEvents:UIControlEventTouchUpInside];
    [stack insertArrangedSubview:hide
                          atIndex:stack.arrangedSubviews.count > 0 ? stack.arrangedSubviews.count - 1 : 0];
    [NSLayoutConstraint activateConstraints:@[
        [hide.heightAnchor constraintEqualToConstant:kBallpadHideButtonHeight],
        [hide.widthAnchor constraintGreaterThanOrEqualToConstant:kBallpadHideButtonMinWidth],
    ]];

    [self ballpadUpdateEditorHideButton];
}

// The row's own state, read from the selection and the store rather than remembered: the title is the
// action the tap would perform, the value is the state it acts on, and both are refreshed from the
// same two facts on every layout pass -- so a control selected while the editor is open moves the
// row without anything having to tell it.
- (void)ballpadUpdateEditorHideButton
{
    if (!BallpadOverlayIsEditingLayout(self))
        s_selectedControl = nil;      // a selection cannot outlive the bar it was made in

    UIView *found = BallpadControlLabelled(self, @"Hide selected control");
    UIButton *button = [found isKindOfClass:UIButton.class] ? (UIButton *)found : nil;
    if (button == nil)
        return;

    NSString *identifier = BallpadHiddenIdentifierForControl(s_selectedControl);
    const BOOL hidden = identifier != nil && [BallpadHiddenControls() containsObject:identifier];
    button.enabled = identifier != nil;
    [button setTitle:identifier == nil ? @"Select a control first"
                                      : (hidden ? @"Show selected control" : @"Hide selected control")
            forState:UIControlStateNormal];
    button.accessibilityValue = identifier == nil ? @"none" : (hidden ? @"hidden" : @"shown");
}

// One tap, one entry, and the drawing follows here rather than in the next layout pass: the player is
// looking at the control when they press this, and a control that waited a pass to change would read
// as a button that did nothing.
- (void)ballpadToggleSelectedControlHidden:(UIButton *)button
{
    (void)button;
    NSString *identifier = BallpadHiddenIdentifierForControl(s_selectedControl);
    if (identifier == nil)
        return;

    NSMutableSet<NSString *> *hidden = BallpadHiddenControls();
    const BOOL nowHidden = ![hidden containsObject:identifier];
    if (nowHidden)
        [hidden addObject:identifier];
    else
        [hidden removeObject:identifier];
    BallpadWriteHiddenControls();
    [[[UISelectionFeedbackGenerator alloc] init] selectionChanged];

    BallpadLog(@"hide: %@ is now %@; the hidden set is %@", identifier,
               nowHidden ? @"hidden" : @"shown",
               hidden.count == 0 ? @"empty"
                                 : [[hidden.allObjects sortedArrayUsingSelector:@selector(compare:)]
                                       componentsJoinedByString:@", "]);

    [self ballpadApplyHiddenControlVisibility];
    [self ballpadUpdateEditorHideButton];
    [self setNeedsLayout];
}

#pragma mark - The vendored editor's own ends

// Both of the editor's gestures route through the vendored selection -- a drag calls it as it begins,
// a tap calls it as it ends -- so this one override is where the toggle learns which control it acts
// on.
// Capture the layout the player is looking at before the vendored editor lays out.
// Its fallback defaults differ from BallPad's defaults; saved centers are shared.
- (void)beginLayoutEditing
{
    self.ballpadRightPress.enabled = NO;
    NSDictionary *zones = objc_getAssociatedObject(self, BallpadPlantedZonesKey);
    for (BallpadPlantedZoneView *zone in zones.allValues)
        [zone ballpadEndTouch];
    [self layoutIfNeeded];
    CGRect safe = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
    if (safe.size.width > 0 && safe.size.height > 0)
    {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSMutableDictionary *saved = [[defaults dictionaryForKey:@"SunPadControlOrigins"] mutableCopy]
            ?: [NSMutableDictionary dictionary];
        for (UIView *control in BallpadTouchControlsInDrawOrder(self))
        {
            NSString *identifier = control.accessibilityIdentifier;
            if (identifier.length == 0 || [identifier hasPrefix:@"D_"])
                continue;
            CGRect frame = [control convertRect:control.bounds toView:self];
            CGPoint normalized = CGPointMake((CGRectGetMidX(frame) - safe.origin.x) / safe.size.width,
                                             (CGRectGetMidY(frame) - safe.origin.y) / safe.size.height);
            saved[identifier] = NSStringFromCGPoint(normalized);
        }
        [defaults setObject:saved forKey:@"SunPadControlOrigins"];
    }
    [super beginLayoutEditing];
}

- (void)selectControlForEditing:(UIView *)control
{
    [super selectControlForEditing:control];
    if (!BallpadOverlayIsEditingLayout(self) || control.accessibilityIdentifier.length == 0)
        return;
    s_selectedControl = control;
    [self ballpadApplyHiddenControlVisibility];
    [self ballpadUpdateEditorHideButton];
}

// The vendored exit re-draws every control whole and asks for no layout pass of its own, so without
// this the set the player just edited would come back the moment Done was pressed and stay until
// something else happened to lay the overlay out.
- (void)endLayoutEditing
{
    [super endLayoutEditing];
    [self setNeedsLayout];
}

// Ballpad's own layout store, cleared by the one row a player would look for it under. The vendored
// reset returns this device's layout to its defaults, and a control that stayed hidden would not be
// a default -- which is also why the set is not cleared anywhere the vendored file calls
// -applySettings, since a foreground resume goes through there.
- (void)resetLayout
{
    [super resetLayout];
    [BallpadHiddenControls() removeAllObjects];
    BallpadWriteHiddenControls();
    BallpadLog(@"hide: the layout was reset, so every hidden control is shown again");
    [self setNeedsLayout];
}

@end

// ── The FPS counter (item 5) ──────────────────────────────────────────────────
// The vendored "Show FPS Counter" row persists a setting and does nothing else -- there is no FPS
// label in the vendored set at all, its own header calling the setting an emulator overlay toggle.
// On this port the numbers exist and the row has to be backed by them, so the label is Ballpad's:
// a view the overlay carries, shown while the setting is on, filled from the port's own benchmark
// once a frame. Busy time is reported next to the frame rate because busy is the figure that says
// whether the machine has headroom: paced by the display, a machine that keeps up reports the
// refresh rate whatever it is doing.
static const void *BallpadFPSCounterKey = &BallpadFPSCounterKey;
// The state the label was last positioned against, in the shape BallpadFPSCounterPlacementSignature
// writes it: the surface, the insets it publishes and every control the player can touch. The label
// is positioned when that state moves rather than once per frame, and this is what remembers it.
static const void *BallpadFPSCounterPlacedKey = &BallpadFPSCounterPlacedKey;
// Which anchor the card was last put on, and how many drawn things that placement was scored
// against. Published by BallpadFPSCounterPlacementNote as a field of the layout reading, because
// "the card is over a control" is two different defects depending on these two numbers: a placement
// that saw the control and chose to cover it, and a placement that saw nothing at all to avoid.
static const void *BallpadFPSCounterAnchorKey = &BallpadFPSCounterAnchorKey;
static const void *BallpadFPSCounterObstacleKey = &BallpadFPSCounterObstacleKey;

// Fixed geometry prevents every FPS update from relaying out touch controls.
static const CGFloat kBallpadFPSWidth = 104.0;
static const CGFloat kBallpadFPSMargin = 12.0;
static NSAttributedString *BallpadFPSReading(NSString *rate)
{
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.alignment = NSTextAlignmentCenter;
    return [[NSAttributedString alloc] initWithString:rate attributes:@{
        NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:17 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: UIColor.whiteColor,
        NSParagraphStyleAttributeName: paragraph,
    }];
}

static UILabel *BallpadFPSCounterLabel(SunPadGameOverlay *overlay)
{
    UILabel *label = objc_getAssociatedObject(overlay, BallpadFPSCounterKey);
    if (label != nil)
        return label;

    label = [UILabel new];
    label.userInteractionEnabled = NO;
    label.textColor = UIColor.whiteColor;
    label.backgroundColor = [UIColor colorWithWhite:0.03 alpha:0.62];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 1;
    label.layer.cornerRadius = 12.0;
    label.layer.masksToBounds = YES;
    label.layer.borderWidth = 1.0;
    label.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.16].CGColor;
    label.accessibilityIdentifier = @"BallpadFPSCounter";
    objc_setAssociatedObject(overlay, BallpadFPSCounterKey, label,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return label;
}

// Whether a view is on screen and can be touched, which is what makes it a thing the card may not be
// drawn over. The whole chain rather than the view alone: the settings panel and the layout editor
// are hidden while they are closed and their rows are not, so asking the row whether it is hidden
// counts a slider inside a hidden panel as drawn -- and a card that gives up a corner to a control
// nobody can see has avoided nothing while putting itself somewhere worse. Alpha is the same fact by
// another route, and the interaction flag is the one that matters for the player rather than for the
// eye: a row that cannot be touched is not a control this card can take away from anybody.
static BOOL BallpadViewIsDrawnAndTouchable(UIView *view, UIView *overlay)
{
    for (UIView *walk = view; walk != nil; walk = walk.superview)
    {
        if (walk.hidden || walk.alpha == 0.0 || !walk.userInteractionEnabled)
            return NO;
        if (walk == overlay)
            break;
    }
    return YES;
}

// What the card must not be drawn over: everything the player touches. The two analog sticks are
// plain views rather than controls, so the named walk the layout reading uses is what names them;
// the overlay's own menu button is a control that is not in that list -- it has no identifier of its
// own -- so controls are collected by type as well. The card itself is a label rather than a control
// and carries an identifier, so neither half of this collects it.
static NSArray<UIView *> *BallpadFPSCounterObstacleViews(SunPadGameOverlay *overlay)
{
    NSMutableArray<UIView *> *touched = [NSMutableArray arrayWithArray:
                                         BallpadTouchControlsInDrawOrder(overlay)];
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:overlay];
    while (pending.count > 0)
    {
        UIView *view = pending.lastObject;
        [pending removeLastObject];
        if ([view isKindOfClass:UIControl.class] && view.accessibilityIdentifier.length == 0)
            [touched addObject:view];
        [pending addObjectsFromArray:view.subviews];
    }

    NSMutableArray<UIView *> *drawn = [NSMutableArray array];
    for (UIView *view in touched)
        if (BallpadViewIsDrawnAndTouchable(view, overlay))
            [drawn addObject:view];
    return drawn;
}

// The same set as rectangles in the overlay's own space, which is what the scoring below and the
// placement signature are both written against.
static NSArray<NSValue *> *BallpadFPSCounterObstacles(SunPadGameOverlay *overlay)
{
    NSMutableArray<NSValue *> *rects = [NSMutableArray array];
    for (UIView *view in BallpadFPSCounterObstacleViews(overlay))
        [rects addObject:[NSValue valueWithCGRect:[view convertRect:view.bounds toView:overlay]]];
    return rects;
}

// Where the card is allowed to sit: the safe rect's two top corners, its top centre, and then its
// two bottom corners -- the order a tie between two equally clear places is broken in. The top
// before the bottom because the bottom is where the thumbs rest, and the top centre after the
// corners because a card over the middle of the picture is the placement a player notices.
static const NSUInteger kBallpadFPSCounterAnchors = 5;

static CGPoint BallpadFPSCounterAnchorOrigin(NSUInteger anchor, CGRect safe, CGSize card)
{
    // Clamped to the safe rect's own edge rather than allowed past it: a card too wide for the safe
    // rect cannot be inside it at any anchor, and pushing it off the surface would be a second defect
    // on top of the first. The anchor then reads as the card sitting against the edge it overflowed.
    const CGFloat left = safe.origin.x + kBallpadFPSMargin;
    const CGFloat right = MAX(left, CGRectGetMaxX(safe) - kBallpadFPSMargin - card.width);
    const CGFloat top = safe.origin.y + kBallpadFPSMargin;
    const CGFloat bottom = MAX(top, CGRectGetMaxY(safe) - kBallpadFPSMargin - card.height);
    switch (anchor)
    {
        case 1:  return CGPointMake(right, top);
        case 2:  return CGPointMake(MAX(left, CGRectGetMidX(safe) - card.width / 2.0), top);
        case 3:  return CGPointMake(left, bottom);
        case 4:  return CGPointMake(right, bottom);
        default: return CGPointMake(left, top);
    }
}

// The state a placement is derived from, as one string: the surface, the insets it publishes, and
// every obstacle's frame. The insets as well as the bounds, because a turn to the other landscape
// side leaves the surface the same size and moves the safe rect under it; the obstacles, because a
// control the player has dragged is an obstacle somewhere else, and a counter left on top of where
// that control used to be is the same defect as having placed it there. Whole points, because the
// vendored pass can land a control a fraction of a point differently on two consecutive passes, and
// a signature that noticed that would re-frame the card every frame -- the re-layout that reserving
// the frame is there to avoid.
static NSString *BallpadFPSCounterPlacementSignature(SunPadGameOverlay *overlay)
{
    const UIEdgeInsets insets = overlay.safeAreaInsets;
    NSMutableString *signature = [NSMutableString stringWithFormat:@"%.0fx%.0f safe %.0f,%.0f,%.0f,%.0f",
                                  (double)CGRectGetWidth(overlay.bounds),
                                  (double)CGRectGetHeight(overlay.bounds),
                                  (double)insets.left, (double)insets.top,
                                  (double)insets.right, (double)insets.bottom];
    for (NSValue *obstacle in BallpadFPSCounterObstacles(overlay))
    {
        const CGRect rect = obstacle.CGRectValue;
        [signature appendFormat:@" %.0f,%.0f %.0fx%.0f", (double)rect.origin.x,
                              (double)rect.origin.y, (double)CGRectGetWidth(rect),
                              (double)CGRectGetHeight(rect)];
    }
    return signature;
}

// The label's own geometry: sized against the widest reading rather than the current one, so the
// frame this sets is the frame it keeps, and placed inside the surface's safe area at the anchor
// that hides the least of what the player is touching. Chosen rather than fixed in a corner because
// the vendored layout puts a control in the top left on the phone -- Start, with L under it -- while
// the pad's default leaves that corner empty and puts Start in the middle of the top edge: no one
// anchor is clear on every shape, and a counter drawn over a control has taken that control away
// from the player, which is the one thing the card is not allowed to do. Called when the label
// appears and when the signature above moves, which is the whole of its layout.
static void BallpadPositionFPSCounterLabel(SunPadGameOverlay *overlay, UILabel *label)
{
    CGRect frame = CGRectMake(0.0, 0.0, kBallpadFPSWidth, 40.0);

    const CGRect safe = UIEdgeInsetsInsetRect(overlay.bounds, overlay.safeAreaInsets);
    NSArray<NSValue *> *obstacles = BallpadFPSCounterObstacles(overlay);
    NSUInteger chosen = 0;
    CGFloat least = CGFLOAT_MAX;
    NSMutableString *scored = [NSMutableString string];
    for (NSUInteger anchor = 0; anchor < kBallpadFPSCounterAnchors; anchor++)
    {
        const CGRect place = (CGRect){ BallpadFPSCounterAnchorOrigin(anchor, safe, frame.size),
                                       frame.size };
        CGFloat hidden = 0.0;
        for (NSValue *obstacle in obstacles)
        {
            const CGRect overlap = CGRectIntersection(place, obstacle.CGRectValue);
            // Both non-null and finite: the conversion above runs against a tree the vendored pass
            // is in the middle of laying out, and a frame that has not been given a value yet is a
            // NaN rather than a rectangle. A NaN carried into the sum makes every comparison below
            // false, which would leave the loop's initial anchor as the answer -- a card placed at
            // the top left whatever it was drawn over. An unreadable rect is skipped rather than
            // counted as clear, because the one thing this placement may not do is cover a control.
            if (CGRectIsNull(overlap))
                continue;
            const CGFloat width = (double)CGRectGetWidth(overlap);
            const CGFloat height = (double)CGRectGetHeight(overlap);
            if (!isfinite(width) || !isfinite(height))
                continue;
            hidden += width * height;
        }
        [scored appendFormat:@" %lu:%.0f", (unsigned long)anchor, (double)hidden];
        // Strictly less, so a tie keeps the earlier anchor, and by half a point, so two anchors that
        // hide the same thing are not separated by the arithmetic of two products.
        if (isfinite(hidden) && hidden < least - 0.5)
        {
            least = hidden;
            chosen = anchor;
        }
    }
    frame.origin = BallpadFPSCounterAnchorOrigin(chosen, safe, frame.size);
    label.frame = frame;
    objc_setAssociatedObject(overlay, BallpadFPSCounterAnchorKey, @(chosen),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(overlay, BallpadFPSCounterObstacleKey, @(obstacles.count),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // One line per placement the card actually moves to, and deduped on the two facts that decide
    // it rather than on the areas: a control being dragged re-places the card on every frame of the
    // touch, and the line worth having is the placement, not the sixty samples of it.
    static NSUInteger s_lastAnchor = NSUIntegerMax;
    static NSUInteger s_lastObstacles = NSUIntegerMax;
    if (chosen != s_lastAnchor || obstacles.count != s_lastObstacles)
    {
        s_lastAnchor = chosen;
        s_lastObstacles = obstacles.count;
        NSMutableString *where = [NSMutableString string];
        for (UIView *view in BallpadFPSCounterObstacleViews(overlay))
        {
            const CGRect rect = [view convertRect:view.bounds toView:overlay];
            [where appendFormat:@" | %@ %.0f,%.0f %.0fx%.0f",
             view.accessibilityIdentifier.length > 0 ? view.accessibilityIdentifier
                                                     : NSStringFromClass(view.class),
             (double)rect.origin.x, (double)rect.origin.y,
             (double)CGRectGetWidth(rect), (double)CGRectGetHeight(rect)];
        }
        BallpadLog(@"fps counter: card %.0fx%.0f in safe %.0f,%.0f %.0fx%.0f, %lu of %lu drawn "
                   @"things are obstacles, placed %lu of %lu, covered area by anchor%@%@ -- the "
                   @"smallest wins, so the card sits where it hides the least of what is touched",
                   (double)frame.size.width, (double)frame.size.height,
                   (double)safe.origin.x, (double)safe.origin.y,
                   (double)safe.size.width, (double)safe.size.height,
                   (unsigned long)obstacles.count,
                   (unsigned long)BallpadTouchControlsInDrawOrder(overlay).count,
                   (unsigned long)chosen, (unsigned long)kBallpadFPSCounterAnchors, scored, where);
    }
}

// The placement as the layout reading publishes it, or a dash when no card has been placed -- which
// is the reading of a run whose FPS row is off.
static NSString *BallpadFPSCounterPlacementNote(UIView *overlay)
{
    NSNumber *anchor = objc_getAssociatedObject(overlay, BallpadFPSCounterAnchorKey);
    if (anchor == nil)
        return @"anchor - obstacles -";
    NSNumber *obstacles = objc_getAssociatedObject(overlay, BallpadFPSCounterObstacleKey);
    return [NSString stringWithFormat:@"anchor %@ obstacles %@", anchor, obstacles ?: @(-1)];
}

static void BallpadRefreshFPSCounter(SunPadGameOverlay *overlay)
{
    UILabel *label = objc_getAssociatedObject(overlay, BallpadFPSCounterKey);
    if (![SunPadSettings sharedSettings].showFPSCounter)
    {
        // Removed rather than hidden. A hidden view is still in the accessibility tree, so the row
        // that turns the counter off would read back as if it had not, and the label would keep a
        // frame in a hierarchy that is re-laid out every frame for nothing.
        if (label != nil)
        {
            [label removeFromSuperview];
            objc_setAssociatedObject(overlay, BallpadFPSCounterKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(overlay, BallpadFPSCounterPlacedKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }

    if (label == nil)
    {
        label = BallpadFPSCounterLabel(overlay);
        [overlay addSubview:label];
        // Once, here, because the label is added after every vendored control: nothing is added to
        // the overlay afterwards, so there is no later sibling for it to fall behind.
        [overlay bringSubviewToFront:label];
    }

    PortBenchLive live;
    PortBenchGetLive(&live);
    // The rolling window is what moves; the run counters stay put until a match is live, so a title
    // screen reads as a rate rather than as a stalled zero.
    NSString *rate = [NSString stringWithFormat:@"%.0f fps", live.fps];
    // Assigned only when the reading it shows has changed. The card is drawn to whole frames a
    // second, so the text is the same on fifty-odd frames out of sixty -- and assigning
    // attributedText invalidates the label's layout and commits a transaction whether the string is
    // new or not, which is a text layout pass per frame to redraw the number that was already there.
    static __weak UILabel *s_ratedLabel = nil;
    static NSString *s_rate = nil;
    if (label != s_ratedLabel || ![rate isEqualToString:s_rate])
    {
        s_ratedLabel = label;
        s_rate = rate;
        label.attributedText = BallpadFPSReading(rate);
    }

    // The placement, on the settling clock the other read-backs use: the signature is a formatted
    // description of the surface the card is placed against, and nothing that can move it -- a
    // rotation, a safe-area change, the panel's size control -- moves it within a tenth of a second.
    static CFTimeInterval s_lastPlacementCheck = 0.0;
    if (!BallpadSampleIsDue(&s_lastPlacementCheck))
        return;

    // The display read-back, published on the card as its accessibility *value*. The card used to
    // spell the whole reading out and build 2 reduced it to the rate (doc 37), which left the row
    // that reads "a display setting reached the renderer" with nothing to read -- it had been
    // parsing this out of the card's label, and has failed on every build since. The value is the
    // right home for it: what the card draws stays "60 fps", what VoiceOver announces stays
    // "60 fps", and the reading is still published where a test can address it.
    label.accessibilityValue = BallpadDisplayReadBack();

    NSString *placed = objc_getAssociatedObject(overlay, BallpadFPSCounterPlacedKey);
    NSString *signature = BallpadFPSCounterPlacementSignature(overlay);
    if (placed == nil || ![placed isEqualToString:signature])
    {
        BallpadPositionFPSCounterLabel(overlay, label);
        // Read again after the frame is set, rather than storing the state the placement was chosen
        // from: assigning a frame invalidates the overlay's layout, so the state the card is now
        // placed against is the one that follows that pass, and storing the state before it would
        // re-place the card on the very next frame.
        objc_setAssociatedObject(overlay, BallpadFPSCounterPlacedKey,
                                 BallpadFPSCounterPlacementSignature(overlay),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// The overlay is retained by the view hierarchy it is added to. The bridge is not retained by the
// overlay, so this is what keeps the menu's actions connected. All three are process-lifetime
// singletons: this build presents one window and one overlay.
@class BallpadHostUIBridge;
static SunPadGameOverlay *s_overlay = nil;
static BallpadHostUIBridge *s_bridge = nil;
// The port's SDL window, kept so a foreground resume can re-resolve the UIKit window it is
// presenting into. A rebuilt surface means a rebuilt view controller view, and the overlay has to
// follow it; holding the pointer is what makes that possible after the overlay's own window
// reference has already gone nil.
static void *s_sdlWindow = nullptr;

// Both defined with the rest of the host-UI plumbing below, forward-declared here because the
// lifecycle notification that uses them is part of the bridge.
static UIWindow *BallpadWindowForSDLWindow(void *sdlWindow);
static void BallpadLogHostGeometry(UIWindow *window, UIView *container);
static void BallpadReattachOverlay(NSString *reason);

// SunPadGameOverlay holds its delegate weakly, so the app has to own the receiver.
@interface BallpadHostUIBridge : NSObject <SunPadGameOverlayDelegate, UIGestureRecognizerDelegate>
// The overlay is retained by the view hierarchy that holds it; this is only how a lifecycle
// notification reaches the one object that knows about it.
@property(nonatomic, weak) SunPadGameOverlay *overlay;
// The two-finger tap that brings a hidden menu button back. Held here because it belongs to the
// window rather than to the overlay, and a rebuilt window needs it put back.
@property(nonatomic, strong) UITapGestureRecognizer *revealGesture;
@end

@implementation BallpadHostUIBridge

// ── The reveal gesture ────────────────────────────────────────────────────────

- (void)installRevealGestureOnWindow:(UIWindow *)window
{
    if (window == nil)
        return;
    if (self.revealGesture.view == window)
        return;
    if (self.revealGesture == nil)
    {
        UITapGestureRecognizer *tap =
            [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(revealTapped:)];
        tap.numberOfTouchesRequired = 2;
        tap.numberOfTapsRequired = 1;
        tap.delegate = self;
        // Observed rather than consumed: the game's own controls keep every touch they would have
        // had, so a gesture that fires over them changes nothing but the menu button's alpha.
        tap.cancelsTouchesInView = NO;
        tap.delaysTouchesBegan = NO;
        tap.delaysTouchesEnded = NO;
        self.revealGesture = tap;
    }
    [self.revealGesture.view removeGestureRecognizer:self.revealGesture];
    [window addGestureRecognizer:self.revealGesture];
}

- (void)revealTapped:(UITapGestureRecognizer *)gesture
{
    (void)gesture;
    BallpadRevealMenuButton(self.overlay);
}

// A touch that reached the interface is a touch the player meant for it, so it is not part of a
// reveal: two thumbs on A and B at the same moment, or two fingers on the movement stick, are not a
// request for the menu button. The test is the overlay rather than UIControl because the stick is a
// plain UIView -- and it is the right test anyway, since the overlay's own hit test already passes
// everything it does not own through to the game. What is left is a touch on the game surface,
// which is the only place a reveal can come from.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch
{
    (void)gestureRecognizer;
    SunPadGameOverlay *overlay = self.overlay;
    if (overlay == nil)
        return NO;
    for (UIView *view = touch.view; view != nil; view = view.superview)
    {
        if (view == overlay)
            return NO;
    }
    return YES;
}

// The window belongs to SDL and to whatever UIKit puts over it, so this recogniser never claims
// exclusivity over anything else that wants the same touches.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other
{
    (void)gestureRecognizer;
    (void)other;
    return YES;
}

// The two callbacks that return text answer from what this build actually is, so the diagnostic
// report and any problem report describe Ballpad rather than the project the overlay came from.
- (NSString *)gameOverlayDiagnosticContext:(SunPadGameOverlay *)overlay
{
    (void)overlay;
    NSBundle *bundle = NSBundle.mainBundle;
    NSString *version = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
    NSString *build = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?";
    UIDevice *device = UIDevice.currentDevice;
    return [NSString stringWithFormat:@"%@ %@ (%@) on %@ %@",
                                      BallpadAppDisplayName(), version, build,
                                      device.model, device.systemVersion];
}

- (NSString *)gameOverlayPerformanceProfile:(SunPadGameOverlay *)overlay
{
    (void)overlay;
    // This is not SunPad's emulator performance profile and must not be reported as one. What a
    // native-port build can honestly say is which build it is, because that is what a reader needs
    // to tell a Simulator result from a device one.
#if TARGET_OS_SIMULATOR
    return @"native port, Simulator";
#else
    return @"native port, device";
#endif
}

// Three of these four actions are Ballpad's own work now, and all three land in BallpadGameData.mm
// on the same store and the same validation the launch path uses -- so a menu row and a cold start
// cannot disagree about what "imported" means. The rows themselves are the vendored ones; only
// their destinations changed, which is the whole reason the adaptation lives here.
- (void)gameOverlayRequestsGameDataChange:(SunPadGameOverlay *)overlay
{
    (void)overlay;
    BallpadLog(@"host ui: game data change requested; opening BallPad's importer");
    BallpadGameDataPresentImport();
}

- (void)gameOverlayRequestsGameDataFolderImport:(SunPadGameOverlay *)overlay
{
    (void)overlay;
    BallpadLog(@"host ui: game data folder import requested; opening BallPad's importer");
    BallpadGameDataPresentFolderImport();
}

- (void)gameOverlayRequestsGameDataRemoval:(SunPadGameOverlay *)overlay
{
    // The overlay put up its own confirmation before calling this, so there is no second question
    // here; what is left is to do the work and say what happened. The running game keeps the disc
    // it already resolved, so the effect of this lands on the next launch -- which is only true
    // because PortHostUIGameDataPath stops answering as soon as the record names nothing.
    int removed = BallpadGameDataRemoveStoredData();
    BallpadLog(@"host ui: game data removal confirmed by the user; %d item(s) removed", removed);

    UIViewController *presenter = overlay.window.rootViewController;
    if (presenter == nil)
        return;
    NSString *message = removed > 0
        ? [NSString stringWithFormat:
               @"BallPad's stored disc was removed. The game keeps running on the disc it already "
                "loaded; quit and open %@ again to be asked for one. Save files and control "
                "settings are not affected.", BallpadAppDisplayName()]
        : @"There was nothing stored to remove. Save files and control settings are not affected.";
    // The alert this came from is still being dismissed, and a presentation started on top of a
    // dismissal in progress is dropped, so this waits it out rather than racing it.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"Game Data Removed"
                                               message:message
                                        preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
    });
}

// The fourth delegate action, and the one that used to be log-only. It is answered with the
// vendored A/B/X/Y/Z remap store, and that is now the only map a physical controller travels
// through: BallPad's GameController bridge is the single reader of a pad on this runtime, because
// SDL's MFi driver is switched off so that Aurora cannot read the same controller a second time
// (see BallpadPhysicalControllers.mm, and doc 42). The port's own STRIKERS_PAD_* table still exists
// but has no device to resolve against here, so a row that showed it would be describing a map
// nothing is read through.
- (void)gameOverlayRequestsControllerMapping:(SunPadGameOverlay *)overlay
{
    BallpadLog(@"host ui: controller mapping requested; presenting the port's own pad map");
    BallpadPresentOverlayViewController(overlay,
        [BallpadControllerMappingViewController mappingViewController]);
}

#pragma mark - Lifecycle

// The port already owns pause: Aurora turns SDL's minimized event -- which SDL's UIKit layer
// raises for UIApplicationDidEnterBackground -- into a frame it refuses to present, so there is
// deliberately no second pause here competing with it. Two things that seam does not cover do
// belong here. Input: a stick or button still held as the app leaves the foreground has no frame
// left to be released in, and a latched edge would then survive into the first frame after the
// resume -- the mixer is the one place that can guarantee the release, and it is the same
// boundary the per-frame publish reads. And controller visibility: re-reading GameController's
// enumeration on resume is what -refreshControllerVisibility is documented for, and it is a
// notification rather than a per-frame check because it animates the controls in or out.
- (void)applicationDidEnterBackground:(NSNotification *)notification
{
    (void)notification;
    NSDictionary *zones = objc_getAssociatedObject(self.overlay, BallpadPlantedZonesKey);
    for (BallpadPlantedZoneView *zone in zones.allValues)
        [zone ballpadEndTouch];
    [[SunPadInputMixer sharedMixer] clearInputFromTouch:YES];
    // The right shoulder's press is tracked by this side of the seam, so clearing the mixer is not
    // enough: a touch that ends while the app is away may never reach the control, and a shoulder
    // left held would be held for the rest of the session.
    s_rightShoulderHeld = false;
    s_rightShoulderPressEdge = false;
    // And the controller half, for exactly the reason the shoulder above needs its own line:
    // GameController stops delivering while the app is away, so a button held as the app goes into
    // the background has its release delivered to nobody. Left alone, the bridge's last published
    // state keeps that button down for the rest of the session -- and a stuck B is a front end that
    // walks out of every screen it is given. What is published when the app comes back is a fresh
    // read of the pad, not this one; see applicationDidBecomeActive:.
    [[BallpadPhysicalControllers sharedControllers] releaseHeldInput];
    BallpadLog(@"host ui: background; touch and controller input released at the mixer");
}

// Logged rather than acted on: the port resumes the frame loop from its own lifecycle, so the
// useful evidence is the ordering of the three notifications around a cycle.
- (void)applicationWillEnterForeground:(NSNotification *)notification
{
    (void)notification;
    BallpadLog(@"host ui: foreground; frame loop resumes on the port's own lifecycle");
}

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
    (void)notification;
    [self.overlay refreshControllerVisibility];
    // And the input bridge, for the same reason and one more: a pad paired while the app was in the
    // background has a connect notification that arrived while the app was not running a frame loop,
    // and a pad unplugged in that window has a disconnect the observer may have missed. The
    // reconcile is what makes the mixer's controller half agree with what is actually in the
    // session rather than with what was there when the app last drew.
    [[BallpadPhysicalControllers sharedControllers] reconcileControllers];
    // And a fresh read of the pads the bridge already held. The reconcile above cannot do it: a
    // controller that was configured before the app went away is still configured, so it is
    // deliberately left alone and nothing re-publishes what it is doing now. Without this the slot
    // resumes on the rest state the background cleared it to, and a stick held through the resume
    // reads as centred until the player moves it again.
    [[BallpadPhysicalControllers sharedControllers] resampleControllers];
    // The touch controls' own settings are re-read here for the same reason the controller
    // enumeration is: a foreground resume is the point at which what the user changed elsewhere --
    // in the Files-visible store, or in another scene -- can differ from what this overlay holds.
    [self.overlay applySettings];
    // And the overlay itself is re-attached. SDL rebuilds its view controller's view when the
    // surface comes back, which leaves this overlay parented to a view that is no longer on screen:
    // the game renders, the menu button is gone, and nothing about the renderer would say so. This
    // is the one place that has to notice.
    BallpadReattachOverlay(@"active");
    // The rebuilt view can arrive one main-queue turn after the notification rather than during it,
    // so the same check runs once more when the queue has drained. The second pass is a check, not a
    // second attach: it does nothing when the first one already found the overlay in place.
    dispatch_async(dispatch_get_main_queue(), ^{
        BallpadReattachOverlay(@"active-deferred");
    });
    BallpadLog(@"host ui: active; controller visibility and settings re-checked, overlay re-attached");
}

@end

// SDL3 hands out the UIWindow it created for the window the port presents into, which is the
// window whose view controller holds the render surface. The key-window search is a fallback so
// that a missing property cannot silently leave the player with no controls at all; it is a
// fallback because the SDL window is the one the renderer is attached to.
static UIWindow *BallpadWindowForSDLWindow(void *sdlWindow)
{
    if (sdlWindow != nullptr)
    {
        SDL_PropertiesID properties = SDL_GetWindowProperties((SDL_Window *)sdlWindow);
        UIWindow *window = (__bridge UIWindow *)SDL_GetPointerProperty(
            properties, SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, nullptr);
        if (window != nil)
            return window;
    }

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
    {
        if (![scene isKindOfClass:UIWindowScene.class])
            continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows)
        {
            if (window.isKeyWindow)
                return window;
        }
    }
    return nil;
}

// Where the overlay belongs: the view controller's view of the window the port renders into, which
// is the same surface PortHostUIStart attached it to. An overlay parented here lays its controls out
// against the bounds the game is actually drawn into. One left on a discarded view lays the same
// controls out for a window nobody is looking at -- the game is visible, the menu button is not --
// and nothing in the renderer would report it, which is why the resume path asks this question
// rather than assuming.
static void BallpadReattachOverlay(NSString *reason)
{
    if (s_overlay == nil)
        return;

    UIWindow *window = BallpadWindowForSDLWindow(s_sdlWindow) ?: s_overlay.window;
    if (window == nil)
    {
        // Nothing to attach to yet: a resume that has not rebuilt its window will land here and the
        // deferred pass will ask again.
        BallpadLog(@"host ui: overlay re-attach (%@) has no window yet", reason);
        return;
    }

    UIView *container = window.rootViewController.view ?: (UIView *)window;
    BOOL moved = (s_overlay.superview != container);
    if (moved)
    {
        [s_overlay removeFromSuperview];
        [container addSubview:s_overlay];
    }
    else
    {
        // Already in the right place, and still able to be behind the surface the port draws into:
        // the z-order is the half of "attached" that a superview check cannot see.
        [container bringSubviewToFront:s_overlay];
    }

    // The player's bounds are the current surface's, not the one the overlay was born on.
    s_overlay.frame = container.bounds;
    // Neither of these is set anywhere else in this build, and both are what a control-hide
    // animation's leftovers would look like; restoring them here is what makes a resume end with
    // controls rather than with a blank surface.
    s_overlay.hidden = NO;
    s_overlay.alpha = 1.0;
    [s_overlay setNeedsLayout];
    [s_overlay layoutIfNeeded];

    // Whether or not the superview moved, the button is re-derived: SunPad rebuilds its menu after
    // any inherited setting changes, and a rebuilt button carries no explicit appearance.
    BallpadConfigureMenuButton(BallpadMenuButton(s_overlay));
    // And its visibility, for the same reason: a rebuilt button is a visible one, so a player who
    // hid it would find it back after every resume.
    BallpadApplyMenuButtonVisibility(s_overlay, NO);
    // The reveal gesture belongs to the window, and a rebuilt surface can bring a different one.
    [s_bridge installRevealGestureOnWindow:window];

    // The same windowing read-back the first attach publishes: a resume and a rotation are the two
    // paths that can hand the overlay a different window from the one it was born on, and both are
    // cases where the frames a test process reads and the frames the overlay drew with can part
    // company without either side reporting it.
    BallpadLogHostGeometry(window, container);

    if (moved)
        BallpadLog(@"host ui: overlay re-attached (%@) to %@ %@", reason,
                   NSStringFromClass(container.class), NSStringFromCGRect(container.bounds));
}

// F04: what the engine did with a control, as opposed to what the overlay drew.
//
// doc 34's F04 asks for game response rather than hittability, and the two are different readings of
// the same touch. The overlay samplers above say a control was drawn pressed; this one says what the
// engine's own pad held, read back through PortPadEngineRead, which returns the bytes
// PadStatus::s_Current[0] carries -- the sample cPlatPad::IsPressed and the game's own tasks read.
// The host's own offer is printed on the same line because the claim is the pair: a control that
// reached the engine is what F04 wants, and an offer that never did is the failure this line has to
// be able to show.
//
// The one asymmetry, and it is arithmetic rather than assumption. The port builds a frame in this
// order (src/Game/main.cpp: PortUpdateSyntheticInput, then PortHostUIFrame, then
// PortInvokePadSamplingCallback): this host's poll, then this sampler, then the engine's own
// VBlankPadUpdate, which is the pass that clamps the assembled pad and swaps it into
// PadStatus::s_Current. So the sample read here during frame N is the one the engine assembled
// during frame N-1, and the offer it was made from is the poll of frame N-1 rather than the poll
// frame N has already made. Both are printed, "now" before "prev", because the difference between
// them is exactly the thing the line has to be able to show. The first run of this line printed the
// poll of the same frame alone, and every ramp in it disagreed in a way that looked like a fault:
// a main stick of 40 beside an offer of 75, a C-stick of 44 beside an offer of 84, a trigger of 150
// beside an offer of 255. None of those is a fault, and none is even a delay: each is the game's
// own clamp of the offer made one poll earlier. The clamp is PADClampCircle
// (extern/aurora/lib/dolphin/pad/pad.cpp), whose ClampRegion is stick min 15 radius 56, C-stick min
// 15 radius 44, trigger min 30 max 180, so a trigger of 255 becomes 150 and a stick of 127 becomes
// 56. With the pair stated, the button half is exact equality and the analog half is that clamp of a
// value the reader can see, which is a row that can be judged rather than explained away.
//
// There is one more difference between the sample and the offer, and it is the port's own, not the
// engine's. When the game enables its left-analog-to-d-pad map, the port reaches into the sample it
// has just published and ORs a compass bit into the buttons when the main stick's own normalized
// value reaches 0.6 of the clamp radius -- 33.6 of 56 (src/NL/plat/platpad.cpp, the
// m_isLeftAnalogToDPadMapEnabled branch of the VBlank swap). The bucket is a 45-degree step taken
// from a 16-bit tick of nlATan2f: angleU16 = (u16)(int)(angle * 10430.378f), scaled back by
// 0.005493164 and truncated to a multiple of 45. The cast is worth stating because it wraps rather
// than rounds -- an angle a hair below the positive X axis is negative before the cast, comes back
// just under 360 degrees, and lands in the 315 bucket, DOWN|RIGHT, rather than bucket 0 -- and
// because the bucket at exactly 180 degrees is LEFT, the map having zeroed a Y that never reached
// 0.6. Those bits are in the sample without ever being in an offer, so a reader who had only the
// offers would call them presses the host never made. They are why the read-back is judged as the
// previous offer PLUS the port's own map rather than as the previous offer alone.
//
// Written only when a field changes: the port's frame loop is not a place to write a line a frame.
// STRIKERS_LOG_CONSUME gates it, the convention the port's own STRIKERS_LOG_* variables use.
static PortHostPad s_offerThis;   // the poll this frame has made; the next sample will carry it
static PortHostPad s_offerPrev;   // the poll one frame back: what this frame's sample was made from
static BOOL s_haveOffer;

static void BallpadLogConsumptionIfChanged(void)
{
    static const int s_enabled = (getenv("STRIKERS_LOG_CONSUME") != NULL) ? 1 : 0;
    if (!s_enabled)
        return;

    PortPadEngineState engine;
    if (!PortPadEngineRead(0, &engine))
        return;

    static PortPadEngineState s_lastEngine;
    static BOOL s_haveEngine = NO;
    static int s_lastScene = -12345;

    // The engine's own front-end scene, from the label BaseGameSceneManager formats and pushes: the
    // scene a control was held in, and the scene it left. Without this the row could only say the
    // pad carried a bit, and a pad that carried a bit is exactly the reading an overlay drawing a
    // press would also produce. The number is the port's, not a re-parse here.
    const int scene = PortOverlaySceneNumber();
    if (s_haveEngine
        && engine.err == s_lastEngine.err
        && engine.buttons == s_lastEngine.buttons
        && engine.stickX == s_lastEngine.stickX
        && engine.stickY == s_lastEngine.stickY
        && engine.substickX == s_lastEngine.substickX
        && engine.substickY == s_lastEngine.substickY
        && engine.triggerLeft == s_lastEngine.triggerLeft
        && engine.triggerRight == s_lastEngine.triggerRight
        && scene == s_lastScene)
        return;

    s_lastEngine = engine;
    s_haveEngine = YES;
    s_lastScene = scene;

    // consume: is the tag the runner's read-back family greps for. Both offers are on the line, in
    // the order the paragraph above explains: "now" is the poll this frame made and "prev" is the
    // one whose clamp is what the engine's own pad holds here, so a reader can compare the sample
    // against the offer it was made from and against the one it was not. The scene label is last
    // because it carries spaces and is the only field a reader does not have to machine-parse; the
    // number in front of it is the one that is compared.
    BallpadLog(@"consume: frame %lu engine err %d buttons 0x%04x stick %d,%d sub %d,%d trig %d,%d"
                " now 0x%04x nstick %d,%d nsub %d,%d ntrig %d,%d"
                " prev 0x%04x pstick %d,%d psub %d,%d ptrig %d,%d scene %d -- %s",
               PortInputFrame(),
               engine.err, engine.buttons,
               engine.stickX, engine.stickY, engine.substickX, engine.substickY,
               engine.triggerLeft, engine.triggerRight,
               s_haveOffer ? s_offerThis.buttons : 0u,
               s_haveOffer ? s_offerThis.stickX : 0,
               s_haveOffer ? s_offerThis.stickY : 0,
               s_haveOffer ? s_offerThis.substickX : 0,
               s_haveOffer ? s_offerThis.substickY : 0,
               s_haveOffer ? s_offerThis.triggerLeft : 0,
               s_haveOffer ? s_offerThis.triggerRight : 0,
               s_haveOffer ? s_offerPrev.buttons : 0u,
               s_haveOffer ? s_offerPrev.stickX : 0,
               s_haveOffer ? s_offerPrev.stickY : 0,
               s_haveOffer ? s_offerPrev.substickX : 0,
               s_haveOffer ? s_offerPrev.substickY : 0,
               s_haveOffer ? s_offerPrev.triggerLeft : 0,
               s_haveOffer ? s_offerPrev.triggerRight : 0,
               scene, PortOverlaySceneName());
}

// The physical controller bridge's read-back, and it is a separate function from the consumption
// sampler above on purpose: that one answers what the engine's pad holds for the game, and this one
// answers what the bridge put in front of it. One line carries the whole chain a press travels --
// what the bridge published into the mixer's controller half, the offer the adapter's poll made out
// of that mixer this frame, and the engine's own pad as VBlankPadUpdate last assembled it. Those are
// three different claims in the order they are made, and a row holding only the offer could not tell
// a press this app made from a press the game took.
//
// Written when any of the three moves rather than once a frame, for the reason the sampler above
// gives, and gated by STRIKERS_LOG_CONTROLLER, which is the port's own STRIKERS_LOG_* convention.
// The engine's half lags the offer by one pad-assembly pass -- the ordering consume-summary.awk
// documents at length -- so a scripted step's press is expected to appear on a later line than the
// step that made it rather than on the same one.
static void BallpadLogControllerIfChanged(void)
{
    static const int s_enabled = (getenv("STRIKERS_LOG_CONTROLLER") != NULL) ? 1 : 0;
    if (!s_enabled)
        return;

    SunPadInputState published = {};
    const BOOL havePublished =
        [[BallpadPhysicalControllers sharedControllers] readPlayer:0 state:&published];

    PortPadEngineState engine;
    const BOOL haveEngine = PortPadEngineRead(0, &engine) ? YES : NO;

    static SunPadInputState s_ctrlLastPublished = {};
    static PortHostPad s_ctrlLastOffer = {};
    static PortPadEngineState s_ctrlLastEngine = {};
    static BOOL s_ctrlHavePublished = NO;
    static BOOL s_ctrlHaveOffer = NO;
    static BOOL s_ctrlHaveEngine = NO;

    const BOOL changed =
        havePublished != s_ctrlHavePublished
        || (havePublished && memcmp(&published, &s_ctrlLastPublished, sizeof(published)) != 0)
        || s_haveOffer != s_ctrlHaveOffer
        || (s_haveOffer && memcmp(&s_offerThis, &s_ctrlLastOffer, sizeof(s_offerThis)) != 0)
        || haveEngine != s_ctrlHaveEngine
        || (haveEngine && memcmp(&engine, &s_ctrlLastEngine, sizeof(engine)) != 0);
    if (!changed)
        return;

    s_ctrlLastPublished = published;
    s_ctrlHavePublished = havePublished;
    if (s_haveOffer)
        s_ctrlLastOffer = s_offerThis;
    s_ctrlHaveOffer = s_haveOffer;
    s_ctrlLastEngine = engine;
    s_ctrlHaveEngine = haveEngine;

    BallpadScriptedController *scripted = [BallpadScriptedController sharedScriptedController];
    BallpadLog(@"controller: frame %lu connected %d pub 0x%04x stick %d,%d cstick %d,%d trig %d,%d"
                " offer 0x%04x stick %d,%d cstick %d,%d trig %d,%d"
                " engine err %d buttons 0x%04x stick %d,%d sub %d,%d trig %d,%d"
                " script %@ step %s",
               PortInputFrame(), havePublished ? 1 : 0, (unsigned)published.buttons,
               published.stickX, published.stickY, published.cStickX, published.cStickY,
               published.triggerL, published.triggerR,
               s_haveOffer ? s_offerThis.buttons : 0u,
               s_haveOffer ? s_offerThis.stickX : 0, s_haveOffer ? s_offerThis.stickY : 0,
               s_haveOffer ? s_offerThis.substickX : 0, s_haveOffer ? s_offerThis.substickY : 0,
               s_haveOffer ? s_offerThis.triggerLeft : 0,
               s_haveOffer ? s_offerThis.triggerRight : 0,
               haveEngine ? engine.err : 0, haveEngine ? engine.buttons : 0u,
               haveEngine ? engine.stickX : 0, haveEngine ? engine.stickY : 0,
               haveEngine ? engine.substickX : 0, haveEngine ? engine.substickY : 0,
               haveEngine ? engine.triggerLeft : 0, haveEngine ? engine.triggerRight : 0,
               [scripted scriptName] != nil ? [scripted scriptName] : @"none",
               [scripted currentStepName]);
}

// The scripted controller's clock, and it is one port frame: the script advances in the frames the
// engine runs in rather than on a timer, so a step lasts the same number of frames in a fast run and
// a slow one and the recorded evidence says what the pad was doing on the frames the game saw.
//
// Started from here rather than from PortHostUIStart for one reason and it is not a preference: a
// virtual controller connected inside the port's start hook lands in the session before
// GameController has finished its own first enumeration, and the bridge would then be reconciling
// against a list that is still being built. By the first frame the app is past launch, and the first
// frame is early enough -- the pad has to be connected before the port's pad-assembly pass for the
// first press to be read on a frame, not after it.
static void BallpadAdvanceScriptedController(void)
{
    static bool s_started = false;
    BallpadScriptedController *scripted = [BallpadScriptedController sharedScriptedController];
    if (!s_started)
    {
        s_started = true;
        // No STRIKERS_FAKE_PAD, which is every launch a player makes: this returns NO and the whole
        // scripted path stays out of the run.
        if (![scripted startIfEnabled])
            return;
    }
    [scripted advanceFrame];
}

// The coordinate space the interface is actually laid out in, in the app's own words.
//
// Every row that addresses a control by a point inside its element frame is trusting one
// assumption -- that the rectangle the test process reads off the accessibility tree and the
// rectangle the overlay lays itself out against are the same one. On this build those two can
// disagree: the app is landscape-only (UIRequiresFullScreen, both landscape sides), so a surface
// that reaches the screen through a window whose logical size is not the interface's leaves the
// element frames scaled and offset relative to the numbers the overlay drew with -- and a slider
// addressed by a point inside its own frame then lands short of the end of its own track. That
// failure reads exactly like a control that will not reach its maximum, so the two have to be
// told apart from the app, not from the reading.
//
// The window, its scene, its screen and the surface the overlay is parented to are published here
// together with the R button converted out of the overlay's space and into the window's and the
// screen's, which is the same control the accessibility tree reports for the same launch. A
// reported frame that agrees with the conversion is a layout that moved; one that disagrees with a
// window that is not the interface's own size is the adaptation boundary rather than the interface.
static void BallpadLogHostGeometry(UIWindow *window, UIView *container)
{
    if (window == nil)
        return;

    UIView *probe = nil;
    if ([s_overlay isKindOfClass:SunPadGameOverlay.class])
    {
        for (UIView *control in BallpadTouchControlsInDrawOrder(s_overlay))
        {
            if ([control.accessibilityIdentifier isEqualToString:@"R"])
            {
                probe = control;
                break;
            }
        }
    }

    NSString *probeText = @"no R control to convert";
    if (probe != nil)
    {
        const CGRect inWindow = [probe convertRect:probe.bounds toView:nil];
        const CGRect onScreen = [window convertRect:inWindow toCoordinateSpace:window.screen.coordinateSpace];
        probeText = [NSString stringWithFormat:@"R own %@ window %@ screen %@",
                     NSStringFromCGRect(probe.frame), NSStringFromCGRect(inWindow),
                     NSStringFromCGRect(onScreen)];
    }

    BallpadLog(@"host ui: geometry window %@ frame %@ transform %@ screen %@ native %@ scale %.2f"
                " scene %@ interface %ld container %@ %@ overlay %@ %@ | %@",
               NSStringFromCGRect(window.bounds), NSStringFromCGRect(window.frame),
               CGAffineTransformIsIdentity(window.transform)
                   ? @"identity"
                   : NSStringFromCGAffineTransform(window.transform),
               NSStringFromCGRect(window.screen.bounds),
               NSStringFromCGRect(window.screen.nativeBounds),
               (double)window.screen.scale,
               NSStringFromCGRect(window.windowScene.coordinateSpace.bounds),
               (long)window.windowScene.interfaceOrientation,
               NSStringFromClass(container.class), NSStringFromCGRect(container.frame),
               NSStringFromClass(s_overlay.class), NSStringFromCGRect(s_overlay.frame),
               probeText);
}

extern "C" void PortHostUIDiagnostic(const char *message)
{
    BallpadLog(@"engine: %s", message != nullptr ? message : "");
}

extern "C" void PortHostUIStart(void *sdlWindow)
{
    @autoreleasepool
    {
        if (s_overlay != nil)
            return;   // once per process; a second call is a port bug, not a second window

        // The controller bridge, and it is started before the window check for the same reason the
        // frame hook keeps its read-backs above the overlay's: this is the app's input boundary
        // rather than a piece of the interface. Two things follow from where it sits. A pad that
        // was already connected when the app started is in the mixer before the port's first poll,
        // because the bridge enumerates the session's controllers on start rather than waiting for
        // a notification that a connection already made will never post. And a run with no window
        // still has a working pad, which is the honest state of the input path.
        [[BallpadPhysicalControllers sharedControllers] start];

        // Kept for the resume path: the pointer is how a rebuilt surface's window is found again
        // after the overlay's own window reference has gone nil.
        s_sdlWindow = sdlWindow;
        UIWindow *window = BallpadWindowForSDLWindow(sdlWindow);
        if (window == nil)
        {
            BallpadLog(@"host ui: no UIWindow for the port's SDL window; no touch controls");
            s_sdlWindow = nullptr;
            return;
        }

        UIView *host = window.rootViewController.view ?: window;
        // BallpadGameOverlay, not the vendored class: the only difference is the menu, and
        // everything else -- layout, hit-testing, the rows, the alerts -- is the vendored code.
        s_overlay = [[BallpadGameOverlay alloc] initWithFrame:host.bounds];
        // The SDL view controller resizes its view for a rotation, a size class change and a
        // safe-area change alike. Matching its autoresizing mask is what keeps SunPad's layout
        // math -- which reads its own bounds and insets -- on the same surface as the game.
        s_overlay.autoresizingMask =
            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        s_bridge = [BallpadHostUIBridge new];
        s_bridge.overlay = s_overlay;
        s_overlay.delegate = s_bridge;
        [host addSubview:s_overlay];

        // The menu button starts in whatever state the player last left it, and the two-finger tap
        // that brings a hidden one back goes on the window rather than the overlay -- the overlay
        // passes empty space through to the game, so a tap on nothing never reaches it.
        BallpadApplyMenuButtonVisibility(s_overlay, NO);
        [s_bridge installRevealGestureOnWindow:window];

        // Registered once, for the same reason the overlay is built once: the notifications are
        // process-wide and the bridge is the process's single receiver for them.
        NSNotificationCenter *notifications = NSNotificationCenter.defaultCenter;
        [notifications addObserver:s_bridge
                          selector:@selector(applicationDidEnterBackground:)
                              name:UIApplicationDidEnterBackgroundNotification
                            object:nil];
        [notifications addObserver:s_bridge
                          selector:@selector(applicationWillEnterForeground:)
                              name:UIApplicationWillEnterForegroundNotification
                            object:nil];
        [notifications addObserver:s_bridge
                          selector:@selector(applicationDidBecomeActive:)
                              name:UIApplicationDidBecomeActiveNotification
                            object:nil];

        // The overlay's own log is what makes a menu action visible after the fact, and those menu
        // actions write to SunPadDiagnostics' file. Ballpad keeps a log of its own as well (item
        // 13): the vendored component's directory is a static function inside its own .mm, so it
        // cannot be redirected without editing a file whose bytes are the fidelity claim, and the
        // component legitimately keeps a log of where it is. Both files are named for their owner
        // here so a reader knows which one they are holding.
        SunPadDiagnosticsStart();
        BallpadLogStart();
        BallpadLog(@"host ui: BallPad log %@; vendored interface log %@",
                   BallpadLogPath(), SunPadDiagnosticsLogPath());

        // The frame-limit row's state is Ballpad's own key (item 11), and the port reads
        // STRIKERS_FPS_LIMIT before this hook ever runs. Re-applying it here is what makes the row's
        // choice survive a cold start rather than only the run that set it.
        PortSetFrameLimit(BallpadFrameLimitIsUnlimited() ? 0.0 : -1.0);

        BallpadLog(@"host ui: overlay %@ over %@ (%@)",
                   NSStringFromCGRect(s_overlay.frame), host, NSStringFromCGRect(host.bounds));
        BallpadLogHostGeometry(window, host);
    }
}

extern "C" int PortHostUIPollPad(PortHostPad *out)
{
    // Deliberately not gated on the overlay. The overlay is the touch half of this app's input; the
    // controller bridge is the other half, and it is started in PortHostUIStart before the window is
    // even looked for, precisely so a run with no overlay still has a working pad. Refusing to poll
    // while the overlay is missing -- a lifecycle rebuild is the case that happens -- did two things,
    // and both were wrong: it dropped a physical controller's input for those frames, and because the
    // mixer latches rising edges and only clears them when it is consumed, every press made in that
    // window was held and then delivered all at once on the first frame after the overlay came back.
    if (out == nullptr)
        return 0;

    // Logged once rather than per frame. This is the only line that shows the port's frame loop
    // reached the app's adapter -- which is a real question here, because the port also carries a
    // weak no-op for this same function and a build that resolved to that one would look identical
    // from the outside -- and at sixty a second it would be noise that hides everything else.
    static bool s_loggedFirstPoll = false;
    if (!s_loggedFirstPoll)
    {
        s_loggedFirstPoll = true;
        BallpadLog(@"host ui: first pad poll; the port is driving this adapter");
    }

    // Read the mixer exactly once per frame, as its header requires: it clears its latched button
    // edges as it is consumed, so a second read in the same frame finds them gone, and a frame
    // that skipped the read carries a tap past the frame it belonged to.
    SunPadInputState state = [[SunPadInputMixer sharedMixer] consumeMergedState];
    out->buttons = BallpadPortButtons(state.buttons);
    out->stickX = state.stickX;
    out->stickY = state.stickY;
    out->substickX = BallpadCStickX(state.cStickX);
    out->substickY = state.cStickY;
    // Read back where the flip lands rather than where the preference lives (R1 item 5).
    BallpadLogCStickIfTurned(state.cStickX, out->substickX);
    out->triggerLeft = state.triggerL;
    out->triggerRight = state.triggerR;

    // The right shoulder's press, which the vendored control reports only from the end of its spray
    // track (see the note on the flags above). L's own handler reports the top of its analog range
    // as well as its bit, so R reports the same pair: the bit the game reads, and 255. The control's
    // own continuous pressure keeps arriving through state.triggerR and is left alone whenever it is
    // the larger of the two readings, which is the same "strongest reading wins" rule the mixer uses.
    if (BallpadRightShoulderPressed())
    {
        out->buttons |= PORT_PAD_TRIGGER_R;
        if (out->triggerRight < 255)
            out->triggerRight = 255;
    }

    // The two offers the sampler above pairs with the engine's reading. Recorded here rather than in
    // that sampler because this is the only place the whole offer exists: this struct belongs to the
    // port's frame and is gone by the time the sampler runs, and the claim is about the pair. Both are
    // kept for the reason the block above records, and the shift is ordered so that the offer this
    // poll just made becomes the sampler's "now" while the previous poll becomes its "prev" -- the
    // one the engine's own VBlank pass has already clamped into the sample the sampler will read.
    s_offerPrev = s_offerThis;
    s_offerThis = *out;
    s_haveOffer = YES;
    return 1;
}

// ── The main thread, shared ───────────────────────────────────────────────────
// The port's frame loop owns the main thread outright: src/Game/main.cpp runs `while (running)`
// from the scene delegate, and the only place UIKit gets a turn is SDL's own pump, which runs the
// run loop for two microseconds and stops at the first source it handles (UIKit_PumpEvents,
// SDL_uikitevents.m). That is enough for a touch to be delivered and nowhere near enough for UIKit
// to run a menu: a presented sheet animates, lays out, and hit-tests on the same thread the game
// is holding, so it arrives in stutters and feels like the app has stopped.
//
// It also hides a second defect, which is the one that turns a slow menu into an unresponsive app.
// When `aurora_begin_frame()` returns false -- no surface, not presentable, paused -- the port's
// loop `continue`s from the top, and the frame limiter it skips is inside `RunAllTasks`
// (src/platform/vi.c sleeps there). So the loop stops being paced at all and spins a core flat out,
// which is both the heat and the "until I close and return to the app": a foreground resume is what
// rebuilds the surface and lets the loop pace itself again.
//
// One mechanism answers both, and it is the only thing the app can do from inside a hook the loop
// calls: spend part of each frame running the run loop properly. `BallpadYieldToUIKit` drains it
// until it reports nothing left to handle or a budget is gone, so a frame with an idle UI costs
// nothing and a frame with a menu on screen hands UIKit most of the time. The floor below it then
// guarantees a minimum interval between frames, which is what caps a spinning loop -- and because
// the floor is also spent in the run loop rather than asleep, the spin becomes idle time UIKit can
// use rather than a burning core.
//
// The budget is bounded by the audio, not by taste. PortAudioUpdate tops the stream up to
// kTargetBuffers (6) of MusyX's own buffers and runs once per frame, so a frame interval that grows
// past that queue underruns the device. The ceiling here keeps the whole frame inside it with
// margin.
namespace {

// What one frame of the game may give UIKit while something of this app's own is on screen. It is
// bounded by the audio rather than by taste: PortAudioUpdate tops the stream up to kTargetBuffers
// (six of MusyX's own buffers, about 30 ms) once per frame, so a frame interval that grows past
// that queue underruns the device. Fourteen milliseconds on top of a frame the engine already
// spends leaves the whole frame inside it with margin, and is several times what UIKit needs to
// animate a menu.
constexpr CFTimeInterval kBallpadUIKitBudget = 0.014;
// What an ordinary frame spends handing over work that is already queued. Nothing waits here, so a
// frame of play costs one poll of a run loop with nothing in it.
constexpr CFTimeInterval kBallpadUIKitPollBudget = 0.001;
// What one iteration of a loop that is not completing frames waits for. It is the pacing for the
// spin above and nothing else: the port's own limiter paces every frame that reaches it.
constexpr CFTimeInterval kBallpadSkippedFrameWait = 0.005;
// How many frames of an idle run loop end the menu's claim on the thread. Two, because a UIMenu
// that is open has work every frame and one that has closed has none.
constexpr int kBallpadIdleFramesToRelease = 2;

// Wait in the run loop for up to `budget`, letting UIKit run. Returns true when the budget ran out
// with work still arriving; false when the run loop went quiet, which is what idle looks like.
//
// The wait is the point. A run loop polled with a zero timeout hands over only what is already
// queued and returns, which drains a backlog but gives UIKit no time of its own -- and UIKit's work
// arrives over the frame, on timers and on its own display link, not in a lump at the start of it.
bool BallpadWaitInRunLoop(CFTimeInterval budget)
{
    const CFTimeInterval deadline = CACurrentMediaTime() + budget;
    for (;;)
    {
        const CFTimeInterval remaining = deadline - CACurrentMediaTime();
        if (remaining <= 0.0)
            return true;
        // returnAfterSourceHandled, so the deadline is re-checked between sources rather than after
        // the whole budget; a quiet run loop blocks until the deadline and reports the timeout.
        if (CFRunLoopRunInMode(kCFRunLoopDefaultMode, remaining, true) != kCFRunLoopRunHandledSource)
            return false;
    }
}

// Hand over whatever is already queued, without waiting for more.
void BallpadPollRunLoop(void)
{
    const CFTimeInterval deadline = CACurrentMediaTime() + kBallpadUIKitPollBudget;
    while (CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.0, true) == kCFRunLoopRunHandledSource)
    {
        if (CACurrentMediaTime() >= deadline)
            break;
    }
}

// Whether something of the app's own is on screen. The presented controller covers every sheet this
// app puts up -- the mapping panel, credits, game data, an alert, a share sheet -- the layout editor
// is the overlay's own mode rather than a presentation, and the menu announces itself through
// -buildMenu because UIKit gives it a window of its own to live in.
bool BallpadHostUIIsPresenting(UIWindow *window)
{
    if (CACurrentMediaTime() < s_menuInteractionUntil)
        return true;
    if (window != nil && window.rootViewController.presentedViewController != nil)
        return true;
    return [SunPadSettings sharedSettings].editingControlLayout;
}

}   // namespace

// The share of the frame this app gives back to UIKit, and the floor that paces a loop nothing else
// is pacing. Called once per frame, at the end of the host's own per-frame work.
static void BallpadShareMainThread(UIWindow *window)
{
    static unsigned long s_lastPortFrame = 0;
    static BOOL s_havePortFrame = NO;
    static int s_idleFrames = 0;

    // Whether the previous iteration of the port's loop completed a frame. `s_portFrame` is
    // incremented after `aurora_end_frame()`, and `PortUpdateSyntheticInput` publishes it just
    // before this hook runs, so a counter that has not moved since the last call is exactly the
    // `continue` that skipped `RunAllTasks` -- and with it the limiter that would have paced the
    // loop. This is the only case the wait below exists for; a frame that was drawn was paced by
    // the port itself, including the uncapped row, which is deliberately left uncapped.
    const unsigned long portFrame = PortInputFrame();
    const BOOL skipped = s_havePortFrame && portFrame == s_lastPortFrame;
    s_lastPortFrame = portFrame;
    s_havePortFrame = YES;

    if (BallpadHostUIIsPresenting(window))
    {
        if (BallpadWaitInRunLoop(kBallpadUIKitBudget))
        {
            s_idleFrames = 0;
        }
        else if (++s_idleFrames >= kBallpadIdleFramesToRelease)
        {
            // Whatever was up has stopped asking for the thread. Releasing the menu's claim here is
            // what keeps a deadline nothing can cancel from costing ten seconds of pacing.
            s_menuInteractionUntil = 0.0;
            s_idleFrames = 0;
        }
    }
    else
    {
        s_idleFrames = 0;
        BallpadPollRunLoop();
    }

    // And the pacing for a loop that is not pacing itself. Spent waiting in the run loop rather than
    // asleep, so the spin becomes idle time UIKit can use instead of a burning core -- which is what
    // makes the app answer a touch while the surface it would draw into is missing.
    if (skipped)
        BallpadWaitInRunLoop(kBallpadSkippedFrameWait);
}

extern "C" void PortHostUIFrame(void)
{
    @autoreleasepool
    {
        // The frame clock the audio read-back is judged against: one count per port loop iteration,
        // incremented before anything can return early, because a frame that draws nothing is still
        // a frame the game ran.
        ++s_framesPolled;

        // And the scripted controller's own step, when STRIKERS_FAKE_PAD named one: a frame here is
        // a frame the engine ran, which is the clock the script's steps are counted in.
        BallpadAdvanceScriptedController();

        // Before the overlay check, because this is a bridge between the store and the port rather
        // than a piece of the interface: it has to run for the whole run, including the frames
        // before the overlay exists and the frames after a lifecycle rebuild has not put one back
        // yet. See the block above for why it lives here rather than in the menu's handlers.
        BallpadApplyDisplaySettings();

        // Cheap, bounded and next to the bridge above: six comparisons a frame, one log line on the
        // frame a setting actually moved. This is the path a panel change takes to the log, since
        // the panel's own controls belong to the vendored bytes and cannot be hooked.
        BallpadLogSettingsIfPanelChanged();

        // The audio read-back on its own clock, for the same reason it exists at all: the device
        // can fail to open before any row or setting exists to report it, and a line written only
        // when something changes would leave that failure in the log as an absence.
        BallpadLogAudioIfDue();

        // The engine's own pad, for F04: the overlay samplers say a control was drawn, and this one
        // says the game read it. It sits with the bridges above rather than below the overlay check
        // for the same reason they do -- the reading is of the engine, and it is the frames with no
        // overlay (a lifecycle rebuild) where an offer with no reader would otherwise be invisible.
        BallpadLogConsumptionIfChanged();

        // And the same frame from the other side: the bridge's own published slot, the offer it
        // became, and the engine's pad. Gated by STRIKERS_LOG_CONTROLLER, and next to the sampler
        // above because the two are read together -- one says what the host offered, the other says
        // what the game took.
        BallpadLogControllerIfChanged();

        if (s_overlay == nil)
        {
            // Still shared, and this is the path where it matters most: no overlay is the lifecycle
            // rebuild, and a rebuild is exactly when the surface is gone and the port's loop is
            // spinning unpaced.
            BallpadShareMainThread(nil);
            return;
        }

        // The one per-frame job here, and it is a reading rather than an invention: the FPS row's
        // counter (item 5). The overlay's own layout stays where it is -- a resize is UIKit's to
        // report -- and the GameController re-check after a foreground resume is a lifecycle
        // notification rather than a per-frame poll (N4-C), because doing it here would restart the
        // control-hide animation sixty times a second. A counter updated only when something else
        // happens is not a counter, so this one is refreshed every frame while it is shown.
        BallpadRefreshFPSCounter(s_overlay);

        // And the touch settings as the overlay draws them, which is the half of R1 item 5 the
        // store cannot answer: a slider holds a number, this holds the control that was drawn with
        // it. On a settling clock, because a drag moves the tree on every frame of the touch.
        BallpadLogOverlayTouchIfSettled(s_overlay);

        // And the shoulders' press outlines, the reading the overlay line above cannot give: a
        // press does not re-lay the tree out, so only a per-frame sample sees it. See the sampler
        // for why the pair is the value rather than a count.
        BallpadLogShoulderOutlineIfChanged(s_overlay);

        // And the safe-area verdict (F06): the same settled pass over the drawn tree as the
        // overlay read-back above, measured against the overlay's own -safeAreaInsets, which is the
        // only thing that moves when the device is turned from one landscape side to the other.
        BallpadLogLayoutIfSettled(s_overlay);

        // The menu button's own clock: a reveal is held for a few seconds and then taken back, and
        // this is the only thing that runs often enough to notice the few seconds are up.
        BallpadExpireMenuButtonReveal(s_overlay);

        // Last, because everything above is this frame's work and this is what is left of it.
        BallpadShareMainThread(s_overlay.window);
    }
}

extern "C" void PortHostUIStop(void)
{
    @autoreleasepool
    {
        // Before the overlay goes, and in the reverse order of PortHostUIStart: the scripted
        // controller lets go of its virtual pad, then the bridge releases every slot and clears the
        // mixer's controller half. A pad held as the app went away must not be held by the next
        // session, and a virtual controller left connected would survive the stop and be reconciled
        // by a bridge that no longer exists.
        [[BallpadScriptedController sharedScriptedController] stop];
        [[BallpadPhysicalControllers sharedControllers] stop];

        if (s_bridge != nil)
            [NSNotificationCenter.defaultCenter removeObserver:s_bridge];

        SunPadGameOverlay *overlay = s_overlay;
        s_overlay = nil;
        s_sdlWindow = nullptr;
        overlay.delegate = nil;
        [overlay removeFromSuperview];
        s_bridge = nil;
    }
}
