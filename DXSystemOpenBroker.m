#import "DXSystemOpenBroker.h"
#import "DXSensitiveURLExecutor.h"
#import "DXQuickActionProvider.h"
#import "DXSystemActionCatalog.h"
#import "DXSystemActionExecutor.h"
#import "DXPanelControlState.h"
#import "DXKeyboardPanelPreferences.h"
#import "DXPanelRegistry.h"
#import "DXStatusBarGesturePolicy.h"
#import "DXGlobalPanelPolicy.h"
#import "DXGlobalPanel.h"
#import "DXGlobalActionExecutor.h"
#import "DXFloatingApp.h"
#import <notify.h>
#import "common.h"
#import <objc/message.h>
#import <dlfcn.h>

BOOL DXIsSensitiveOpenScheme(NSString *scheme) {
    NSString *lower = scheme.lowercaseString;
    return [lower isEqualToString:@"prefs"] || [lower isEqualToString:@"app-prefs"] ||
           [lower isEqualToString:@"itms-services"];
}

static BOOL DXIsSystemOpenServerProcess(void) {
    return [NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"];
}

// Accessed on the main queue; NSProgress cancellation can be read by the RPC
// worker. A newer system action invalidates an older pending foreground step.
static NSProgress *DXCurrentSystemOpenRequest;

static NSProgress *DXBeginSystemOpenOperation(void) {
    [DXCurrentSystemOpenRequest cancel];
    DXCancelSystemActionConfirmation();
    DXCurrentSystemOpenRequest = [NSProgress discreteProgressWithTotalUnitCount:1];
    return DXCurrentSystemOpenRequest;
}

static DXSystemOpenResult DXActivateSystemApplication(NSString *bundleIdentifier) {
    // Activate inside SpringBoard through the same native selector used by
    // local PullOver-X. No URL event is sent through WeChat and no invented
    // __LaunchURL option is involved. Check the runtime BOOL return ABI;
    // historical headers disagree about this method's return type.
    UIApplication *application = UIApplication.sharedApplication;
    SEL launch = NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:");
    NSMethodSignature *signature = [application methodSignatureForSelector:launch];
    const char *returnType = signature.methodReturnType;
    if (!application || ![application respondsToSelector:launch] || signature.numberOfArguments != 4 || !returnType ||
        (strcmp(returnType, @encode(BOOL)) != 0 && strcmp(returnType, "c") != 0)) {
        return DXSystemOpenUnavailable;
    }
    NSLog(@"[TypeXSB] native application dispatch bundleID=%@", bundleIdentifier);
    BOOL opened = ((BOOL (*)(id, SEL, id, BOOL))objc_msgSend)(application, launch, bundleIdentifier, NO);
    NSLog(@"[TypeXSB] native application bundleID=%@ result=%d", bundleIdentifier, opened);
    return opened ? DXSystemOpenSucceeded : DXSystemOpenFailed;
}

// Runs only in SpringBoard, on the main queue. The requester never supplies
// an Objective-C selector or an arbitrary launch-options dictionary.
static void DXPerformSystemOpen(NSDictionary *request, DXSystemOpenReply reply) {
    if (!DXIsSystemOpenServerProcess() || !NSThread.isMainThread) {
        reply(DXSystemOpenUnavailable);
        return;
    }
    NSString *kind = request[@"kind"];
    NSString *payload = request[@"payload"];
    if (![kind isKindOfClass:NSString.class] || ![payload isKindOfClass:NSString.class] || !payload.length) {
        reply(DXSystemOpenInvalid);
        return;
    }
    if ([kind isEqual:@"floating-shelf-restore"]) {
        NSData *data = [payload dataUsingEncoding:NSUTF8StringEncoding];
        id control = data.length <= 1024 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![control isKindOfClass:NSDictionary.class] || !DXIsValidBundleIdentifier(control[@"bundleID"]) ||
            ![control[@"revision"] isKindOfClass:NSNumber.class]) { reply(DXSystemOpenInvalid); return; }
        NSDate *deadline = [NSDate dateWithTimeIntervalSince1970:[request[@"created"] doubleValue] + DXSystemOpenRequestTTL];
        DXRestoreFloatingAppFromShelf(control[@"bundleID"], [control[@"revision"] unsignedLongLongValue], deadline, reply);
        return;
    }
    if ([kind isEqual:@"floating-application"] || [kind isEqual:@"floating-url"]) {
        BOOL isURL = [kind isEqual:@"floating-url"];
        NSURL *url = isURL && DXIsOpenableSchemeURLString(payload) ? [NSURL URLWithString:payload] : nil;
        NSString *identifier = isURL ? DXFloatingBundleIdentifierForURL(url) : payload;
        if (payload.length > (isURL ? 4096 : 256) || (isURL && !url) || !DXIsValidBundleIdentifier(identifier)) {
            reply(DXSystemOpenInvalid); return;
        }
        NSDate *deadline = [NSDate dateWithTimeIntervalSince1970:[request[@"created"] doubleValue] + DXSystemOpenRequestTTL];
        DXPresentFloatingApplication(identifier, url, deadline, reply);
        return;
    }
    if ([kind isEqual:@"statusbar-gesture"]) {
        NSTimeInterval age = NSDate.date.timeIntervalSince1970 - [request[@"created"] doubleValue];
        if (!(age >= 0 && age <= 1.5)) { reply(DXSystemOpenExpired); return; }
        NSData *data = [payload dataUsingEncoding:NSUTF8StringEncoding];
        id binding = data.length <= 1024 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (!DXStatusBarRequestValid(binding)) { reply(DXSystemOpenInvalid); return; }
        DXPrefsManager *manager = DXPrefsManager.sharedInstance;
        [manager reload];
        NSString *selector = manager.preferencesAvailable ? DXStatusBarRequestSelector(manager.prefs, binding, kEnabledkey) : nil;
        if (!selector || ![DXGlobalPanel deviceUnlocked] || [DXGlobalPanel.sharedInstance isVisible]) {
            NSLog(@"[TypeX][StatusBarGesture] dispatch rejected slot=%@ gate=binding/lock/panel", binding[@"slot"]);
            reply(DXSystemOpenUnavailable); return;
        }
        NSLog(@"[TypeX][StatusBarGesture] dispatch slot=%@", binding[@"slot"]);
        BOOL isPanel = DXPanelAllowed(manager.prefs, selector, DXPanelGestureKind);
        if (isPanel) {
            [DXGlobalPanel.sharedInstance presentPanelSelector:selector fromWindow:nil origin:@"statusbar"];
            reply([DXGlobalPanel.sharedInstance isVisible] ? DXSystemOpenSucceeded : DXSystemOpenUnavailable);
            return;
        }
        id definitions = manager.prefs[kLinkActionskey];
        for (id entry in [definitions isKindOfClass:NSArray.class] ? definitions : @[]) {
            if (![entry isKindOfClass:NSDictionary.class] || ![entry[@"selector"] isEqual:selector]) continue;
            if (!DXIsLinkActionSelector(selector) || !DXGlobalCustomActionSupported(entry)) { reply(DXSystemOpenInvalid); return; }
            DXExecuteGlobalCustomAction(entry, reply);
            return;
        }
        reply(DXSystemOpenInvalid);
        return;
    }
    if ([kind isEqual:@"panel-control"]) {
        NSData *data = [payload dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *control = data.length <= 1024 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (!DXPanelControlRequestValid(control)) { reply(DXSystemOpenInvalid); return; }
        NSTimeInterval age = NSDate.date.timeIntervalSince1970 - [request[@"created"] doubleValue];
        // A drag queued behind a busy SpringBoard must not be applied later.
        if (!(age >= 0 && age <= 1.5)) { reply(DXSystemOpenExpired); return; }
        DXPrefsManager *manager = DXPrefsManager.sharedInstance;
        if (!manager.preferencesAvailable) [manager reload];
        // Toolbar gesture switches no longer control panels opened by buttons.
        NSString *enabledKey = [control[@"source"] isEqual:@"global"] ? kDXPanelGlobalEnabled : kEnabledkey;
        if (!manager.preferencesAvailable || !DXKeyboardPanelBool(manager.prefs, enabledKey, YES)) { reply(DXSystemOpenUnavailable); return; }
        int token = NOTIFY_TOKEN_INVALID;
        NSString *slot = DXPanelControlStateSlot(control[@"token"]);
        uint64_t word = 0;
        if (notify_register_check(slot.UTF8String, &token) != NOTIFY_STATUS_OK) { reply(DXSystemOpenUnavailable); return; }
        if (notify_get_state(token, &word) != NOTIFY_STATUS_OK || word != DXPanelControlPendingWord) {
            notify_cancel(token); reply(DXSystemOpenExpired); return;
        }
        DXSystemOpenResult result = DXSystemOpenFailed;
        @try {
            result = DXPerformPanelSystemControl(control[@"action"], control[@"value"]);
            NSDictionary *state = DXReadPanelSystemControlState();
            if (!state || notify_set_state(token, DXPanelControlEncodeState(state)) != NOTIFY_STATUS_OK)
                result = DXSystemOpenUnavailable;
        } @finally { notify_cancel(token); }
        if (![control[@"action"] isEqual:@"state"] || result != DXSystemOpenSucceeded)
            NSLog(@"[TypeX][PanelControl] action=%@ result=%llu", control[@"action"], (unsigned long long)result);
        reply(result);
        return;
    }
    if ([kind isEqualToString:@"system-action"]) {
        NSDictionary *definition = DXSystemActionDefinition(payload);
        if (!definition) { reply(DXSystemOpenInvalid); return; }
        NSTimeInterval age = NSDate.date.timeIntervalSince1970 - [request[@"created"] doubleValue];
        if (!(age >= 0 && age <= DXSystemOpenRequestTTL)) { reply(DXSystemOpenExpired); return; }
        DXPrefsManager *manager = DXPrefsManager.sharedInstance;
        if (!manager.preferencesAvailable) [manager reload];
        if (!manager.preferencesAvailable) { reply(DXSystemOpenUnavailable); return; }
        if (!DXSystemActionIsConfigured(manager.prefs[kLinkActionskey], payload, kLinkActionSelectorPrefix)) {
            reply(DXSystemOpenInvalid); return;
        }
        if (DXSystemActionIsRecording(payload)) {
            // ReplayKit acknowledges asynchronously. Its separate flight guard
            // survives unrelated foreground requests and never retries on timeout.
            DXPerformSystemRecordingAction(payload, reply);
            return;
        }
        NSProgress *operation = DXBeginSystemOpenOperation();
        if ([definition[@"destructive"] boolValue]) {
            // A transport success acknowledges the trusted SpringBoard prompt.
            // Execution requires a fresh user choice inside that prompt; callers
            // cannot bypass it by forging a client-side "confirmed" flag.
            reply(DXConfirmSystemExitAction(payload, operation) ? DXSystemOpenSucceeded : DXSystemOpenUnavailable);
        } else {
            DXSystemOpenResult result = DXPerformSystemAction(payload);
            NSLog(@"[TypeX][SystemAction] id=%@ result=%llu", payload, (unsigned long long)result);
            reply(result);
        }
        return;
    }
    if ([kind isEqualToString:@"quick-action"]) {
        NSData *data = [payload dataUsingEncoding:NSUTF8StringEncoding];
        if (!data.length || data.length > 4096) { reply(DXSystemOpenInvalid); return; }
        id fields = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![fields isKindOfClass:NSDictionary.class]) { reply(DXSystemOpenInvalid); return; }
        NSString *bundleIdentifier = fields[@"bundleID"];
        NSString *shortcutType = fields[@"shortcutType"];
        if (!DXIsValidBundleIdentifier(bundleIdentifier) || bundleIdentifier.length > 256 ||
            !DXIsValidAppShortcutType(shortcutType)) { reply(DXSystemOpenInvalid); return; }
        NSTimeInterval age = [NSDate date].timeIntervalSince1970 - [request[@"created"] doubleValue];
        if (!(age >= 0 && age <= DXSystemOpenRequestTTL)) { reply(DXSystemOpenExpired); return; }
        DXBeginSystemOpenOperation();
        reply([DXQuickActionProvider activateShortcutWithBundleIdentifier:bundleIdentifier type:shortcutType]);
        return;
    }
    if ([kind isEqualToString:@"sensitive-url"]) {
        NSURL *url = [NSURL URLWithString:payload];
        if (!url || payload.length > 2048 || !DXIsSensitiveOpenScheme(url.scheme)) { reply(DXSystemOpenInvalid); return; }
        typedef bool (*DXSensitiveOpen)(CFURLRef, char);
        DXSensitiveOpen openSensitive = (DXSensitiveOpen)dlsym(RTLD_DEFAULT, "SBSOpenSensitiveURLAndUnlock");
        if (!openSensitive) { reply(DXSystemOpenUnavailable); return; }
        // Preserve the original deadline across the worker queue. A queued RPC
        // cannot become a surprise open after the caller's request expired.
        NSNumber *created = request[@"created"];
        NSDate *deadline = [NSDate dateWithTimeIntervalSince1970:created.doubleValue + DXSystemOpenRequestTTL];
        DXExecuteSensitiveURL(url, deadline, DXBeginSystemOpenOperation(), ^BOOL(NSURL *sensitiveURL) {
            return openSensitive((__bridge CFURLRef)sensitiveURL, 0);
        }, reply);
        return;
    }
    if (![kind isEqualToString:@"application"] || payload.length > 256 || !DXIsValidBundleIdentifier(payload)) {
        reply(DXSystemOpenInvalid);
        return;
    }

    DXBeginSystemOpenOperation();
    reply(DXActivateSystemApplication(payload));
}

