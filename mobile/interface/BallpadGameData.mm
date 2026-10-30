// Ballpad's game-data store and importer.
//
// Two doors reach this file and they reach the same place. The port calls the two hooks in
// port/hostui.h: PortHostUIGameDataPath from its disc search, which runs from a static
// initialiser before any host framework exists, and PortHostUIRunGameDataImport from its entry
// point once that search has found nothing. The overlay's Game Data rows call the
// BallpadGameData* functions declared in the header beside this file. All of them share one store
// and one validation, so "imported" cannot mean two different things depending on how the player
// got there.
//
// The store is <container>/Documents/BallpadGameData/: a 'current' file naming the active data,
// and the staged copy beside it under import-<uuid>/<name>. Activation is the write of 'current'
// and nothing else, which is what leaves a previous installation usable when a new image is
// refused. Whether data is usable is decided by the port's own reader (port/disc.h) rather than by
// a second parser, so "valid" means exactly "the engine can open this", and a refusal shows the
// engine's own words.
//
// See docs/36-native-strikers-progress.md, "N5 - Ballpad's Files importer, design of record", for
// why the seam is split between the static initialiser and the entry point.

#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>

#include "port/disc.h"
#include "port/hostui.h"

#include "BallpadGameData.h"
#include "BallpadImportFiles.h"
#include "BallpadLog.h"
#include "SunPadDiagnostics.h"

// The one file that is on every copy of this disc and on nothing else a person is likely to point
// the importer at. dvd.c uses the same name for the same reason; it is repeated here rather than
// shared because the port's copy is a private define in a .c file.
#define BALLPAD_DVD_SENTINEL "common.ini"

// Long enough for a container path, the store name and a staged file name together.
#define BALLPAD_PATH_MAX 1200

// MARK: - The store, in plain C
//
// None of this section touches a framework, and that is a requirement rather than a style.
// PortHostUIGameDataPath is called from the port's disc search, which is a static initialiser: on
// iOS that is before UIApplicationMain, so a Foundation or UIKit call here would be a call into a
// framework that does not exist yet. getenv, fopen and stat do work, because libSystem is up; that
// is the whole reason the activation record is a plain file and not a defaults entry.

// The store's directory. Not created here: PortHostUIGameDataPath must be able to answer "no" from
// a static initialiser without writing anything, and the first import is what creates it.
static int BallpadStoreDir(char* out, size_t size)
{
    const char* home = getenv("HOME");
    if (home == NULL || home[0] == 0)
        return 0;
    int n = snprintf(out, size, "%s/Documents/BallpadGameData", home);
    return n > 0 && (size_t)n < size;
}

// The activation record: the one file whose contents decide what this app will play.
static int BallpadCurrentFile(char* out, size_t size)
{
    char dir[BALLPAD_PATH_MAX];
    if (!BallpadStoreDir(dir, sizeof dir))
        return 0;
    int n = snprintf(out, size, "%s/current", dir);
    return n > 0 && (size_t)n < size;
}

// The recorded path, or zero when there is no record. A record naming something that has since
// been deleted still reads as a record; whether the file is there is the caller's question.
static int BallpadReadCurrent(char* out, size_t size)
{
    char file[BALLPAD_PATH_MAX];
    if (!BallpadCurrentFile(file, sizeof file))
        return 0;

    FILE* f = fopen(file, "r");
    if (f == NULL)
        return 0;
    if (fgets(out, (int)size, f) == NULL)
    {
        fclose(f);
        return 0;
    }
    fclose(f);

    // One path on one line. Trailing whitespace is trimmed rather than trusted, because this file
    // is reachable from a desktop via iTunes-style file sharing and an editor will happily leave
    // an innocent carriage return in it.
    size_t len = strlen(out);
    while (len > 0)
    {
        char c = out[len - 1];
        if (c != '\n' && c != '\r' && c != ' ' && c != '\t')
            break;
        out[--len] = 0;
    }
    if (len == 0)
        return 0;

    // iOS may relocate a preserved data container during an in-place update.
    // New records are relative to HOME; rebase legacy app-container records too.
    const char* relative = strncmp(out, "Documents/", 10) == 0 ? out : NULL;
    if (relative == NULL && strstr(out, "/Containers/Data/Application/") != NULL)
    {
        const char* documents = strstr(out, "/Documents/");
        if (documents != NULL)
            relative = documents + 1;
    }
    if (relative != NULL)
    {
        const char* home = getenv("HOME");
        if (home == NULL || strstr(relative, "/../") != NULL)
            return 0;
        char resolved[BALLPAD_PATH_MAX];
        int n = snprintf(resolved, sizeof resolved, "%s/%s", home, relative);
        if (n <= 0 || (size_t)n >= sizeof resolved || (size_t)n >= size)
            return 0;
        memcpy(out, resolved, (size_t)n + 1);
    }
    return 1;
}

extern "C" int BallpadGameDataStaged(void)
{
    char path[BALLPAD_PATH_MAX];
    struct stat st;
    if (!BallpadReadCurrent(path, sizeof path))
        return 0;
    return stat(path, &st) == 0;
}

