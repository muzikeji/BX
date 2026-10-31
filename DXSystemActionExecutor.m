#import "DXSystemActionExecutor.h"
#import "DXSystemActionCatalog.h"
#import "DXSystemActionCompatibility.h"
#import "DXSystemRecordingSession.h"
#import "common.h"
#import "DXPixPinIntegration.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#include <signal.h>
#include <unistd.h>

static __weak UIAlertController *DXSystemActionConfirmation;

void DXCancelSystemActionConfirmation(void) {
    if (!NSThread.isMainThread) return;
    [DXSystemActionConfirmation dismissViewControllerAnimated:NO completion:nil];
    DXSystemActionConfirmation = nil;
}

BOOL DXConfirmSystemExitAction(NSString *action, NSProgress *operation) {
    if (!DXSystemExitActionAvailable(action) || ![DXSystemActionDefinition(action)[@"destructive"] boolValue]) return NO;
    UIWindow *window = DXKeyWindow();
    UIViewController *presenter = window.rootViewController;
    while (presenter.presentedViewController && !presenter.presentedViewController.isBeingDismissed)
        presenter = presenter.presentedViewController;
    if (!presenter || !window || window.hidden || presenter.view.window != window) return NO;
    NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
    NSString *title = [bundle localizedStringForKey:DXSystemActionDefinition(action)[@"title"] value:action table:nil];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:[bundle localizedStringForKey:@"SYSTEM_ACTION_CONFIRM" value:@"Continue?" table:nil]
        preferredStyle:UIAlertControllerStyleAlert];
    NSTimeInterval deadline = NSDate.date.timeIntervalSince1970 + 60;
    __weak UIWindow *originalWindow = window;
    __weak UIViewController *originalPresenter = presenter;
    __weak UIAlertController *originalAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:[bundle localizedStringForKey:@"CANCEL" value:@"Cancel" table:nil]
        style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *choice) {
            if (DXSystemActionConfirmation == originalAlert) DXSystemActionConfirmation = nil;
            [operation cancel];
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:[bundle localizedStringForKey:@"ANSWER_YES" value:@"Continue" table:nil]
        style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *choice) {
            BOOL current = DXSystemActionConfirmation == originalAlert;
            if (current) DXSystemActionConfirmation = nil;
            UIWindow *source = originalWindow;
            if (!current || operation.cancelled || !source || source.hidden || DXKeyWindow() != source ||
                originalPresenter.view.window != source || NSDate.date.timeIntervalSince1970 > deadline) return;
            DXSystemOpenResult result = DXPerformSystemAction(action);
            NSLog(@"[MUBX][SystemAction] confirmed id=%@ result=%llu", action, (unsigned long long)result);
            if (result != DXSystemOpenSucceeded) {
                UIAlertController *error = [UIAlertController alertControllerWithTitle:title
                    message:[bundle localizedStringForKey:@"SYSTEM_ACTION_UNAVAILABLE" value:@"Unavailable" table:nil]
                    preferredStyle:UIAlertControllerStyleAlert];
                [error addAction:[UIAlertAction actionWithTitle:[bundle localizedStringForKey:@"ANSWER_OK" value:@"OK" table:nil]
                    style:UIAlertActionStyleDefault handler:nil]];
                UIAlertController *prompt = originalAlert;
                [prompt dismissViewControllerAnimated:YES completion:^{
                    UIWindow *currentWindow = originalWindow;
                    UIViewController *currentPresenter = originalPresenter;
                    if (operation.cancelled || !currentWindow || currentWindow.hidden || DXKeyWindow() != currentWindow ||
                        currentPresenter.view.window != currentWindow || currentPresenter.presentedViewController ||
                        NSDate.date.timeIntervalSince1970 > deadline) return;
                    [currentPresenter presentViewController:error animated:YES completion:nil];
                }];
            }
        }]];
    DXSystemActionConfirmation = alert;
    [presenter presentViewController:alert animated:YES completion:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (DXSystemActionConfirmation != originalAlert || !originalAlert) return;
        [operation cancel];
        DXCancelSystemActionConfirmation();
    });
    return YES;
}