static void DXSubmitSystemOpen(NSString *kind, NSString *payload, DXSystemOpenReply reply) {
    if (DXIsSystemOpenServerProcess()) {
        NSDictionary *request = @{@"kind": kind, @"payload": payload ?: @"",
                                   @"created": @([NSDate date].timeIntervalSince1970)};
        dispatch_async(dispatch_get_main_queue(), ^{
            __block BOOL completed = NO;
            DXSystemOpenReply finish = ^(DXSystemOpenResult result) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completed) return;
                    completed = YES;
                    if (reply) reply(result);
                });
            };
            @try { DXPerformSystemOpen(request, finish); }
            @catch (NSException *exception) {
                NSLog(@"[TypeXSB] direct exception=%@", exception.name);
                finish(DXSystemOpenFailed);
            }
        });
        return;
    }
    DXSendDarwinOpenRequest(kind, payload, reply);
}

void DXRequestStatusBarGesture(NSString *slot, NSString *expectedSelector, BOOL landscape, DXSystemOpenReply reply) {
    NSDictionary *request = @{@"slot": slot ?: @"", @"selector": expectedSelector ?: @"", @"landscape": @(landscape)};
    if (!DXStatusBarRequestValid(request)) { if (reply) reply(DXSystemOpenInvalid); return; }
    NSData *data = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
    if (!data.length || data.length > 1024) { if (reply) reply(DXSystemOpenInvalid); return; }
    DXSubmitSystemOpen(@"statusbar-gesture", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding], reply);
}