extern "C" const char* BallpadGameDataStorePath(void)
{
    static char s_dir[BALLPAD_PATH_MAX];
    if (s_dir[0] == 0 && !BallpadStoreDir(s_dir, sizeof s_dir))
        snprintf(s_dir, sizeof s_dir, "Documents/BallpadGameData");
    return s_dir;
}

// The file's own name, for a log line or an alert, rather than the staging directory's uuid.
static const char* BallpadBaseName(const char* path)
{
    const char* slash = strrchr(path, '/');
    return slash != NULL ? slash + 1 : path;
}

extern "C" const char* BallpadGameDataSummary(void)
{
    static char s_summary[BALLPAD_PATH_MAX + 64];
    char path[BALLPAD_PATH_MAX];
    struct stat st;

    if (!BallpadReadCurrent(path, sizeof path))
    {
        snprintf(s_summary, sizeof s_summary, "no game data");
        return s_summary;
    }
    if (stat(path, &st) != 0)
    {
        snprintf(s_summary, sizeof s_summary,
                 "no game data (the recorded file is gone: %s)",
                 BallpadBaseName(path));
        return s_summary;
    }
    if (S_ISDIR(st.st_mode))
        snprintf(s_summary, sizeof s_summary, "%s (folder)", BallpadBaseName(path));
    else
        snprintf(s_summary, sizeof s_summary, "%s (%.1f MB)", BallpadBaseName(path),
                 (double)st.st_size / (1024.0 * 1024.0));
    return s_summary;
}

// The port's half of the pair. Returning the recorded path only while it still exists is what
// makes a removal take effect on the next launch instead of being undone by a stale record: the
// port sees nothing to search, falls back to its own locations, and then asks for an import again.
extern "C" const char* PortHostUIGameDataPath(void)
{
    static char s_path[BALLPAD_PATH_MAX];
    char path[BALLPAD_PATH_MAX];
    struct stat st;

    if (!BallpadReadCurrent(path, sizeof path))
        return NULL;
    if (stat(path, &st) != 0)
        return NULL;
    if (strcmp(path, s_path) != 0)
        snprintf(s_path, sizeof s_path, "%s", path);
    return s_path;
}

// MARK: - Validation, through the port's own reader
//
// A second parser here would be a second opinion about what a disc is, and the two would disagree
// the first time the port learned a format this did not. Walking the port's reader is also what
// makes the refusal text the engine's own, which is the text the desktop box would have shown.

struct BallpadWalkResult
{
    int files;
    int sentinel;
};

static int BallpadWalkVisit(void* user, const char* path, unsigned offset, unsigned length,
                            int isDir)
{
    (void)offset;
    (void)length;
    struct BallpadWalkResult* result = (struct BallpadWalkResult*)user;
    if (isDir)
        return 0;
    result->files++;
    if (strcasecmp(path, BALLPAD_DVD_SENTINEL) == 0)
        result->sentinel = 1;
    return 0;
}

// Nonzero when the port could play this. On refusal, 'reason' holds a finished, user-facing
// explanation built from the same facts dvd.c refuses on.
static int BallpadValidateDiscImage(const char* path, char* reason, size_t size)
{
    char err[1024];
    err[0] = 0;

    PortDisc* disc = port_disc_open(path, err, sizeof err);
    if (disc == NULL)
    {
        snprintf(reason, size, "%s",
                 err[0] != 0 ? err
                             : "That file is not a disc image this build can read.");
        return 0;
    }

    // The disc header. port_disc_open has already refused anything shorter than this, so a short
    // read here means the image changed under us rather than that it is a strange disc.
    unsigned char header[0x20];
    if (port_disc_read(disc, header, sizeof header, 0) != (long)sizeof header)
    {
        port_disc_close(disc);
        snprintf(reason, size,
                 "That disc image is too short to hold a disc header. "
                 "It is probably truncated.");
        return 0;
    }

    struct BallpadWalkResult result = { 0, 0 };
    if (port_disc_walk(disc, BallpadWalkVisit, &result, err, sizeof err) != 0)
    {
        port_disc_close(disc);
        snprintf(reason, size, "%s",
                 err[0] != 0 ? err
                             : "That disc image's file table could not be read.");
        return 0;
    }
    port_disc_close(disc);

    if (result.files == 0)
    {
        snprintf(reason, size,
                 "That disc image has no files in it, so it is not Super Mario "
                 "Strikers.\n\nFound 0 files, and no '%s', which is on every copy "
                 "of this game.",
                 BALLPAD_DVD_SENTINEL);
        return 0;
    }

    if (!result.sentinel)
    {
        snprintf(reason, size,
                 "That disc image is not the Super Mario Strikers disc.\n\n"
                 "Found %d files, but no '%s', which is on every copy of this "
                 "game. It is a readable disc image of some other game.",
                 result.files, BALLPAD_DVD_SENTINEL);
        return 0;
    }

    // This game's files, but not this game's disc. The same three codes dvd.c prints, because a
    // player who has one of the other two regions should be told that it would work.
    if (memcmp(header, "G4Q", 3) != 0)
    {
        char found[7];
        memcpy(found, header, 6);
        found[6] = 0;
        snprintf(reason, size,
                 "The disc header %s is not Super Mario Strikers.\n\n"
                 "Every release of this game has a code beginning G4Q "
                 "(G4QE01 USA, G4QP01 Europe, G4QJ01 Japan) and this port runs "
                 "any of them. A 'files' folder from one game beside another "
                 "game's 'sys' is the usual cause.",
                 found);
        return 0;
    }

    return 1;
}