static void DXLoadSystemActionFrameworks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (NSString *name in @[@"BluetoothManager", @"DoNotDisturb", @"DoNotDisturbKit", @"AVFCapture"]) {
            NSString *path = [NSString stringWithFormat:@"/System/Library/PrivateFrameworks/%@.framework/%@", name, name];
            if (!dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_GLOBAL))
                NSLog(@"[MUBX][SystemAction] framework unavailable name=%@", name);
        }
        dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony", RTLD_LAZY | RTLD_GLOBAL);
    });
}

static id DXSystemShared(NSString *className, NSString *selector) {
    id result = nil;
    return DXSystemInvoke(NSClassFromString(className), selector, @[], &result) ? result : nil;
}

void DXPerformSystemRecordingAction(NSString *action, DXSystemOpenReply reply) {
    if (!DXSystemActionIsRecording(action)) { if (reply) reply(DXSystemOpenInvalid); return; }
    if (![NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"] || !NSThread.isMainThread) {
        if (reply) reply(DXSystemOpenUnavailable);
        return;
    }
    static dispatch_once_t once;
    static DXSystemRecordingSession *session;
    dispatch_once(&once, ^{
        if (!dlopen("/System/Library/Frameworks/ReplayKit.framework/ReplayKit", RTLD_LAZY | RTLD_GLOBAL))
            NSLog(@"[MUBX][SystemRecording] framework unavailable name=ReplayKit");
        session = [DXSystemRecordingSession new];
    });
    [session toggleRecorder:DXSystemShared(@"RPScreenRecorder", @"sharedRecorder")
        microphoneEnabled:[action isEqual:@"screen-recording-microphone"] reply:reply];
}

static id DXSystemObjectIvar(id owner, const char *name) {
    Ivar ivar = owner ? class_getInstanceVariable([owner class], name) : NULL;
    const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
    return type && type[0] == '@' ? object_getIvar(owner, ivar) : nil;
}
static id DXSystemVolumeControl(void) {
    Class cls = NSClassFromString(@"SBVolumeControl");
    if ([cls respondsToSelector:NSSelectorFromString(@"sharedInstance")]) {
        id control = DXSystemShared(@"SBVolumeControl", @"sharedInstance");
        if (control) return control;
    }
    return DXSystemObjectIvar(DXSystemShared(@"SBMediaController", @"sharedInstance"), "_volumeControl") ?:
        DXSystemObjectIvar(DXSystemShared(@"SBUIController", @"sharedInstance"), "_volumeControl");
}
static id DXSystemFlashlight(void) {
    static id flashlight;
    if (!flashlight) flashlight = [NSClassFromString(@"AVFlashlight") new];
    return flashlight;
}
static id DXSystemRingerControl(void) {
    id workspace = DXSystemShared(@"SBMainWorkspace", @"sharedInstance"), ringer = nil;
    if ([workspace respondsToSelector:NSSelectorFromString(@"ringerControl")])
        DXSystemInvoke(workspace, @"ringerControl", @[], &ringer);
    return ringer ?: DXSystemObjectIvar(DXSystemVolumeControl(), "_ringerControl");
}
static NSString *DXSystemAvailableGetter(id target, NSArray<NSString *> *names) {
    for (NSString *name in names) if ([target respondsToSelector:NSSelectorFromString(name)]) return name;
    return nil;
}
static NSNumber *DXSystemPanelValue(id target, NSString *getter) {
    id value = nil;
    return getter && [target respondsToSelector:NSSelectorFromString(getter)] &&
        DXSystemInvoke(target, getter, @[], &value) && [value isKindOfClass:NSNumber.class] ? value : nil;
}
static id DXSystemPanelVolumeTarget(void) {
    id media = DXSystemShared(@"SBMediaController", @"sharedInstance");
    if ([media respondsToSelector:NSSelectorFromString(@"volume")] && [media respondsToSelector:NSSelectorFromString(@"setVolume:")]) return media;
    return DXSystemVolumeControl();
}

static DXSystemOpenResult DXSystemToggle(id target, NSString *getter, NSString *setter) {
    id state = nil;
    if (!DXSystemInvoke(target, getter, @[], &state) || ![state isKindOfClass:NSNumber.class]) return DXSystemOpenUnavailable;
    return DXSystemCall(target, setter, @[@(![state boolValue])]);
}

static BOOL DXSafeModeHandlerLoaded(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        NSString *image = name ? [NSString stringWithUTF8String:name].lowercaseString : nil;
        if ([image containsString:@"safemode"] || [image containsString:@"mobilesafety"]) return YES;
    }
    return NO;
}