void DXOpenSystemApplication(NSString *bundleIdentifier, DXSystemOpenReply reply) {
    DXSubmitSystemOpen(@"application", bundleIdentifier, reply);
}

void DXRestoreFloatingApplication(NSString *identifier, uint64_t revision, DXSystemOpenReply reply) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"bundleID": identifier ?: @"", @"revision": @(revision)} options:0 error:nil];
    DXSubmitSystemOpen(@"floating-shelf-restore", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding], reply);
}
void DXOpenFloatingApplication(NSString *bundleIdentifier, DXSystemOpenReply reply) {
    DXSubmitSystemOpen(@"floating-application", bundleIdentifier, reply);
}

void DXOpenFloatingURL(NSURL *url, DXSystemOpenReply reply) {
    DXSubmitSystemOpen(@"floating-url", url.absoluteString, reply);
}

void DXRunSystemAction(NSString *identifier, DXSystemOpenReply reply) {
    if (!DXSystemActionDefinition(identifier)) {
        if (reply) dispatch_async(dispatch_get_main_queue(), ^{ reply(DXSystemOpenInvalid); });
        return;
    }
    DXSubmitSystemOpen(@"system-action", identifier, reply);
}

void DXOpenSensitiveSystemURL(NSURL *url, DXSystemOpenReply reply) {
    DXSubmitSystemOpen(@"sensitive-url", url.absoluteString, reply);
}

