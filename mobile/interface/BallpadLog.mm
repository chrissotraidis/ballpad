// Ballpad's own log and diagnostic report.
//
// The design notes live with the declarations in BallpadLog.h; what is here is the writing. Three
// properties are worth stating because the code below depends on them:
//
//   * every path is derived from the document folder, so nothing here needs a UI framework and the
//     files are reachable through Files on a device;
//   * a write is one file handle opened, appended and closed, under a lock, because the frame loop
//     and UIKit can both call in and neither is allowed to lose a line;
//   * a report only ever reads what is already on disk. Nothing is uploaded, no URL is opened, and
//     the report says so in its own header, because the row that produces it is the one R1 row 10
//     found pointing at another project's issue tracker.

#import "BallpadLog.h"

#import "SunPadDiagnostics.h"
#import "SunPadSettings.h"

// The cap is the vendored component's own, for the same reason: a log that a person can open should
// not grow without bound, and one rotation is enough to keep the run that matters.
static NSUInteger const BallpadMaximumLogBytes = 1024 * 1024;

// How much of each log a report carries. Bounded because a report is something a person reads and
// attaches, not an archive.
static NSUInteger const BallpadReportTailBytes = 64 * 1024;

static NSObject *BallpadLogLock(void)
{
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [NSObject new];
    });
    return lock;
}

static NSString *BallpadDocumentsDirectory(void)
{
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documents = paths.firstObject;
    return documents.length > 0 ? documents : NSTemporaryDirectory();
}

static NSString *BallpadLogDirectory(void)
{
    return [BallpadDocumentsDirectory() stringByAppendingPathComponent:@"BallpadLogs"];
}

NSString *BallpadLogPath(void)
{
    return [BallpadLogDirectory() stringByAppendingPathComponent:@"runtime.log"];
}

static NSString *BallpadPreviousLogPath(void)
{
    return [BallpadLogDirectory() stringByAppendingPathComponent:@"runtime.previous.log"];
}

// The same two substitutions the vendored diagnostics make, and for the same reason: a report is
// meant to leave the device, and an absolute container path in it tells the reader nothing they need
// and everything about the device it came from.
static NSString *BallpadRedacted(NSString *value)
{
    NSString *redacted = value ?: @"";
    NSString *temporary = NSTemporaryDirectory();
    if (temporary.length > 1)
        redacted = [redacted stringByReplacingOccurrencesOfString:temporary
                                                       withString:@"<temporary>/"];
    NSString *home = NSHomeDirectory();
    if (home.length > 0)
        redacted = [redacted stringByReplacingOccurrencesOfString:home
                                                       withString:@"<app-container>"];
    return redacted;
}

static NSString *BallpadTimestamp(void)
{
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
        NSISO8601DateFormatWithFractionalSeconds;
    return [formatter stringFromDate:NSDate.date];
}

// The last `limit` bytes of a file, decoded as UTF-8 and with a leading partial line dropped.
// Reading the tail rather than the whole file is what keeps a report's size a property of the
// report rather than of how long the app has been running.
static NSString *BallpadTailOfFile(NSString *path, NSUInteger limit)
{
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (handle == nil)
        return @"unavailable\n";
    unsigned long long size = handle.seekToEndOfFile;
    unsigned long long start = size > limit ? size - limit : 0;
    [handle seekToFileOffset:start];
    NSData *data = [handle readDataToEndOfFile];
    [handle closeFile];

    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text == nil)
        return @"unavailable\n";
    if (start > 0) {
        NSRange firstNewline = [text rangeOfString:@"\n"];
        if (firstNewline.location != NSNotFound)
            text = [text substringFromIndex:NSMaxRange(firstNewline)];
    }
    return [text hasSuffix:@"\n"] ? text : [text stringByAppendingString:@"\n"];
}

