#import "DXSystemActionInvocation.h"
#import "DXDarwinOpenChannel.h"

static inline DXSystemOpenResult DXSystemCall(id target, NSString *selector, NSArray *arguments) {
    id result = nil;
    NSError *error = nil;
    if (!DXSystemInvokeReportingError(target, selector, arguments, &result, &error)) {
        NSLog(@"[MUBX][SystemAction] unavailable class=%@ selector=%@", target ? NSStringFromClass([target class]) : @"nil", selector);
        return DXSystemOpenUnavailable;
    }
    if ([error isKindOfClass:NSError.class]) {
        NSLog(@"[MUBX][SystemAction] native error selector=%@ domain=%@ code=%ld", selector, error.domain, (long)error.code);
        return DXSystemOpenFailed;
    }
    return [result isKindOfClass:NSNumber.class] && ![result boolValue] ? DXSystemOpenFailed : DXSystemOpenSucceeded;
}

// Select one supported interface before invoking. An invoked failure never
// falls through to another interface, which could repeat a system operation.
static inline DXSystemOpenResult DXSystemCallFirstAvailable(id target, NSArray<NSArray *> *candidates) {
    for (NSArray *candidate in candidates) {
        if ([target respondsToSelector:NSSelectorFromString(candidate[0])])
            return DXSystemCall(target, candidate[0], candidate[1]);
    }
    NSLog(@"[MUBX][SystemAction] no compatible interface class=%@", target ? NSStringFromClass([target class]) : @"nil");
    return DXSystemOpenUnavailable;
}

// Classes are supplied by the SpringBoard executor after loading the native
// frameworks; keeping this route Foundation-only permits error-path tests.
static inline DXSystemOpenResult DXSystemToggleDND(Class stateServiceClass, Class toggleManagerClass) {
    // DND daemon checks the caller's client-identifier entitlements even
    // inside SpringBoard. A MUBX-invented identifier cannot query/assert.
    NSString *client = @"com.apple.donotdisturb.control-center.module";
    id service = nil, state = nil, manager = nil, activeIdentifier = nil;
    NSError *error = nil;
    if (!DXSystemInvoke(stateServiceClass, @"serviceForClientIdentifier:", @[client], &service) || !service ||
        !DXSystemInvokeReportingError(service, @"queryCurrentStateWithError:", @[NSNull.null], &state, &error) || !state || error) {
        if (error) NSLog(@"[MUBX][SystemAction] DND query error domain=%@ code=%ld", error.domain, (long)error.code);
        return error ? DXSystemOpenFailed : DXSystemOpenUnavailable;
    }
    if (!DXSystemInvoke(toggleManagerClass, @"managerForClientIdentifier:", @[client], &manager) || !manager) return DXSystemOpenUnavailable;
    BOOL active = NO;
    if ([state respondsToSelector:NSSelectorFromString(@"activeModeIdentifier")]) {
        if (!DXSystemInvoke(state, @"activeModeIdentifier", @[], &activeIdentifier)) return DXSystemOpenUnavailable;
        active = [activeIdentifier isEqual:@"com.apple.donotdisturb.mode.default"];
    } else {
        id isActive = nil;
        if (!DXSystemInvoke(state, @"isActive", @[], &isActive) || ![isActive isKindOfClass:NSNumber.class]) return DXSystemOpenUnavailable;
        active = [isActive boolValue];
    }
    return DXSystemCall(manager, active ? @"_toggleDNDOffReturningError:" : @"_toggleDNDOnReturningError:", @[NSNull.null]);
}