BOOL DXStartSystemOpenBroker(void) {
    if (!DXIsSystemOpenServerProcess()) return NO;
    return DXStartDarwinOpenServer(^(NSDictionary *request, DXSystemOpenReply reply) {
        DXPerformSystemOpen(request, reply);
    });
}

void DXOpenSystemShortcut(NSString *bundleIdentifier, NSString *shortcutType, DXSystemOpenReply reply) {
    if (!DXIsValidBundleIdentifier(bundleIdentifier) || bundleIdentifier.length > 256 ||
        !DXIsValidAppShortcutType(shortcutType)) {
        if (reply) dispatch_async(dispatch_get_main_queue(), ^{ reply(DXSystemOpenInvalid); });
        return;
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"bundleID": bundleIdentifier, @"shortcutType": shortcutType}
                                                 options:0 error:nil];
    if (!data.length || data.length > 4096) {
        if (reply) dispatch_async(dispatch_get_main_queue(), ^{ reply(DXSystemOpenInvalid); });
        return;
    }
    DXSubmitSystemOpen(@"quick-action", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding], reply);
}

// NSProgress may dispatch cancellationHandler asynchronously. Revoke the
// request-owned slot synchronously when the keyboard panel closes on main.
@interface DXPanelControlOperation : NSProgress
@property(nonatomic, copy) void (^invalidateSlot)(void);
@end
@implementation DXPanelControlOperation
- (void)cancel {
    void (^invalidate)(void) = self.invalidateSlot;
    if (invalidate) {
        if (NSThread.isMainThread) invalidate();
        else dispatch_async(dispatch_get_main_queue(), invalidate);
    }
    [super cancel];
}
@end

