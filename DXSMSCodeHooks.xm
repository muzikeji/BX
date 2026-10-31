#import "common.h"
#import "DXSMSCodePolicy.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#include <atomic>

// One atomic word carries both admission and epoch, so reloads cannot undo
// a newer disable notification. Bit 0 is enabled; higher bits are the epoch.
static std::atomic<NSUInteger> DXSMSCodeEpoch(0);
static DXSMSCodeSession *DXSMSSession;
static void DXSMSTryInstallHooks(void);

// Read only object-returning selectors whose ABI has been checked. A missing
// or changed private getter disables that field instead of crashing SpringBoard.
static id DXSMSObject(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) return nil;
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 2 || signature.methodReturnType[0] != '@') return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}
static NSString *DXSMSString(id object, NSString *name) {
    id value = DXSMSObject(object, name);
    return [value isKindOfClass:NSString.class] ? [value copy] : nil;
}

static void DXSMSCaptureBulletin(id bulletin, NSString *explicitSection) {
    // The off path does not even read the notification payload.
    NSUInteger epoch = DXSMSCodeEpoch.load();
    if (!(epoch & 1)) return;
    NSString *section = explicitSection ?: DXSMSString(bulletin, @"sectionID");
    if (![section isEqualToString:@"com.apple.MobileSMS"]) return;
    NSString *text = DXSMSString(bulletin, @"message");
    if (!text.length || text.length > 4096) return;
    NSString *messageID = DXSMSString(bulletin, @"recordID");
    if (!messageID.length) messageID = DXSMSString(bulletin, @"publisherBulletinID");
    if (!messageID.length) messageID = DXSMSString(bulletin, @"bulletinID");
    id date = DXSMSObject(bulletin, @"date");
    if (![date isKindOfClass:NSDate.class]) date = DXSMSObject(bulletin, @"publicationDate");
    if (!messageID.length || ![date isKindOfClass:NSDate.class]) return;
    NSDate *messageDate = [date copy];
    NSDate *receivedAt = [NSDate date];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (epoch != DXSMSCodeEpoch.load() ||
            [[NSDate date] timeIntervalSinceDate:receivedAt] > 2) return;
        @try {
            NSString *code = DXSMSExtractCode(text);
            if (!code || ![DXSMSSession acceptMessageID:messageID date:messageDate now:[NSDate date]]) return;
            if (epoch != DXSMSCodeEpoch.load()) return;
            // Parsing and writing form one main-thread operation; there is no
            // delayed parse result that can later replace a newer manual copy.
            [[UIPasteboard generalPasteboard] setItems:@[@{@"public.utf8-plain-text": code}]
                options:@{UIPasteboardOptionLocalOnly: @YES,
                          UIPasteboardOptionExpirationDate: [NSDate dateWithTimeIntervalSinceNow:180]}];
            NSLog(@"[MUBX][SMSCode] receive copied length=%lu", (unsigned long)code.length);
        } @catch (NSException *exception) {
            NSLog(@"[MUBX][SMSCode] receive copy failed");
        }
    });
}
static void DXSMSReceiveBulletin(id bulletin, NSString *explicitSection) {
    @try { DXSMSCaptureBulletin(bulletin, explicitSection); }
    @catch (NSException *exception) { NSLog(@"[MUBX][SMSCode] receive unsupported payload"); }
}

%group DXSMSPublish
%hook BBServer
- (void)publishBulletin:(id)bulletin destinations:(unsigned long long)destinations {
    DXSMSReceiveBulletin(bulletin, nil);
    %orig;
}
%end
%end
%group DXSMSPublishLock
%hook BBServer
- (void)publishBulletin:(id)bulletin destinations:(unsigned long long)destinations alwaysToLockScreen:(BOOL)always {
    DXSMSReceiveBulletin(bulletin, nil);
    %orig;
}
%end
%end
%group DXSMSRequest
%hook BBServer
- (void)publishBulletinRequest:(id)bulletin destinations:(unsigned long long)destinations {
    DXSMSReceiveBulletin(bulletin, nil);
    %orig;
}
%end
%end
%group DXSMSPrivateRequest
%hook BBServer
- (void)_publishBulletinRequest:(id)bulletin forSectionID:(id)section forDestinations:(unsigned long long)destinations {
    DXSMSReceiveBulletin(bulletin, [section isKindOfClass:NSString.class] ? section : nil);
    %orig;
}
%end
%end
%group DXSMSPrivateRequestLock
%hook BBServer
- (void)_publishBulletinRequest:(id)bulletin forSectionID:(id)section forDestinations:(unsigned long long)destinations alwaysToLockScreen:(BOOL)always {
    DXSMSReceiveBulletin(bulletin, [section isKindOfClass:NSString.class] ? section : nil);
    %orig;
}
%end
%end