// Activation is this rename and nothing else. Everything before it can fail and leave the store
// exactly as it was, which is what makes "the previous installation still works" a property rather
// than a promise.
static int BallpadActivate(const char* stagedPath)
{
    char current[BALLPAD_PATH_MAX];
    char temporary[BALLPAD_PATH_MAX];
    if (!BallpadCurrentFile(current, sizeof current))
        return 0;

    int n = snprintf(temporary, sizeof temporary, "%s.tmp", current);
    if (n <= 0 || (size_t)n >= sizeof temporary)
        return 0;

    FILE* f = fopen(temporary, "w");
    if (f == NULL)
        return 0;
    const char* record = stagedPath;
    const char* home = getenv("HOME");
    if (home != NULL && strncmp(stagedPath, home, strlen(home)) == 0
        && strncmp(stagedPath + strlen(home), "/Documents/", 11) == 0)
        record = stagedPath + strlen(home) + 1;
    int wrote = fprintf(f, "%s\n", record) > 0;
    if (fclose(f) != 0)
        wrote = 0;
    if (!wrote)
    {
        remove(temporary);
        return 0;
    }

    // A rename within one directory: the record is either the old path or the new one, never half
    // of either, so a host killed at this instant still has an installation it can play.
    if (rename(temporary, current) != 0)
    {
        remove(temporary);
        return 0;
    }
    return 1;
}

// MARK: - Objective-C helpers

static NSString* BallpadStringFromC(const char* text)
{
    if (text == NULL || text[0] == 0)
        return @"";
    NSString* string = [NSString stringWithUTF8String:text];
    return string != nil ? string : @"";
}

static NSString* BallpadStoreDirString(void)
{
    NSString* store = BallpadStringFromC(BallpadGameDataStorePath());
    NSError* error = nil;
    [NSFileManager.defaultManager createDirectoryAtPath:store
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:&error];
    if (error != nil)
        SunPadLog(@"game data: could not create the store at %@: %@", store,
                  error.localizedDescription);
    return store;
}

// The previous installation goes only after the new one is recorded. Nothing here runs before
// BallpadActivate has returned nonzero, so a refusal cannot take away the disc that still works.
static void BallpadPruneInactiveCopies(NSString* activePath)
{
    NSFileManager* fileManager = NSFileManager.defaultManager;
    NSString* store = BallpadStoreDirString();
    NSString* activeDir = activePath.stringByDeletingLastPathComponent;
    NSArray<NSString*>* names =
        [fileManager contentsOfDirectoryAtPath:store error:NULL] ?: @[];

    for (NSString* name in names)
    {
        if (![name hasPrefix:@"import-"])
            continue;
        NSString* candidate = [store stringByAppendingPathComponent:name];
        if ([candidate isEqualToString:activeDir])
            continue;
        if ([fileManager removeItemAtPath:candidate error:NULL])
            SunPadLog(@"game data: pruned the replaced installation %@", name);
    }
}