NSProgress *DXRequestPanelSystemControl(NSString *action, NSNumber *value, NSString *source, DXPanelSystemControlReply reply) {
    DXPanelControlOperation *operation = [[DXPanelControlOperation alloc] initWithParent:nil userInfo:nil];
    operation.totalUnitCount = 1;
    if (!NSThread.isMainThread) {
        if (reply) dispatch_async(dispatch_get_main_queue(), ^{ reply(DXSystemOpenUnavailable, nil); });
        return operation;
    }
    NSMutableDictionary *request = [@{@"action": action ?: @"", @"source": source ?: @"", @"token": NSUUID.UUID.UUIDString} mutableCopy];
    if (value) request[@"value"] = value;
    if (!DXPanelControlRequestValid(request)) {
        if (reply) dispatch_async(dispatch_get_main_queue(), ^{ if (!operation.cancelled) reply(DXSystemOpenInvalid, nil); });
        return operation;
    }
    int token = NOTIFY_TOKEN_INVALID;
    NSString *slot = DXPanelControlStateSlot(request[@"token"]);
    if (notify_register_check(slot.UTF8String, &token) != NOTIFY_STATUS_OK) {
        if (reply) dispatch_async(dispatch_get_main_queue(), ^{ if (!operation.cancelled) reply(DXSystemOpenUnavailable, nil); });
        return operation;
    }
    __block BOOL cleaned = NO;
    void (^cleanup)(void) = ^{
        if (cleaned) return;
        cleaned = YES;
        notify_set_state(token, 0);
        notify_cancel(token);
    };
    operation.invalidateSlot = cleanup;
    if (notify_set_state(token, DXPanelControlPendingWord) != NOTIFY_STATUS_OK) {
        cleanup();
        if (reply) dispatch_async(dispatch_get_main_queue(), ^{ if (!operation.cancelled) reply(DXSystemOpenUnavailable, nil); });
        return operation;
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
    DXSubmitSystemOpen(@"panel-control", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding], ^(DXSystemOpenResult result) {
        uint64_t word = 0;
        NSDictionary *state = !cleaned && notify_get_state(token, &word) == NOTIFY_STATUS_OK ? DXPanelControlDecodeState(word) : nil;
        cleanup();
        if (result == DXSystemOpenSucceeded && !state) result = DXSystemOpenUnavailable;
        if (!operation.cancelled && reply) reply(result, state);
    });
    return operation;
}
