#import "../mobile/interface/BallpadImportFiles.h"
#include <stdio.h>
#include <stdlib.h>

static void Check(BOOL condition, const char* label) {
    printf("%s: %s\n", condition ? "PASS" : "FAIL", label);
    if (!condition) exit(1);
}
static NSURL* Fixture(NSURL* root, NSString* relative) {
    NSURL* file = [root URLByAppendingPathComponent:relative];
    [NSFileManager.defaultManager createDirectoryAtURL:file.URLByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:NULL];
    [@"synthetic fixture" writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    return file.URLByResolvingSymlinksInPath;
}
int main(void) { @autoreleasepool {
    NSURL* root = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]].URLByResolvingSymlinksInPath;
    NSURL* documents = [root URLByAppendingPathComponent:@"Documents"];
    NSURL* temporary = [root URLByAppendingPathComponent:@"tmp"];
    NSURL* store = [documents URLByAppendingPathComponent:@"BallpadGameData"];
    NSURL* manual = Fixture(documents, @"game.ISO");
    NSURL* nested = Fixture(documents, @"Manual/another.gcm");
    NSURL* prefix = Fixture(documents, @"BallpadGameData-backup/backup.iso");
    NSURL* inbox = Fixture(documents, @"Inbox/game.iso");
    NSURL* active = Fixture(documents, @"BallpadGameData/import-active/game.iso");
    NSURL* temporaryCopy = Fixture(temporary, @"com.ballpad.strikers-Inbox/game.iso");
    NSURL* external = Fixture(root, @"External/source.iso");
    NSURL* link = [documents URLByAppendingPathComponent:@"alias.iso"];
    [NSFileManager.defaultManager createSymbolicLinkAtURL:link withDestinationURL:external error:NULL];
    NSArray* images = BallpadImportImagesInDocuments(documents, store);
    Check(images.count == 3 && [[NSSet setWithArray:[images valueForKey:@"lastPathComponent"]] isEqual:[NSSet setWithArray:@[@"game.ISO", @"another.gcm", @"backup.iso"]]],
          "Folder scan includes only manually supplied images, including same-prefix folders");
    Check(![images containsObject:inbox] && ![images containsObject:active] && ![images containsObject:link],
          "Picker Inbox, active installation, and symbolic links stay out of fallback");
    BallpadRemovePickerCopy(inbox, documents, temporary, @"com.ballpad.strikers");
    BallpadRemovePickerCopy(temporaryCopy, documents, temporary, @"com.ballpad.strikers");
    Check(![NSFileManager.defaultManager fileExistsAtPath:inbox.path] &&
          ![NSFileManager.defaultManager fileExistsAtPath:temporaryCopy.path], "Both UIKit-owned copy locations are cleaned");
    for (NSURL* url in @[manual, nested, prefix, active, external, link])
        BallpadRemovePickerCopy(url, documents, temporary, @"com.ballpad.strikers");
    Check([NSFileManager.defaultManager fileExistsAtPath:manual.path] &&
          [NSFileManager.defaultManager fileExistsAtPath:nested.path] &&
          [NSFileManager.defaultManager fileExistsAtPath:prefix.path] &&
          [NSFileManager.defaultManager fileExistsAtPath:active.path] &&
          [NSFileManager.defaultManager fileExistsAtPath:external.path], "Cleanup preserves originals and active game data");
    NSURL* linkedInbox = [documents URLByAppendingPathComponent:@"Inbox/link.iso"];
    [NSFileManager.defaultManager createSymbolicLinkAtURL:linkedInbox withDestinationURL:external error:NULL];
    BallpadRemovePickerCopy(linkedInbox, documents, temporary, @"com.ballpad.strikers");
    Check([NSFileManager.defaultManager fileExistsAtPath:external.path], "Inbox symlink cannot delete external source");
    NSURL* fakeInbox = Fixture(documents, @"Inbox-backup/game.iso");
    BallpadRemovePickerCopy(fakeInbox, documents, temporary, @"com.ballpad.strikers");
    Check([NSFileManager.defaultManager fileExistsAtPath:fakeInbox.path], "Cleanup requires exact Inbox parent");
    NSURL* otherInbox = Fixture(temporary, @"other-app-Inbox/game.iso");
    BallpadRemovePickerCopy(otherInbox, documents, temporary, @"com.ballpad.strikers");
    Check([NSFileManager.defaultManager fileExistsAtPath:otherInbox.path], "Cleanup requires this app's temporary Inbox");
    [NSFileManager.defaultManager removeItemAtURL:[documents URLByAppendingPathComponent:@"Inbox"] error:NULL];
    [NSFileManager.defaultManager createSymbolicLinkAtURL:[documents URLByAppendingPathComponent:@"Inbox"]
        withDestinationURL:external.URLByDeletingLastPathComponent error:NULL];
    BallpadRemovePickerCopy([documents URLByAppendingPathComponent:@"Inbox/source.iso"], documents, temporary, @"com.ballpad.strikers");
    Check([NSFileManager.defaultManager fileExistsAtPath:external.path], "A symlinked Inbox cannot authorize source deletion");
    [NSFileManager.defaultManager removeItemAtURL:root error:NULL];
    return 0;
} }
