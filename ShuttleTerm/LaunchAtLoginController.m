//
//  LaunchAtLoginController.m
//
//  Copyright 2011 Tomáš Znamenáček
//  Copyright 2010 Ben Clark-Robinson
//
//  Permission is hereby granted, free of charge, to any person obtaining
//  a copy of this software and associated documentation files (the 'Software'),
//  to deal in the Software without restriction, including without limitation
//  the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  and/or sell copies of the Software, and to permit persons to whom the
//  Software is furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be
//  included in all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND,
//  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
//  MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
//  IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
//  CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
//  TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
//  SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

#import "LaunchAtLoginController.h"
#import <ServiceManagement/ServiceManagement.h>

static NSString *const StartAtLoginKey = @"launchAtLogin";

@interface LaunchAtLoginController ()
@property(nonatomic, assign) LSSharedFileListRef loginItems;
@end

@implementation LaunchAtLoginController

#pragma mark Change Observing

void sharedFileListDidChange(LSSharedFileListRef inList, void *context)
{
    LaunchAtLoginController *controller = (__bridge LaunchAtLoginController *)context;
    [controller willChangeValueForKey:StartAtLoginKey];
    [controller didChangeValueForKey:StartAtLoginKey];
}

#pragma mark Initialization

- (instancetype)init
{
    self = [super init];
    if (!self) {
        return nil;
    }

    if (@available(macOS 13.0, *)) {
        return self;
    }

    _loginItems = LSSharedFileListCreate(NULL, kLSSharedFileListSessionLoginItems, NULL);
    LSSharedFileListAddObserver(_loginItems, CFRunLoopGetMain(),
                                 (CFStringRef)NSDefaultRunLoopMode, sharedFileListDidChange,
                                 (__bridge void *)self);
    return self;
}

- (void)dealloc
{
    if (_loginItems) {
        LSSharedFileListRemoveObserver(_loginItems, CFRunLoopGetMain(),
                                       (CFStringRef)NSDefaultRunLoopMode, sharedFileListDidChange,
                                       (__bridge void *)self);
        CFRelease(_loginItems);
        _loginItems = NULL;
    }
}

#pragma mark Launch List Control

- (LSSharedFileListItemRef)findItemWithURL:(NSURL *)wantedURL inFileList:(LSSharedFileListRef)fileList
{
    if (!wantedURL || !fileList) {
        return NULL;
    }

    NSArray *listSnapshot = (__bridge_transfer NSArray *)LSSharedFileListCopySnapshot(fileList, NULL);
    for (id itemObject in listSnapshot) {
        LSSharedFileListItemRef item = (__bridge LSSharedFileListItemRef)itemObject;
        UInt32 resolutionFlags = kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes;
        CFURLRef currentItemURL = NULL;
        LSSharedFileListItemResolve(item, resolutionFlags, &currentItemURL, NULL);
        if (currentItemURL && CFEqual(currentItemURL, (__bridge CFURLRef)wantedURL)) {
            CFRelease(currentItemURL);
            return item;
        }
        if (currentItemURL) {
            CFRelease(currentItemURL);
        }
    }

    return NULL;
}

- (BOOL)willLaunchAtLogin:(NSURL *)itemURL
{
    return [self findItemWithURL:itemURL inFileList:_loginItems] != NULL;
}

- (void)setLaunchAtLogin:(BOOL)enabled forURL:(NSURL *)itemURL
{
    LSSharedFileListItemRef appItem = [self findItemWithURL:itemURL inFileList:_loginItems];
    if (enabled && !appItem) {
        LSSharedFileListInsertItemURL(_loginItems, kLSSharedFileListItemBeforeFirst,
                                      NULL, NULL, (__bridge CFURLRef)itemURL, NULL, NULL);
    } else if (!enabled && appItem) {
        LSSharedFileListItemRemove(_loginItems, appItem);
    }
}

#pragma mark Basic Interface

- (NSURL *)appURL
{
    return [NSURL fileURLWithPath:[[NSBundle mainBundle] bundlePath]];
}

- (void)setLaunchAtLogin:(BOOL)enabled
{
    [self willChangeValueForKey:StartAtLoginKey];

    if (@available(macOS 13.0, *)) {
        SMAppService *service = [SMAppService mainAppService];
        if (enabled) {
            [service registerAndReturnError:NULL];
        } else {
            [service unregisterAndReturnError:NULL];
        }
    } else {
        [self setLaunchAtLogin:enabled forURL:[self appURL]];
    }

    [self didChangeValueForKey:StartAtLoginKey];
}

- (BOOL)launchAtLogin
{
    if (@available(macOS 13.0, *)) {
        return [SMAppService mainAppService].status == SMAppServiceStatusEnabled;
    }

    return [self willLaunchAtLogin:[self appURL]];
}

@end