static void BallpadPresentAlert(UIViewController* presenter, NSString* title, NSString* message,
                                NSString* actionTitle, void (^handler)(void))
{
    UIAlertController* alert =
        [UIAlertController alertControllerWithTitle:title
                                           message:message
                                    preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:actionTitle
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction* action) {
        (void)action;
        if (handler != nil)
            handler();
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

// Copy, validate, activate, prune. Every failure path removes the staging directory it created and
// returns NO, so the caller can only ever be looking at a store that either did not change or
// gained a working installation.
static BOOL BallpadStageAndActivate(NSURL* source, NSString** refusal)
{
    NSFileManager* fileManager = NSFileManager.defaultManager;
    NSString* store = BallpadStoreDirString();

    NSString* name = source.lastPathComponent;
    if (name.length == 0)
    {
        if (refusal != NULL)
            *refusal = @"That file has no name to stage under.";
        return NO;
    }

    NSString* stagingDir = [store stringByAppendingPathComponent:
        [NSString stringWithFormat:@"import-%@", NSUUID.UUID.UUIDString]];
    NSString* staged = [stagingDir stringByAppendingPathComponent:name];

    // The picker hands out a URL outside this app's container, so the copy has to happen inside a
    // security-scoped access or the first read of it fails. The copy is also why the original image
    // is never touched: everything after this point reads Ballpad's own file.
    BOOL scoped = [source startAccessingSecurityScopedResource];
    NSError* error = nil;
    BOOL copied = [fileManager createDirectoryAtPath:stagingDir
                         withIntermediateDirectories:YES
                                          attributes:nil
                                               error:&error] &&
        [fileManager copyItemAtURL:source toURL:[NSURL fileURLWithPath:staged] error:&error];
    if (scoped)
        [source stopAccessingSecurityScopedResource];

    if (!copied)
    {
        [fileManager removeItemAtPath:stagingDir error:NULL];
        SunPadLog(@"game data: could not copy %@ into the store: %@", name,
                  error.localizedDescription);
        if (refusal != NULL)
            *refusal = [NSString stringWithFormat:
                @"That file could not be copied into BallPad's own folder:\n\n%@\n\nThe disc "
                "image itself was not changed.",
                error.localizedDescription ?: @"unknown error"];
        return NO;
    }

    char reason[2048];
    reason[0] = 0;
    if (!BallpadValidateDiscImage(staged.fileSystemRepresentation, reason, sizeof reason))
    {
        [fileManager removeItemAtPath:stagingDir error:NULL];
        SunPadLog(@"game data: %@ was refused by the port's own reader", name);
        if (refusal != NULL)
            *refusal = BallpadStringFromC(reason);
        return NO;
    }

    if (!BallpadActivate(staged.fileSystemRepresentation))
    {
        [fileManager removeItemAtPath:stagingDir error:NULL];
        SunPadLog(@"game data: could not record the import; the store is unchanged");
        if (refusal != NULL)
            *refusal = @"BallPad could not record the import in its own folder, so nothing "
                       "changed. The disc that already works is still in place.";
        return NO;
    }

    SunPadLog(@"game data: staged and activated %@ (%@)", name,
              BallpadStringFromC(BallpadGameDataSummary()));
    BallpadPruneInactiveCopies(staged);
    return YES;
}

// Staging off the main thread and reporting on it: the copy is a few hundred megabytes for an
// image and the validation reads the whole file table, so neither belongs on the thread the game
// frame is being drawn on.
static void BallpadStagePickedURL(NSURL* url, BOOL pickerCopy, void (^report)(NSURL*, NSString*))
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool
        {
            NSString* refusal = nil;
            BOOL staged = BallpadStageAndActivate(url, &refusal);
            if (pickerCopy)
            {
                NSURL* documents = [NSFileManager.defaultManager URLForDirectory:NSDocumentDirectory
                    inDomain:NSUserDomainMask appropriateForURL:nil create:NO error:NULL];
                BallpadRemovePickerCopy(url, documents, [NSURL fileURLWithPath:NSTemporaryDirectory()], NSBundle.mainBundle.bundleIdentifier);
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                report(staged ? url : nil, staged ? nil : refusal);
            });
        }
    });
}

// MARK: - The document picker

@interface BallpadGameDataImportViewController : UIViewController
@property(nonatomic, copy) NSString* heading;
@property(nonatomic, copy) NSString* message;
@property(nonatomic, copy) NSString* detail;
@property(nonatomic, copy) void (^onChooseFiles)(void);
@property(nonatomic, copy) void (^onChooseFolder)(void);
@property(nonatomic, copy) void (^onCancel)(void);
- (instancetype)initWithHeading:(NSString*)heading
                        message:(NSString*)message
                         detail:(NSString*)detail;
- (void)setRefusal:(NSString*)refusal busy:(BOOL)busy;
@end

// SunPad's overlay is above the render surface when the game is running; this is the other half of
// the same interface, for the launch where there is no game behind it yet. The identifiers are the
// ones the Simulator acceptance runs address it by.
@implementation BallpadGameDataImportViewController
{
    UILabel* _refusalLabel;
    UILabel* _detailLabel;
    UIStackView* _busyRow;
    UIActivityIndicatorView* _busySpinner;
    UIButton* _chooseButton;
    UIButton* _folderButton;
    UIButton* _cancelButton;
}

- (instancetype)initWithHeading:(NSString*)heading
                        message:(NSString*)message
                         detail:(NSString*)detail
{
    self = [super initWithNibName:nil bundle:nil];
    if (self == nil)
        return nil;
    _heading = [heading copy];
    _message = [message copy];
    _detail = [detail copy];
    return self;
}

static UILabel* BallpadTextLabel(NSString* text, UIFont* font, UIColor* color,
                                 NSString* identifier)
{
    UILabel* label = [UILabel new];
    label.text = text;
    label.font = font;
    label.textColor = color;
    label.numberOfLines = 0;
    label.accessibilityIdentifier = identifier;
    return label;
}