void BallpadLogStart(void)
{
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSString *directory = BallpadLogDirectory();
    [fileManager createDirectoryAtPath:directory
           withIntermediateDirectories:YES
                            attributes:nil
                                 error:nil];

    @synchronized (BallpadLogLock()) {
        NSString *current = BallpadLogPath();
        NSDictionary<NSFileAttributeKey, id> *attributes =
            [fileManager attributesOfItemAtPath:current error:nil];
        if (attributes.fileSize > BallpadMaximumLogBytes) {
            NSString *previous = BallpadPreviousLogPath();
            [fileManager removeItemAtPath:previous error:nil];
            [fileManager moveItemAtPath:current toPath:previous error:nil];
        }
    }

    NSBundle *bundle = NSBundle.mainBundle;
    BallpadLog(@"session start version=%@ build=%@ os=%@",
               [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown",
               [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown",
               NSProcessInfo.processInfo.operatingSystemVersionString);
    BallpadLog(@"log path %@", BallpadLogPath());
}

void BallpadLog(NSString *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);

    message = BallpadRedacted(message);
    NSLog(@"[Ballpad] %@", message);

    NSString *line = [NSString stringWithFormat:@"%@ %@\n", BallpadTimestamp(), message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (data == nil)
        return;

    @synchronized (BallpadLogLock()) {
        NSString *path = BallpadLogPath();
        NSFileManager *fileManager = NSFileManager.defaultManager;
        if (![fileManager fileExistsAtPath:path])
            [fileManager createDirectoryAtPath:BallpadLogDirectory()
                   withIntermediateDirectories:YES
                                    attributes:nil
                                         error:nil];
        if (![fileManager fileExistsAtPath:path])
            [fileManager createFileAtPath:path contents:nil attributes:nil];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle closeFile];
    }
}

NSString *BallpadNewReportID(void)
{
    return [NSString stringWithFormat:@"BP-%@",
            [[[NSUUID UUID] UUIDString] substringToIndex:8]];
}

NSString *BallpadAppDisplayName(void)
{
    NSBundle *bundle = NSBundle.mainBundle;
    return [bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"]
        ?: [bundle objectForInfoDictionaryKey:@"CFBundleName"]
        ?: @"BallPad";
}

NSURL *BallpadDiagnosticsReportURL(
    NSString *reportID,
    NSDictionary<NSString *, NSString *> *reporterAnswers,
    NSString *technicalContext,
    NSError **error)
{
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSMutableString *report = [NSMutableString string];
    [report appendString:@"BallPad Diagnostic Report v1\n"];
    [report appendFormat:@"reportID=%@\n", reportID];
    [report appendFormat:@"generated=%@\n", BallpadTimestamp()];
    // Written down rather than left implicit, because the destination is the thing R1 row 10
    // changed: a reader of this file can see that nothing was sent anywhere.
    [report appendString:@"tracker=https://github.com/chrissotraidis/ballpad/issues\nattachment=local log; attach manually before submitting\n\n"];
    [report appendString:@"[Reporter Answers]\n"];
    for (NSString *key in @[@"problem", @"context", @"frequency"]) {
        NSString *value = BallpadRedacted(reporterAnswers[key] ?: @"");
        [report appendFormat:@"%@=%@\n", key, value.length > 0 ? value : @"not provided"];
    }
    [report appendString:@"\n[Technical Context]\n"];
    [report appendString:BallpadRedacted(technicalContext ?: @"unavailable")];
    if (![report hasSuffix:@"\n"])
        [report appendString:@"\n"];
    [report appendString:@"\n[Control Layout]\n"];
    for (NSString *key in @[@"SunPadControlOrigins", @"SunPadControlSizeScales",
                            @"SunPadExperimentalDPadOrigin", @"SunPadExperimentalDPadScale"])
        [report appendFormat:@"%@=%@\n", key,
            [NSUserDefaults.standardUserDefaults objectForKey:key] ?: @"default"];
    [report appendString:@"\n[BallPad Adapter Log]\n"];
    [report appendString:BallpadRedacted(BallpadTailOfFile(BallpadLogPath(), BallpadReportTailBytes))];
    [report appendString:@"\n[Vendored Interface Log]\n"];
    [report appendString:BallpadRedacted(BallpadTailOfFile(SunPadDiagnosticsLogPath(), BallpadReportTailBytes))];

    NSString *directory = [BallpadDocumentsDirectory()
        stringByAppendingPathComponent:@"Diagnostics"];
    if (![fileManager createDirectoryAtPath:directory
            withIntermediateDirectories:YES
                             attributes:nil
                                  error:error])
        return nil;
    NSString *path = [directory stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"Ballpad-Diagnostic-%@.log", reportID]];
    if (![report writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:error])
        return nil;
    return [NSURL fileURLWithPath:path];
}

NSString *const BallpadFrameLimitUnlimitedKey = @"BallpadUnlimitedFrameRate";
NSString *const BallpadHideMenuButtonKey = @"BallpadHideMenuButton";

void BallpadLogSettingsSnapshot(NSString *what)
{
    SunPadSettings *settings = [SunPadSettings sharedSettings];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;

    // Which keys the store actually holds, next to what each one currently resolves to. A setting
    // nobody has touched and a setting deliberately put back at its default are different facts in
    // a bug report, and only the keys' presence tells them apart -- every accessor above answers
    // the same way for both. The keys that gate a shipped row are named here so a report shows the
    // row's own choice rather than only the port's response to it.
    NSArray<NSString *> *keys = @[
        @"SunPadRenderScale", @"SunPadAspectRatioMode", @"SunPadShowFPSCounter",
        @"SunPadExperimental60FPS", @"SunPadExperimentalPerformanceMode",
        @"SunPadHideControlsOnController", @"SunPadModernCStickHorizontal",
        @"SunPadControlOpacity", @"SunPadControlSizeScale", @"SunPadControlSizeScales",
        @"SunPadEditingControlLayout", BallpadFrameLimitUnlimitedKey,
        BallpadHideMenuButtonKey,
    ];
    NSMutableArray<NSString *> *stored = [NSMutableArray array];
    for (NSString *key in keys)
        if ([defaults objectForKey:key] != nil)
            [stored addObject:key];

    BallpadLog(@"settings: %@ -- render scale %ld, aspect mode %ld, opacity %.2f, size %.2f, "
               @"hide-on-controller %d, modern-c-stick %d, fps counter %d, frame-row key %d, "
               @"layout editing %d, menu button hidden %d, stored [%@]",
               what,
               (long)settings.renderScale, (long)settings.aspectRatioMode,
               (double)settings.controlOpacity, (double)settings.controlSizeScale,
               settings.hideTouchControlsWhenControllerConnected ? 1 : 0,
               settings.modernCStickHorizontal ? 1 : 0,
               settings.showFPSCounter ? 1 : 0,
               [defaults objectForKey:BallpadFrameLimitUnlimitedKey] != nil ? 1 : 0,
               settings.editingControlLayout ? 1 : 0,
               [defaults boolForKey:BallpadHideMenuButtonKey] ? 1 : 0,
               stored.count > 0 ? [stored componentsJoinedByString:@","] : @"none");
}
