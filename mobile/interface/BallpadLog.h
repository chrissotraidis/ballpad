// Ballpad's own log and diagnostic report, as the rest of the app sees them.
//
// Two R1 rows in doc 36 are the reason this file exists rather than a call into the vendored
// diagnostics.
//
// Row 13 asks for the log to live in Ballpad's own directory. The vendored component's log
// directory is a static function inside SunPadDiagnostics.mm, so it cannot be redirected without
// editing a file whose bytes are the fidelity claim (row 1), and the vendored component legitimately
// keeps a log of its own. What Ballpad can do -- and what it does here -- is own a log of its own, at
// a path a person can reach through Files, and write the adapter's own breadcrumbs into it. The two
// files are described as what they are: one is Ballpad's, the other is the vendored component's.
//
// Row 10 asks where a problem report goes. As shipped, the vendored row files a GitHub issue against
// the project the interface came from, which is wrong for this app -- a Ballpad report must not land
// on that project's tracker -- and this assignment does not authorise messaging maintainers. So the
// report this writes is local: it names no remote tracker, it is written where the player can attach
// it to whatever they choose, and the row that calls it offers a share sheet rather than a URL.

#ifndef BALLPAD_LOG_H
#define BALLPAD_LOG_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Rotates the log if it has grown past the cap and writes the session's opening lines. Called once,
// from the adapter's start hook, so the file a report reads begins with the run that produced it.
FOUNDATION_EXPORT void BallpadLogStart(void);

// One timestamped line: the unified device log and Ballpad's own file. Low-frequency breadcrumbs
// rather than per-frame tracing -- the frame loop's own numbers belong to the port and to the FPS
// counter, not here.
FOUNDATION_EXPORT void BallpadLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

// <container>/Documents/BallpadLogs/runtime.log -- inside the document folder, so a person can get at
// it through Files, and inside a directory whose name is this app's. Never nil.
FOUNDATION_EXPORT NSString *BallpadLogPath(void);

// The report the problem row leaves behind: reporter answers, technical context, and the tails of
// both logs, written to <container>/Documents/Diagnostics/. Returns nil only when the write itself
// failed, with `error` filled in.
FOUNDATION_EXPORT NSURL *_Nullable BallpadDiagnosticsReportURL(
    NSString *reportID,
    NSDictionary<NSString *, NSString *> *reporterAnswers,
    NSString *technicalContext,
    NSError **error);

// The report identifier the row shows the player, so a report and a log line can be matched up.
// BP-XXXXXXXX, which is deliberately not the vendored component's SP- prefix.
FOUNDATION_EXPORT NSString *BallpadNewReportID(void);

// The app's own name, in one place, because four things have to agree on it: the state window's
// title, the overlay's menu header, the app's own alerts, and the folder name the Files app gives
// this app. Read from the bundle's display name rather than written out again, so a spelling that
// lives in the bundle cannot drift from the spellings in code; the literal is the fallback for a
// bundle that somehow carries no name at all. It lives in this header because this is where the
// app-level facts the rest of Ballpad asks for already are.
FOUNDATION_EXPORT NSString *BallpadAppDisplayName(void);

// One line naming every touch-control setting and its value, read back from the store rather than
// from the panel that set it. The settings surface is the vendored component's, so a row landing
// there is not the same claim as the value the rest of the build reads; this is the read-back that
// tells those two apart, and it is written on the changes that matter (a pinned display setting, a
// menu row, the panel's own controls) rather than per frame.
FOUNDATION_EXPORT void BallpadLogSettingsSnapshot(NSString *what);

// The one setting whose store is Ballpad's rather than the vendored component's: the frame-rate
// row's own key (doc 36 R1 item 11). It is declared here, next to the display name, because this
// header is where the app-level facts the rest of Ballpad asks for already are, and because the
// settings read-back below has to name it to report it.
FOUNDATION_EXPORT NSString *const BallpadFrameLimitUnlimitedKey;

// And the menu button's own: whether the three-dot button is kept off the screen while playing. It
// is Ballpad's key for the same reason the one above is -- the vendored component has no such row --
// and the settings read-back names it so a report says whether the button was hidden when something
// could not be reached.
FOUNDATION_EXPORT NSString *const BallpadHideMenuButtonKey;

NS_ASSUME_NONNULL_END

#endif // BALLPAD_LOG_H