static UIButton* BallpadFilledButton(NSString* title, NSString* identifier, id target, SEL action)
{
    UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.accessibilityIdentifier = identifier;
    button.titleLabel.font = [UIFont boldSystemFontOfSize:17.0];
    button.backgroundColor = UIColor.systemBlueColor;
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.layer.cornerRadius = 12.0;
    [button.heightAnchor constraintEqualToConstant:48.0].active = YES;
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

static UIButton* BallpadPlainButton(NSString* title, NSString* identifier, id target, SEL action)
{
    UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.accessibilityIdentifier = identifier;
    button.titleLabel.font = [UIFont systemFontOfSize:17.0];
    [button.heightAnchor constraintEqualToConstant:44.0].active = YES;
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.view.accessibilityIdentifier = @"BallpadGameDataImport";

    UILabel* title = BallpadTextLabel(self.heading, [UIFont boldSystemFontOfSize:28.0],
                                      UIColor.labelColor, @"BallpadGameDataImportTitle");
    title.textAlignment = NSTextAlignmentCenter;

    // BallPad's own words, centred: what this screen is for and the one thing the player has to do.
    // A label rather than a text view, because this copy is chosen here -- nothing in it is a path to
    // select or a link, and a text view drew the port's developer-facing explanation as a wall of
    // selectable blue-ish prose that read like a crash log.
    UILabel* body = BallpadTextLabel(self.message,
                                     [UIFont preferredFontForTextStyle:UIFontTextStyleBody],
                                     UIColor.secondaryLabelColor, @"BallpadGameDataImportBody");
    body.textAlignment = NSTextAlignmentCenter;
    body.adjustsFontForContentSizeCategory = YES;

    // The port's own explanation, in full and quiet. It names the locations the disc search tried,
    // which is the only thing on this screen that answers "but I know I stored it there", and it is
    // written for a desktop developer, so it is set like a footnote under the copy rather than
    // standing in front of it.
    _detailLabel = BallpadTextLabel(self.detail, [UIFont systemFontOfSize:13.0],
                                    UIColor.tertiaryLabelColor, @"BallpadGameDataImportDetail");
    _detailLabel.textAlignment = NSTextAlignmentNatural;
    _detailLabel.hidden = self.detail.length == 0;

    // A refusal is a different thing: it is the reason the button the player just pressed did
    // nothing, so it is loud and it sits with the buttons.
    _refusalLabel = BallpadTextLabel(nil, [UIFont boldSystemFontOfSize:15.0],
                                     UIColor.systemOrangeColor,
                                     @"BallpadGameDataImportRefusal");
    _refusalLabel.hidden = YES;

    // Validation reads a disc image, which is a second or two of a screen with every button greyed
    // out and nothing saying why. This is that reason, in the row the refusal uses when it has one.
    _busySpinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _busySpinner.color = UIColor.secondaryLabelColor;
    _busyRow = [[UIStackView alloc] initWithArrangedSubviews:@[
        _busySpinner,
        BallpadTextLabel(@"Checking the disc image...", [UIFont systemFontOfSize:15.0],
                         UIColor.secondaryLabelColor, @"BallpadGameDataImportBusy"),
    ]];
    _busyRow.axis = UILayoutConstraintAxisHorizontal;
    _busyRow.spacing = 8.0;
    _busyRow.alignment = UIStackViewAlignmentCenter;
    _busyRow.hidden = YES;

    _chooseButton = BallpadFilledButton(@"Choose ISO or GCM", @"BallpadGameDataImportChoose", self,
                                        @selector(chooseFilesTapped));
    _folderButton = BallpadPlainButton(@"Import from BallPad Folder",
                                       @"BallpadGameDataImportFolder", self,
                                       @selector(chooseFolderTapped));
    _cancelButton = BallpadPlainButton(@"Not now", @"BallpadGameDataImportCancel", self,
                                       @selector(cancelTapped));

    // The text scrolls -- the copy above and the port's explanation under it -- and the actions do
    // not. A first-run screen whose only button is below the fold looks like an app with no way
    // forward, and that is what the phone showed when the text and the buttons shared one scrolling
    // stack: the explanation alone is taller than the landscape safe area. Pinning the actions is
    // what makes them visible without a scroll on both form factors.
    UIStackView* text = [[UIStackView alloc] initWithArrangedSubviews:@[ title, body, _detailLabel ]];
    text.axis = UILayoutConstraintAxisVertical;
    text.spacing = 16.0;
    text.translatesAutoresizingMaskIntoConstraints = NO;

    // The refusal and the busy row sit with the buttons rather than at the end of the scrolling
    // text, because both are answers to the button the player just pressed.
    UIStackView* actions = [[UIStackView alloc] initWithArrangedSubviews:@[
        _refusalLabel, _busyRow, _chooseButton, _folderButton, _cancelButton
    ]];
    actions.axis = UILayoutConstraintAxisVertical;
    actions.spacing = 12.0;
    actions.translatesAutoresizingMaskIntoConstraints = NO;

    UIScrollView* scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    [scroll addSubview:text];
    [self.view addSubview:scroll];
    [self.view addSubview:actions];

    UILayoutGuide* safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:actions.topAnchor constant:-16.0],
        [text.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24.0],
        [text.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor
                                         constant:-24.0],
        [text.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor
                                           constant:24.0],
        [text.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor
                                            constant:-24.0],
        [text.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor
                                         constant:-48.0],
        [actions.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24.0],
        [actions.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24.0],
        [actions.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-16.0],
    ]];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    // A screen that appears without a sound is a screen VoiceOver may not have noticed, and there
    // is no game behind this one to read anything back.
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, _chooseButton);
}

- (void)setRefusal:(NSString*)refusal busy:(BOOL)busy
{
    _refusalLabel.text = refusal;
    _refusalLabel.hidden = busy || refusal.length == 0;
    _busyRow.hidden = !busy;
    if (busy)
        [_busySpinner startAnimating];
    else
        [_busySpinner stopAnimating];
    _chooseButton.enabled = !busy;
    _folderButton.enabled = !busy;
    _cancelButton.enabled = !busy;
}

- (void)chooseFilesTapped
{
    if (self.onChooseFiles != nil)
        self.onChooseFiles();
}

