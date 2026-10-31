#import "DXQuickActionProvider.h"
#import "common.h"
#import <objc/message.h>

static NSString *DXQAReadString(id object, NSString *propertyName) {
    SEL selector = NSSelectorFromString(propertyName);
    if (!object || ![object respondsToSelector:selector]) return nil;
    @try {
        id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
        return [value isKindOfClass:[NSString class]] ? value : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static id DXQAReadObject(id object, NSString *propertyName) {
    SEL selector = NSSelectorFromString(propertyName);
    if (!object || ![object respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static dispatch_queue_t DXQASnapshotWriterQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.lindo.mubx.quickactions.snapshot", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static void DXQAWriteStatus(NSString *phase, NSString *requestID, NSDictionary *details) {
    NSMutableDictionary *status = [NSMutableDictionary dictionaryWithDictionary:details ?: @{}];
    status[@"phase"] = phase ?: @"unknown";
    status[@"updated"] = @([NSDate timeIntervalSinceReferenceDate]);
    if (requestID.length > 0) status[@"requestID"] = requestID;
    DXSetQuickActionSharedValue(status, MUBXQuickActionStatusKey);
}

static id DXQAApplicationController(void) {
    Class controllerClass = NSClassFromString(@"SBApplicationController");
    SEL sharedSelector = NSSelectorFromString(@"sharedInstance");
    if (!controllerClass || ![controllerClass respondsToSelector:sharedSelector]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(controllerClass, sharedSelector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static id DXQAApplication(id controller, NSString *bundleIdentifier) {
    SEL selector = NSSelectorFromString(@"applicationWithBundleIdentifier:");
    if (!controller || ![controller respondsToSelector:selector] || bundleIdentifier.length == 0) return nil;
    @try {
        return ((id (*)(id, SEL, id))objc_msgSend)(controller, selector, bundleIdentifier);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSArray<NSString *> *DXQABundleIdentifiersFromController(id controller) {
    NSArray *applications = DXQAReadObject(controller, @"allApplications");
    if ([applications isKindOfClass:[NSSet class]]) applications = [(NSSet *)applications allObjects];
    if (![applications isKindOfClass:[NSArray class]]) return @[];

    NSMutableOrderedSet<NSString *> *bundleIdentifiers = [NSMutableOrderedSet orderedSet];
    for (id application in applications) {
        NSString *bundleIdentifier = DXQAReadString(application, @"bundleIdentifier")
            ?: DXQAReadString(application, @"applicationIdentifier");
        if (DXIsValidBundleIdentifier(bundleIdentifier)) [bundleIdentifiers addObject:bundleIdentifier];
    }
    return bundleIdentifiers.array;
}

static NSArray *DXQAArray(id value) {
    return [value isKindOfClass:[NSArray class]] ? value : @[];
}

static NSArray *DXQAStaticItems(id application) {
    id info = DXQAReadObject(application, @"info");
    NSArray *items = DXQAArray(DXQAReadObject(info, @"staticApplicationShortcutItems"));
    if (items.count == 0) {
        items = DXQAArray(DXQAReadObject(application, @"staticApplicationShortcutItems"));
    }
    return items;
}

static NSArray *DXQADynamicItems(id application) {
    return DXQAArray(DXQAReadObject(application, @"dynamicApplicationShortcutItems"));
}

static NSDictionary *DXQADescriptor(id item, NSString *source) {
    NSString *type = DXQAReadString(item, @"type");
    if (type.length == 0 || [type hasPrefix:@"com.apple.springboard."]) return nil;

    NSString *title = DXQAReadString(item, @"localizedTitle") ?: DXQAReadString(item, @"title");
    NSString *subtitle = DXQAReadString(item, @"localizedSubtitle") ?: DXQAReadString(item, @"subtitle");
    NSMutableDictionary *descriptor = [NSMutableDictionary dictionaryWithDictionary:@{
        @"type": type,
        @"title": title.length > 0 ? title : type,
        @"source": source,
    }];
    if (subtitle.length > 0) descriptor[@"subtitle"] = subtitle;
    return descriptor;
}

// Dynamic items precede static items, matching the order used by the system
// menu. A type is the stable app-defined identity; duplicate types are exposed
// once and always resolve to the current first matching object at activation.
static NSArray<NSDictionary *> *DXQADescriptors(id application) {
    NSMutableArray<NSDictionary *> *descriptors = [NSMutableArray array];
    NSMutableSet<NSString *> *seenTypes = [NSMutableSet set];
    for (NSDictionary *sourceGroup in @[
        @{@"source": @"dynamic", @"items": DXQADynamicItems(application)},
        @{@"source": @"static", @"items": DXQAStaticItems(application)},
    ]) {
        for (id item in sourceGroup[@"items"]) {
            NSDictionary *descriptor = DXQADescriptor(item, sourceGroup[@"source"]);
            NSString *type = descriptor[@"type"];
            if (type.length == 0 || [seenTypes containsObject:type]) continue;
            [seenTypes addObject:type];
            [descriptors addObject:descriptor];
        }
    }
    return descriptors;
}

static id DXQACurrentItem(id application, NSString *shortcutType) {
    for (NSArray *items in @[DXQADynamicItems(application), DXQAStaticItems(application)]) {
        for (id item in items) {
            if ([DXQAReadString(item, @"type") isEqualToString:shortcutType]) return item;
        }
    }
    return nil;
}

@implementation DXQuickActionProvider

+ (void)refreshSnapshotForBundleIdentifiers:(NSArray<NSString *> *)bundleIdentifiers
                                   requestID:(NSString *)requestID {
    NSString *resolvedRequestID = requestID.length > 0 ? requestID : [NSUUID UUID].UUIDString;
    dispatch_async(dispatch_get_main_queue(), ^{
        id controller = DXQAApplicationController();
        if (!controller) {
            DXQAWriteStatus(@"failed", resolvedRequestID, @{@"error": @"SBApplicationController unavailable"});
            NSLog(@"[MUBX] quickactions: SBApplicationController unavailable");
            return;
        }

        NSMutableOrderedSet<NSString *> *requested = [NSMutableOrderedSet orderedSet];
        for (id value in bundleIdentifiers) {
            if (DXIsValidBundleIdentifier(value)) [requested addObject:value];
        }
        if (requested.count == 0) {
            [requested addObjectsFromArray:DXQABundleIdentifiersFromController(controller)];
        }
        if (requested.count == 0) {
            DXQAWriteStatus(@"failed", resolvedRequestID, @{@"error": @"No applications available"});
            return;
        }

        DXQAWriteStatus(@"building", resolvedRequestID, @{@"requestedApps": @(requested.count)});
        NSMutableDictionary<NSString *, NSDictionary *> *apps = [NSMutableDictionary dictionary];
        NSUInteger staticCount = 0;
        NSUInteger dynamicCount = 0;
        for (NSString *bundleIdentifier in requested) {
            @autoreleasepool {
                id application = DXQAApplication(controller, bundleIdentifier);
                if (!application) continue;
                NSArray *staticItems = DXQAStaticItems(application);
                NSArray *dynamicItems = DXQADynamicItems(application);
                staticCount += staticItems.count;
                dynamicCount += dynamicItems.count;
                NSArray *items = DXQADescriptors(application);
                if (items.count == 0) continue;
                NSString *name = DXQAReadString(application, @"displayName")
                    ?: DXQAReadString(application, @"applicationDisplayName")
                    ?: bundleIdentifier;
                apps[bundleIdentifier] = @{@"name": name, @"items": items};
            }
        }

        NSDictionary *snapshot = @{
            @"format": @3,
            @"generation": resolvedRequestID,
            @"updated": @([NSDate timeIntervalSinceReferenceDate]),
            @"apps": [apps copy],
        };
        NSDictionary *stats = @{
            @"requestedApps": @(requested.count),
            @"appsWithShortcuts": @(apps.count),
            @"staticItems": @(staticCount),
            @"dynamicItems": @(dynamicCount),
        };
        dispatch_async(DXQASnapshotWriterQueue(), ^{
            if (!DXSetQuickActionSharedValue(snapshot, MUBXQuickActionSnapshotKey)) {
                DXQAWriteStatus(@"failed", resolvedRequestID, @{@"error": @"Snapshot write failed"});
                NSLog(@"[MUBX] quickactions: failed to write snapshot %@", resolvedRequestID);
                return;
            }
            DXQAWriteStatus(@"complete", resolvedRequestID, stats);
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                 (__bridge CFStringRef)kShortcutSnapshotChangedIdentifier,
                                                 NULL, NULL, YES);
            NSLog(@"[MUBX] quickactions: snapshot %@ complete (%lu apps, %lu static, %lu dynamic)",
                  resolvedRequestID, (unsigned long)apps.count,
                  (unsigned long)staticCount, (unsigned long)dynamicCount);
        });
    });
}

// Synchronous dispatch on SpringBoard's main queue so the broker's freshness
// check covers the actual invocation. Success means dispatched, not app completion.
+ (DXSystemOpenResult)activateShortcutWithBundleIdentifier:(NSString *)bundleIdentifier
                                                    type:(NSString *)shortcutType {
    if (!NSThread.isMainThread || ![NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"]) {
        return DXSystemOpenUnavailable;
    }
    if (!DXIsValidBundleIdentifier(bundleIdentifier) || bundleIdentifier.length > 256 ||
        !DXIsValidAppShortcutType(shortcutType)) return DXSystemOpenInvalid;
    id application = DXQAApplication(DXQAApplicationController(), bundleIdentifier);
    id item = DXQACurrentItem(application, shortcutType);
    if (!item) {
        NSLog(@"[MUBXSB] quickaction current item missing bundleID=%@", bundleIdentifier);
        return DXSystemOpenFailed;
    }
    Class iconViewClass = NSClassFromString(@"SBIconView");
    SEL activate = NSSelectorFromString(@"activateShortcut:withBundleIdentifier:forIconView:");
    NSMethodSignature *signature = [iconViewClass methodSignatureForSelector:activate];
    if (![iconViewClass respondsToSelector:activate] || signature.numberOfArguments != 5 ||
        !signature.methodReturnType || strcmp(signature.methodReturnType, @encode(void)) != 0) {
        return DXSystemOpenUnavailable;
    }
    @try {
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(iconViewClass, activate, item, bundleIdentifier, nil);
        NSLog(@"[MUBXSB] quickaction dispatched bundleID=%@", bundleIdentifier);
        return DXSystemOpenSucceeded;
    } @catch (NSException *exception) {
        NSLog(@"[MUBXSB] quickaction exception=%@", exception.name);
        return DXSystemOpenFailed;
    }
}

@end