static BOOL DXSMSMethodMatches(Class cls, NSString *name, const char *arguments) {
    Method method = class_getInstanceMethod(cls, NSSelectorFromString(name));
    if (!method || method_getNumberOfArguments(method) != strlen(arguments) + 2) return NO;
    char type[16] = {};
    method_getReturnType(method, type, sizeof(type));
    if (type[0] != 'v') return NO;
    for (NSUInteger i = 0; arguments[i]; i++) {
        method_getArgumentType(method, (unsigned int)i + 2, type, sizeof(type));
        if (arguments[i] == 'B') {
            if (type[0] != 'B' && type[0] != 'c') return NO;
        } else if (type[0] != arguments[i]) return NO;
    }
    return YES;
}
static void DXSMSTryInstallHooks(void) {
    Class cls = NSClassFromString(@"BBServer");
    if (!cls) return;
    static BOOL publish, publishLock, request, privateRequest, privateRequestLock;
    if (!publish && DXSMSMethodMatches(cls, @"publishBulletin:destinations:", "@Q")) {
        %init(DXSMSPublish, BBServer = cls); publish = YES;
    }
    if (!publishLock && DXSMSMethodMatches(cls, @"publishBulletin:destinations:alwaysToLockScreen:", "@QB")) {
        %init(DXSMSPublishLock, BBServer = cls); publishLock = YES;
    }
    if (!request && DXSMSMethodMatches(cls, @"publishBulletinRequest:destinations:", "@Q")) {
        %init(DXSMSRequest, BBServer = cls); request = YES;
    }
    if (!privateRequest && DXSMSMethodMatches(cls, @"_publishBulletinRequest:forSectionID:forDestinations:", "@@Q")) {
        %init(DXSMSPrivateRequest, BBServer = cls); privateRequest = YES;
    }
    if (!privateRequestLock && DXSMSMethodMatches(cls, @"_publishBulletinRequest:forSectionID:forDestinations:alwaysToLockScreen:", "@@QB")) {
        %init(DXSMSPrivateRequestLock, BBServer = cls); privateRequestLock = YES;
    }
    static BOOL reported;
    if (!reported) {
        reported = YES;
        NSLog(@"[MUBX][SMSCode] hooks publish=%d lock=%d request=%d private=%d privateLock=%d",
              publish, publishLock, request, privateRequest, privateRequestLock);
    }
}
static void DXSMSReload(void) {
    NSUInteger epoch = DXSMSCodeEpoch.load();
    NSDictionary *preferences = [[DXPrefsManager sharedInstance] readPrefs];
    [DXSMSSession updatePreferences:preferences now:[NSDate date]];
    DXSMSCodeEpoch.compare_exchange_strong(epoch, (epoch & ~NSUInteger(1)) | (DXSMSSession.enabled ? 1 : 0));
}
static void DXSMSPreferencesChanged(CFNotificationCenterRef center, void *observer,
                                   CFStringRef name, const void *object, CFDictionaryRef info) {
    // Stop admission immediately; a disable/re-enable invalidates queued work
    // even if both preference notifications arrive before the main queue runs.
    NSUInteger epoch = DXSMSCodeEpoch.load();
    while (!DXSMSCodeEpoch.compare_exchange_weak(epoch, (epoch + 2) & ~NSUInteger(1))) {}
    dispatch_async(dispatch_get_main_queue(), ^{ DXSMSReload(); });
}
%ctor {
    @autoreleasepool {
        if (![NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            DXSMSSession = [DXSMSCodeSession new];
            DXSMSReload();
            // Keep the image loaded for the installed IMPs' process lifetime.
            dlopen("/System/Library/PrivateFrameworks/BulletinBoard.framework/BulletinBoard", RTLD_LAZY);
            DXSMSTryInstallHooks();
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                DXSMSPreferencesChanged, (CFStringRef)kPrefsChangedIdentifier, NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately);
            // Process-lifetime observers, installed exactly once in SpringBoard.
            [NSNotificationCenter.defaultCenter addObserverForName:NSBundleDidLoadNotification object:nil
                queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { DXSMSTryInstallHooks(); }];
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil
                queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { DXSMSTryInstallHooks(); }];
        });
    }
}