- (void)chooseFolderTapped
{
    if (self.onChooseFolder != nil)
        self.onChooseFolder();
}

- (void)cancelTapped
{
    if (self.onCancel != nil)
        self.onCancel();
}

@end

@interface BallpadGameDataImporter : NSObject <UIDocumentPickerDelegate>
- (void)presentFrom:(UIViewController*)presenter
         completion:(void (^)(NSURL*, NSString*))completion;
@end

// One picker at a time. The launch path and the menu path both come through here, and two live
// importers would mean two delegates for one dismissal.
static BallpadGameDataImporter* s_importer = nil;

@implementation BallpadGameDataImporter
{
    void (^_completion)(NSURL*, NSString*);
}

- (void)presentFrom:(UIViewController*)presenter
         completion:(void (^)(NSURL*, NSString*))completion
{
    if (s_importer != nil)
    {
        // Already asking. Answering "nothing happened" is honest and leaves the live picker alone.
        if (completion != nil)
            completion(nil, nil);
        return;
    }
    s_importer = self;
    _completion = [completion copy];

    // .iso and .gcm are what the port reads uncompressed; the fallback to plain data is for a file
    // the system cannot type from its extension, which the validation then judges. asCopy gives a
    // copy inside this app's container to work from, which is also what keeps the player's
    // original untouched.
    NSMutableArray<UTType*>* types = [NSMutableArray array];
    UTType* iso = [UTType typeWithFilenameExtension:@"iso"];
    UTType* gcm = [UTType typeWithFilenameExtension:@"gcm"];
    if (iso != nil)
        [types addObject:iso];
    if (gcm != nil)
        [types addObject:gcm];

    NSArray<UTType*>* offered = types.count > 0 ? types : @[ UTTypeData ];
    UIDocumentPickerViewController* picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:offered asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    picker.shouldShowFileExtensions = YES;
    SunPadLog(@"game data: presenting the Files picker");
    [presenter presentViewController:picker animated:YES completion:nil];
}

- (void)finishWithURL:(NSURL*)url refusal:(NSString*)refusal
{
    void (^completion)(NSURL*, NSString*) = _completion;
    _completion = nil;
    if (s_importer == self)
        s_importer = nil;
    if (completion != nil)
        completion(url, refusal);
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController*)controller
{
    (void)controller;
    [self finishWithURL:nil refusal:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController*)controller
    didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls
{
    [controller dismissViewControllerAnimated:YES completion:nil];
    NSURL* url = urls.firstObject;
    if (url == nil)
    {
        [self finishWithURL:nil refusal:nil];
        return;
    }
    SunPadLog(@"game data: the player chose %@", url.lastPathComponent);
    [self finishWithURL:url refusal:nil];
}

@end

// MARK: - Finding something to present from

static UIWindowScene* BallpadFirstWindowScene(void)
{
    for (UIScene* scene in UIApplication.sharedApplication.connectedScenes)
    {
        if ([scene isKindOfClass:UIWindowScene.class])
            return (UIWindowScene*)scene;
    }
    return nil;
}

static UIViewController* BallpadPresentingViewController(void)
{
    UIWindowScene* scene = BallpadFirstWindowScene();
    if (scene == nil)
        return nil;
    for (UIWindow* window in scene.windows)
    {
        if (window.isKeyWindow && window.rootViewController != nil)
            return window.rootViewController;
    }
    for (UIWindow* window in scene.windows)
    {
        if (window.rootViewController != nil)
            return window.rootViewController;
    }
    return nil;
}

// The folder route: images the player put in this app's own Documents folder through Files rather
// than picking out of Browse. The store is skipped, or the staged copies of past imports would
// list themselves as candidates.
static NSArray<NSURL*>* BallpadImagesInDocuments(void)
{
    NSURL* documents = [NSFileManager.defaultManager URLForDirectory:NSDocumentDirectory
        inDomain:NSUserDomainMask appropriateForURL:nil create:NO error:NULL];
    return BallpadImportImagesInDocuments(documents,
        [NSURL fileURLWithPath:BallpadStringFromC(BallpadGameDataStorePath())]);
}

static void BallpadRunFolderImport(UIViewController* presenter,
                                   void (^completion)(NSURL*, NSString*))
{
    NSArray<NSURL*>* images = BallpadImagesInDocuments();
    if (images.count == 0)
    {
        BallpadPresentAlert(presenter, @"No Disc Image in the BallPad Folder",
                            [NSString stringWithFormat:
                                @"Put an .iso or .gcm disc image into this app's folder in Files -- "
                                "On My iPhone (or iPad), %@ -- and try again. Nothing was changed.",
                                BallpadAppDisplayName()],
                            @"OK", nil);
        completion(nil, nil);
        return;
    }
    if (images.count == 1)
    {
        BallpadStagePickedURL(images.firstObject, NO, completion);
        return;
    }

    UIAlertController* choice =
        [UIAlertController alertControllerWithTitle:@"Choose a Disc Image"
                                           message:@"More than one disc image is in the "
                                                   @"BallPad folder."
                                    preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSURL* image in images)
    {
        [choice addAction:[UIAlertAction actionWithTitle:image.lastPathComponent
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction* action) {
            (void)action;
            BallpadStagePickedURL(image, NO, completion);
        }]];
    }
    [choice addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction* action) {
        (void)action;
        completion(nil, nil);
    }]];
    // An action sheet on an iPad needs somewhere to point at, or presenting it throws.
    choice.popoverPresentationController.sourceView = presenter.view;
    choice.popoverPresentationController.sourceRect = presenter.view.bounds;
    [presenter presentViewController:choice animated:YES completion:nil];
}

