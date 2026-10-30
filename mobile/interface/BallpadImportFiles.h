#pragma once
#import <Foundation/Foundation.h>

// App-owned import staging must never appear as a new manually supplied image.
static NSArray<NSURL*>* BallpadImportImagesInDocuments(NSURL* documents, NSURL* store)
{
    if (documents == nil) return @[];
    NSString* storePath = store.URLByResolvingSymlinksInPath.path;
    NSString* inboxPath = [documents URLByAppendingPathComponent:@"Inbox"].URLByResolvingSymlinksInPath.path;
    NSMutableArray<NSURL*>* images = [NSMutableArray array];
    NSDirectoryEnumerator<NSURL*>* enumerator = [NSFileManager.defaultManager
        enumeratorAtURL:documents includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey]
        options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
    for (NSURL* url in enumerator)
    {
        NSString* path = url.URLByResolvingSymlinksInPath.path;
        if ([path isEqualToString:storePath] || [path isEqualToString:inboxPath])
        {
            [enumerator skipDescendants];
            continue;
        }
        NSNumber* symbolic = nil;
        [url getResourceValue:&symbolic forKey:NSURLIsSymbolicLinkKey error:NULL];
        if (symbolic.boolValue) continue;
        NSString* extension = url.pathExtension.lowercaseString;
        if (![extension isEqualToString:@"iso"] && ![extension isEqualToString:@"gcm"]) continue;
        NSNumber* regular = nil;
        if (![url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:NULL] || !regular.boolValue) continue;
        [images addObject:url];
    }
    return [images sortedArrayUsingComparator:^NSComparisonResult(NSURL* a, NSURL* b) {
        return [a.lastPathComponent localizedStandardCompare:b.lastPathComponent];
    }];
}

// Call only for URLs returned by this app's copy-mode picker, never for the folder route.
static void BallpadRemovePickerCopy(NSURL* url, NSURL* documents, NSURL* temporary, NSString* bundleIdentifier)
{
    if (!url.isFileURL) return;
    NSNumber* regular = nil;
    NSNumber* symbolic = nil;
    [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:NULL];
    [url getResourceValue:&symbolic forKey:NSURLIsSymbolicLinkKey error:NULL];
    if (!regular.boolValue || symbolic.boolValue) return;
    NSNumber* parentSymbolic = nil;
    [url.URLByDeletingLastPathComponent getResourceValue:&parentSymbolic forKey:NSURLIsSymbolicLinkKey error:NULL];
    if (parentSymbolic.boolValue) return;
    NSURL* resolved = url.URLByResolvingSymlinksInPath;
    NSString* parent = resolved.URLByDeletingLastPathComponent.path;
    NSString* inbox = [documents URLByAppendingPathComponent:@"Inbox"].URLByResolvingSymlinksInPath.path;
    NSString* temporaryPath = temporary.URLByResolvingSymlinksInPath.path;
    // Current UIKit uses tmp/<bundle>-Inbox; older versions use Documents/Inbox.
    BOOL temporaryInbox = [parent.lastPathComponent isEqualToString:[bundleIdentifier stringByAppendingString:@"-Inbox"]] &&
        [parent.stringByDeletingLastPathComponent isEqualToString:temporaryPath];
    if ([parent isEqualToString:inbox] || temporaryInbox)
        [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
}