BOOL DXSystemExitActionAvailable(NSString *action) {
    if (![NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"] || !NSThread.isMainThread) return NO;
    if ([action isEqual:@"respring-sb"]) return YES;
    if ([action isEqual:@"safe-mode"]) return DXSafeModeHandlerLoaded();
    // Use the exact userspace flag; never fall back to a full reboot or to a shell.
    // This syscall needs privileges that a particular jailbreak may not grant SB.
    if ([action isEqual:@"userspace-reboot"]) return dlsym(RTLD_DEFAULT, "reboot3") != NULL;
    id service = DXSystemShared(@"FBSSystemService", @"sharedService");
    if ([action isEqual:@"shutdown"]) return [service respondsToSelector:NSSelectorFromString(@"shutdown")];
    if ([action isEqual:@"reboot"]) return [service respondsToSelector:NSSelectorFromString(@"reboot")];
    if ([action isEqual:@"respring"]) return [service respondsToSelector:NSSelectorFromString(@"sendActions:withResult:")] &&
        [NSClassFromString(@"SBSRelaunchAction") respondsToSelector:NSSelectorFromString(@"actionWithReason:options:targetURL:")];
    return NO;
}

DXSystemOpenResult DXPerformSystemAction(NSString *action) {
    if (!DXSystemActionDefinition(action)) return DXSystemOpenInvalid;
    if (![NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"] || !NSThread.isMainThread) return DXSystemOpenUnavailable;
    if (DXSystemActionDefinition(action)[@"pixpinNotification"])
        return DXPostPixPinSystemAction(action, DX_ROOT_PATH_NS(DXPixPinDylibPath));
    DXLoadSystemActionFrameworks();
    NSLog(@"[MUBX][SystemAction] execute id=%@", action);
    if ([action isEqual:@"previous-track"] || [action isEqual:@"next-track"]) {
        return DXSystemCall(DXSystemShared(@"SBMediaController", @"sharedInstance"), @"changeTrack:eventSource:",
            @[@([action isEqual:@"next-track"] ? 1 : -1), @0]);
    }
    if ([action isEqual:@"play-pause"]) return DXSystemCall(DXSystemShared(@"SBMediaController", @"sharedInstance"), @"togglePlayPauseForEventSource:", @[@0]);
    if ([action isEqual:@"home"]) return DXSystemCallFirstAvailable(UIApplication.sharedApplication, @[
        @[@"_simulateHomeButtonPress", @[]], @[@"_simulateHomeButtonPressWithCompletion:", @[NSNull.null]]]);
    // Enter SpringBoard's native capture path so screenshot hooks still run.
    // Its void return acknowledges dispatch, not photo-library persistence.
    if ([action isEqual:@"screenshot"]) return DXSystemCall(UIApplication.sharedApplication, @"takeScreenshot", @[]);
    if ([action isEqual:@"switcher"]) {
        id coordinator = DXSystemShared(@"SBMainSwitcherControllerCoordinator", @"sharedInstance");
        NSArray *interfaces = @[@[@"toggleSwitcherNoninteractivelyWithSource:", @[@1]],
            @[@"toggleMainSwitcherNoninteractivelyWithSource:animated:", @[@1, @YES]],
            @[@"toggleSwitcherNoninteractively", @[]]];
        BOOL supported = NO;
        for (NSArray *candidate in interfaces) supported |= [coordinator respondsToSelector:NSSelectorFromString(candidate[0])];
        if (!supported) coordinator = DXSystemShared(@"SBMainSwitcherViewController", @"sharedInstance");
        return DXSystemCallFirstAvailable(coordinator, interfaces);
    }
    if ([action isEqual:@"control-center"]) return DXSystemCallFirstAvailable(DXSystemShared(@"SBControlCenterController", @"sharedInstance"), @[
        @[@"presentAnimated:completion:", @[@YES, NSNull.null]], @[@"presentAnimated:", @[@YES]]]);
    if ([action isEqual:@"wifi"]) return DXSystemToggle(DXSystemShared(@"SBWiFiManager", @"sharedInstance"), @"wiFiEnabled", @"setWiFiEnabled:");
    if ([action isEqual:@"bluetooth"]) {
        id manager = DXSystemShared(@"BluetoothManager", @"sharedInstance");
        id powered = nil;
        if (!DXSystemInvoke(manager, @"powered", @[], &powered) || ![powered isKindOfClass:NSNumber.class]) return DXSystemOpenUnavailable;
        // Bluetooth has separate enabled and powered states. Enable its service
        // before powering on; retain the original route when setEnabled is absent.
        BOOL next = ![powered boolValue];
        if (next && [manager respondsToSelector:NSSelectorFromString(@"setEnabled:")]) {
            DXSystemOpenResult result = DXSystemCall(manager, @"setEnabled:", @[@YES]);
            if (result != DXSystemOpenSucceeded) return result;
        }
        return DXSystemCall(manager, @"setPowered:", @[@(next)]);
    }
    if ([action isEqual:@"airplane"]) return DXSystemToggle(DXSystemShared(@"SBAirplaneModeController", @"sharedInstance"), @"isInAirplaneMode", @"setInAirplaneMode:");
    if ([action isEqual:@"cellular"]) {
        typedef Boolean (*GetData)(void);
        typedef void (*SetData)(Boolean);
        GetData get = (GetData)dlsym(RTLD_DEFAULT, "CTCellularDataPlanGetIsEnabled");
        SetData set = (SetData)dlsym(RTLD_DEFAULT, "CTCellularDataPlanSetIsEnabled");
        if (!get || !set) return DXSystemOpenUnavailable;
        Boolean next = !get();
        set(next);
        // The setter has no acknowledgment; radio changes are asynchronous.
        return DXSystemOpenSucceeded;
    }
    if ([action isEqual:@"orientation-lock"]) {
        id manager = DXSystemShared(@"SBOrientationLockManager", @"sharedInstance");
        id locked = nil;
        if (!DXSystemInvoke(manager, @"isUserLocked", @[], &locked) || ![locked isKindOfClass:NSNumber.class]) return DXSystemOpenUnavailable;
        if ([locked boolValue]) return DXSystemCall(manager, @"unlock", @[]);
        UIInterfaceOrientation orientation = DXKeyWindow().windowScene.interfaceOrientation;
        if (orientation == UIInterfaceOrientationUnknown) orientation = UIInterfaceOrientationPortrait;
        return DXSystemCallFirstAvailable(manager, @[@[@"lock", @[]], @[@"lock:", @[@(orientation)]]]);
    }
    if ([action isEqual:@"dark-mode"]) return DXSystemCall(DXSystemShared(@"UIUserInterfaceStyleArbiter", @"sharedInstance"), @"toggleCurrentStyle", @[]);
    if ([action isEqual:@"brightness-up"] || [action isEqual:@"brightness-down"]) {
        UIScreen *screen = UIScreen.mainScreen;
        screen.brightness = MIN(1, MAX(0, screen.brightness + ([action isEqual:@"brightness-up"] ? 0.1 : -0.1)));
        return DXSystemOpenSucceeded;
    }
    if ([action isEqual:@"volume-up"] || [action isEqual:@"volume-down"]) {
        id volume = DXSystemVolumeControl();
        return DXSystemCall(volume, [action isEqual:@"volume-up"] ? @"increaseVolume" : @"decreaseVolume", @[]);
    }
    if ([action isEqual:@"flashlight"]) {
        id flashlight = DXSystemFlashlight();
        id level = nil;
        if (!DXSystemInvoke(flashlight, @"flashlightLevel", @[], &level) || ![level isKindOfClass:NSNumber.class]) return DXSystemOpenUnavailable;
        return DXSystemCall(flashlight, @"setFlashlightLevel:withError:", @[@([level floatValue] > 0 ? 0.0f : 1.0f), NSNull.null]);
    }
    if ([action isEqual:@"do-not-disturb"]) return DXSystemToggleDND(NSClassFromString(@"DNDStateService"), NSClassFromString(@"DNDToggleManager"));
    if (!DXSystemExitActionAvailable(action)) return DXSystemOpenUnavailable;
    if ([action isEqual:@"respring-sb"]) { exit(0); }
    if ([action isEqual:@"safe-mode"]) { return kill(getpid(), SIGSEGV) == 0 ? DXSystemOpenSucceeded : DXSystemOpenFailed; }
    if ([action isEqual:@"userspace-reboot"]) {
        typedef int (*UserReboot)(uint64_t, ...);
        UserReboot reboot = (UserReboot)dlsym(RTLD_DEFAULT, "reboot3");
        return reboot && reboot(0x2000000000000000ULL) == 0 ? DXSystemOpenSucceeded : DXSystemOpenFailed;
    }
    id service = DXSystemShared(@"FBSSystemService", @"sharedService");
    if ([action isEqual:@"respring"]) {
        id relaunch = nil;
        if (!DXSystemInvoke(NSClassFromString(@"SBSRelaunchAction"), @"actionWithReason:options:targetURL:",
            @[@"RestartRenderServer", @4, NSNull.null], &relaunch) || !relaunch) return DXSystemOpenUnavailable;
        return DXSystemCall(service, @"sendActions:withResult:", @[[NSSet setWithObject:relaunch], NSNull.null]);
    }
    return DXSystemCall(service, [action isEqual:@"shutdown"] ? @"shutdown" : @"reboot", @[]);
}

// Fixed safe controls use their own whitelist in the broker. They do not add
// definitions to the custom-action directory or expose destructive actions.
NSDictionary *DXReadPanelSystemControlState(void) {
    if (!NSThread.isMainThread || ![NSProcessInfo.processInfo.processName isEqual:@"SpringBoard"]) return nil;
    DXLoadSystemActionFrameworks();
    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    id btManager = DXSystemShared(@"BluetoothManager", @"sharedInstance");
    NSNumber *powered = DXSystemPanelValue(btManager, @"powered");
    if (powered && [btManager respondsToSelector:NSSelectorFromString(@"setPowered:")]) state[@"bluetooth"] = @([powered boolValue]);
    id wifi = DXSystemShared(@"SBWiFiManager", @"sharedInstance");
    NSNumber *enabled = DXSystemPanelValue(wifi, @"wiFiEnabled");
    if (enabled && [wifi respondsToSelector:NSSelectorFromString(@"setWiFiEnabled:")]) state[@"wifi"] = @([enabled boolValue]);
    // Read-only mirror of the toggle route in DXSystemToggleDND: the DND daemon
    // only answers entitlement-checked Control Center client identifiers.
    id dndService = nil, dndState = nil;
    NSError *dndError = nil;
    if (DXSystemInvoke(NSClassFromString(@"DNDStateService"), @"serviceForClientIdentifier:",
        @[@"com.apple.donotdisturb.control-center.module"], &dndService) && dndService &&
        DXSystemInvokeReportingError(dndService, @"queryCurrentStateWithError:", @[NSNull.null], &dndState, &dndError) && dndState && !dndError) {
        id activeIdentifier = nil;
        if (DXSystemInvoke(dndState, @"activeModeIdentifier", @[], &activeIdentifier))
            state[@"do-not-disturb"] = @([activeIdentifier isEqual:@"com.apple.donotdisturb.mode.default"]);
        else {
            id isActive = nil;
            if (DXSystemInvoke(dndState, @"isActive", @[], &isActive) && [isActive isKindOfClass:NSNumber.class])
                state[@"do-not-disturb"] = @([isActive boolValue]);
        }
    }
    id lock = DXSystemShared(@"SBOrientationLockManager", @"sharedInstance");
    NSNumber *locked = DXSystemPanelValue(lock, @"isUserLocked");
    if (locked && [lock respondsToSelector:NSSelectorFromString(@"unlock")] &&
        ([lock respondsToSelector:NSSelectorFromString(@"lock")] || [lock respondsToSelector:NSSelectorFromString(@"lock:")])) state[@"orientation-lock"] = @([locked boolValue]);
    id ringer = DXSystemRingerControl();
    NSString *getter = DXSystemAvailableGetter(ringer, @[@"isRingerMuted", @"_accessibilityIsRingerMuted"]);
    NSNumber *muted = DXSystemPanelValue(ringer, getter);
    if (muted && ([ringer respondsToSelector:NSSelectorFromString(@"setRingerMuted:")] ||
        [ringer respondsToSelector:NSSelectorFromString(@"setRingerMuted:withFeedback:reason:clientType:")])) state[@"silent"] = @([muted boolValue]);
    id volume = DXSystemPanelVolumeTarget();
    getter = DXSystemAvailableGetter(volume, @[@"_getMediaVolumeForIAP", @"getMediaVolume", @"volume"]);
    NSNumber *mediaLevel = DXSystemPanelValue(volume, getter);
    if (mediaLevel && ([volume respondsToSelector:NSSelectorFromString(@"_setMediaVolumeForIAP:")] ||
        [volume respondsToSelector:NSSelectorFromString(@"setMediaVolume:")] || [volume respondsToSelector:NSSelectorFromString(@"setVolume:")])) state[@"volume"] = mediaLevel;
    state[@"brightness"] = @(UIScreen.mainScreen.brightness);
    return state;
}
DXSystemOpenResult DXPerformPanelSystemControl(NSString *action, NSNumber *value) {
    if (!NSThread.isMainThread || ![NSProcessInfo.processInfo.processName isEqual:@"SpringBoard"]) return DXSystemOpenUnavailable;
    DXLoadSystemActionFrameworks();
    if ([action isEqual:@"state"]) return DXSystemOpenSucceeded;
    if ([action isEqual:@"brightness"] || [action isEqual:@"volume"]) {
        if (![value isKindOfClass:NSNumber.class] || !isfinite(value.doubleValue) || value.doubleValue < 0 || value.doubleValue > 1) return DXSystemOpenInvalid;
        if ([action isEqual:@"brightness"]) { UIScreen.mainScreen.brightness = value.doubleValue; return DXSystemOpenSucceeded; }
        return DXSystemCallFirstAvailable(DXSystemPanelVolumeTarget(), @[@[@"_setMediaVolumeForIAP:", @[value]],
            @[@"setMediaVolume:", @[value]], @[@"setVolume:", @[value]]]);
    }
    if ([action isEqual:@"silent"]) {
        id ringer = DXSystemRingerControl();
        NSNumber *muted = DXSystemPanelValue(ringer, DXSystemAvailableGetter(ringer, @[@"isRingerMuted", @"_accessibilityIsRingerMuted"]));
        if (!muted) return DXSystemOpenUnavailable;
        NSNumber *next = @(!muted.boolValue);
        return DXSystemCallFirstAvailable(ringer, @[@[@"setRingerMuted:", @[next]],
            @[@"setRingerMuted:withFeedback:reason:clientType:", @[next, @NO, @"MUBXPanel", @0]]]);
    }
    if ([@[@"do-not-disturb", @"wifi", @"bluetooth", @"orientation-lock"] containsObject:action]) return DXPerformSystemAction(action);
    return DXSystemOpenInvalid;
}