static void BallpadGameDataRunImport(UIViewController* presenter,
                                     void (^apply)(NSURL*, NSString*))
{
    BallpadGameDataImporter* importer = [BallpadGameDataImporter new];
    [importer presentFrom:presenter
               completion:^(NSURL* url, NSString* refusal) {
        if (url == nil)
        {
            apply(nil, refusal);
            return;
        }
        BallpadStagePickedURL(url, YES, apply);
    }];
}

// What the menu's rows say afterwards. The game is running on a disc it already resolved, so a
// successful import here is for the next launch and the alert has to say so rather than imply the
// running match changed.
static void BallpadReportMenuImport(UIViewController* presenter, NSURL* url, NSString* refusal)
{
    if (url != nil)
    {
        BallpadPresentAlert(presenter, @"Game Data Imported",
                            [NSString stringWithFormat:
                                @"%@ is in place.\n\nThe game keeps running on the disc it already "
                                "loaded. Quit and open %@ again to play the new one.",
                                BallpadStringFromC(BallpadGameDataSummary()),
                                BallpadAppDisplayName()],
                            @"OK", nil);
        return;
    }
    if (refusal != nil)
    {
        BallpadPresentAlert(presenter, @"That Disc Cannot Be Used", refusal, @"OK", nil);
        return;
    }
    SunPadLog(@"game data: nothing imported; the store is unchanged");
}

// MARK: - Ballpad's side of the header

void BallpadGameDataPresentImport(void)
{
    @autoreleasepool
    {
        UIViewController* presenter = BallpadPresentingViewController();
        if (presenter == nil)
        {
            SunPadLog(@"game data: no view controller to present the picker from");
            return;
        }
        SunPadLog(@"game data: the menu asked to import or reimport; store is %@",
                  BallpadStringFromC(BallpadGameDataSummary()));
        BallpadGameDataRunImport(presenter, ^(NSURL* url, NSString* refusal) {
            BallpadReportMenuImport(presenter, url, refusal);
        });
    }
}

void BallpadGameDataPresentFolderImport(void)
{
    @autoreleasepool
    {
        UIViewController* presenter = BallpadPresentingViewController();
        if (presenter == nil)
        {
            SunPadLog(@"game data: no view controller to present the folder import from");
            return;
        }
        SunPadLog(@"game data: the menu asked for a folder import");
        BallpadRunFolderImport(presenter, ^(NSURL* url, NSString* refusal) {
            BallpadReportMenuImport(presenter, url, refusal);
        });
    }
}

// The overlay has already asked the player to confirm by the time this runs, so there is no second
// confirmation here. Removing every entry in the store is what makes the next launch ask for a disc
// again, because PortHostUIGameDataPath stops answering the moment the record points at nothing.
extern "C" int BallpadGameDataRemoveStoredData(void)
{
    int removed = 0;
    @autoreleasepool
    {
        NSFileManager* fileManager = NSFileManager.defaultManager;
        NSString* store = BallpadStoreDirString();
        NSArray<NSString*>* names =
            [fileManager contentsOfDirectoryAtPath:store error:NULL] ?: @[];

        for (NSString* name in names)
        {
            NSString* path = [store stringByAppendingPathComponent:name];
            if ([fileManager removeItemAtPath:path error:NULL])
                removed++;
            else
                SunPadLog(@"game data: could not remove %@", name);
        }
        SunPadLog(@"game data: removed %d item(s); %@", removed,
                  BallpadStringFromC(BallpadGameDataSummary()));
    }
    return removed;
}

// MARK: - The port's other hook

// The port calls this from its own main(), which on iOS runs inside the host's application
// delegate, so UIKit is up but the game's UIWindow is not: SDL creates it later in the same
// function, after this returns.
//
// That is why the screen gets a window of its own. The scene delegate's launch window is still on
// screen, one level above normal; a window at alert level is above it, so the explanation the port
// wanted to show cannot be hidden behind a launch screen that has nothing left to do.
//
// The loop at the bottom is what reconciles the two halves: the port asks a synchronous question
// from inside its main(), and a document picker answers through the run loop. Nothing else owns the
// run loop yet -- SDL's event pump has no window to pump for -- so pumping it here is what lets the
// call wait for the player without blocking the screen from being drawn or tapped.
extern "C" int PortHostUIRunGameDataImport(const char* title, const char* message)
{
    // Data is already in the store: this is a re-resolve after an import made from the menu, and
    // there is nothing to ask the player.
    if (BallpadGameDataStaged())
        return 1;

    int staged = 0;
    @autoreleasepool
    {
        UIWindowScene* scene = BallpadFirstWindowScene();
        if (scene == nil)
        {
            SunPadLog(@"game data: no window scene, so no importer to present");
            return 0;
        }

        NSString* portTitle = title != NULL && title[0] != 0
            ? BallpadStringFromC(title)
            : [NSString stringWithFormat:@"%@: game data not found", BallpadAppDisplayName()];
        NSString* portMessage = message != NULL && message[0] != 0
            ? BallpadStringFromC(message)
            : @"The game data was not found, and the disc has not been resolved yet.";

        // What the port says about a disc it could not find is written for a developer at a desktop:
        // it names every container path it tried -- on a Simulator, an absolute
        // /Users/.../CoreSimulator/Devices/<UDID>/... path -- and then tells the reader to set the
        // STRIKERS_DATA variable or the `data` key in strikers.ini. None of that is a thing a player
        // holding an iPad can do, and printing it under BallPad's own copy made the screen read like
        // a crash log with a button on it. So the screen says only what BallPad knows and what the
        // player can act on, and the port's own words go to the log instead, flattened to one line
        // so a multi-line message cannot be mistaken for a log record by anything reading the file.
        SunPadLog(@"game data: the port's own not-found text, kept for diagnosis and off the screen "
                   "-- %@ | %@",
                  [portTitle stringByReplacingOccurrencesOfString:@"\n" withString:@" | "],
                  [portMessage stringByReplacingOccurrencesOfString:@"\n" withString:@" | "]);

        NSString* heading = @"Add your game";
        NSString* body = [NSString stringWithFormat:
            @"%@ plays Super Mario Strikers from your own disc.\n\n"
            @"Choose your .iso or .gcm disc image, or copy that image into %@'s "
            @"folder in Files and import it. Nothing is bundled with this app, "
            @"and nothing is uploaded anywhere.",
            BallpadAppDisplayName(), BallpadAppDisplayName()];
        // The quiet line under the copy is the one fact a first-run screen can add that the player
        // does not already know: which disc BallPad will accept. It is BallPad's own sentence, so it
        // carries no host path and no instruction the platform cannot follow.
        NSString* detail = @"Supported: Super Mario Strikers USA, revision 0 (G4QE01).";

        BallpadGameDataImportViewController* screen =
            [[BallpadGameDataImportViewController alloc] initWithHeading:heading
                                                                 message:body
                                                                  detail:detail];

        UIWindow* window = [[UIWindow alloc] initWithWindowScene:scene];
        window.windowLevel = UIWindowLevelAlert;
        window.rootViewController = screen;
        [window makeKeyAndVisible];
        SunPadLog(@"game data: the port found no disc; presenting the importer (%@)",
                  BallpadStringFromC(BallpadGameDataSummary()));

        __block BOOL finished = NO;
        __block BOOL imported = NO;
        // The screen owns the blocks below and the blocks reach back into the screen, so one of the
        // two ends has to be weak. It is cleared after the loop as well; this is what keeps the
        // cycle from existing at all rather than depending on that line being reached.
        __weak BallpadGameDataImportViewController* weakScreen = screen;

        void (^applyResult)(NSURL*, NSString*) = ^(NSURL* url, NSString* refusal) {
            BallpadGameDataImportViewController* strongScreen = weakScreen;
            if (strongScreen == nil)
                return;
            if (url == nil && refusal == nil)
            {
                // Cancelled, or there was nothing to offer. The screen stays up so the port's own
                // explanation is still readable.
                [strongScreen setRefusal:nil busy:NO];
                return;
            }
            if (refusal != nil)
            {
                // Refused, and the store was not touched, so another file can be tried without
                // restarting the app.
                [strongScreen setRefusal:refusal busy:NO];
                return;
            }
            imported = YES;
            [strongScreen setRefusal:nil busy:NO];
            BallpadPresentAlert(strongScreen, @"Game Data Ready",
                                [NSString stringWithFormat:@"%@ is in place. %@ will start now.",
                                                           BallpadStringFromC(
                                                               BallpadGameDataSummary()),
                                                           BallpadAppDisplayName()],
                                @"Start the Game", ^{
                finished = YES;
            });
        };

        screen.onCancel = ^{
            finished = YES;
        };
        screen.onChooseFiles = ^{
            BallpadGameDataImportViewController* strongScreen = weakScreen;
            if (strongScreen == nil)
                return;
            [strongScreen setRefusal:nil busy:YES];
            BallpadGameDataRunImport(strongScreen, applyResult);
        };
        screen.onChooseFolder = ^{
            BallpadGameDataImportViewController* strongScreen = weakScreen;
            if (strongScreen == nil)
                return;
            [strongScreen setRefusal:nil busy:YES];
            BallpadRunFolderImport(strongScreen, applyResult);
        };

        while (!finished)
        {
            @autoreleasepool
            {
                [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                                       beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            }
        }

        screen.onChooseFiles = nil;
        screen.onChooseFolder = nil;
        screen.onCancel = nil;
        window.hidden = YES;
        window.rootViewController = nil;
        staged = imported ? 1 : 0;
    }

    SunPadLog(@"game data: importer finished with %@; the port will resolve again",
              staged ? @"a staged disc" : @"nothing staged");
    return staged;
}
