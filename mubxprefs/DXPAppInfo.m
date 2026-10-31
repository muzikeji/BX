#import "DXPAppInfo.h"
#import "../common.h"
#import <dlfcn.h>
#import <objc/message.h>
#import "AltList/CoreServices.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

@interface UIImage (MUBXAppIcon)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier format:(NSInteger)format;
@end

#pragma clang diagnostic pop

@implementation DXPAppShortcutItem
@end

@implementation DXPAppInfo

+ (void)ensureLaunchServicesLoaded {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Settings on iOS 17 normally has LaunchServices loaded already;
        // iOS 16 does not. Keep both framework locations for compatibility.
        for (NSString *path in @[
            @"/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",
            @"/System/Library/Frameworks/CoreServices.framework/CoreServices",
        ]) {
            if (dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL)) break;
        }
    });
}

// Direct LaunchServices resolution — no enumeration involved, so the result
// does not depend on any list filtering (a configured app that AltList hides
// still renders with its real name in the editor).
+ (NSString *)displayNameForBundleID:(NSString *)bundleID {
    if (bundleID.length == 0) return nil;
    [self ensureLaunchServicesLoaded];
    @try {
        Class proxyClass = NSClassFromString(@"LSApplicationProxy");
        if (!proxyClass) return nil;
        LSApplicationProxy *proxy = [proxyClass applicationProxyForIdentifier:bundleID];
        NSString *name = proxy.localizedName;
        return name.length > 0 ? name : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

// SpringBoard replaces the entire format-3 snapshot after reading each
// SBApplication's current dynamic and static items. Settings only decodes the
// stable display fields; execution resolves the original item again.
+ (NSArray<NSDictionary *> *)appShortcutGroups {
    @try {
        NSDictionary *root = DXQuickActionSharedValue(MUBXQuickActionSnapshotKey);
        if (![root[@"format"] isKindOfClass:[NSNumber class]] || [root[@"format"] integerValue] != 3) {
            return @[];
        }
        NSDictionary *apps = [root[@"apps"] isKindOfClass:[NSDictionary class]] ? root[@"apps"] : nil;
        if (apps.count == 0) return @[];

        NSMutableArray<NSDictionary *> *groups = [NSMutableArray array];
        for (NSString *bundleID in apps) {
            if (!DXIsValidBundleIdentifier(bundleID) || bundleID.length > 256) continue;
            NSDictionary *entry = [apps[bundleID] isKindOfClass:[NSDictionary class]] ? apps[bundleID] : nil;
            NSArray *rawItems = [entry[@"items"] isKindOfClass:[NSArray class]] ? entry[@"items"] : nil;
            if (rawItems.count == 0) continue;

            NSMutableArray<DXPAppShortcutItem *> *items = [NSMutableArray array];
            NSMutableSet<NSString *> *seenTypes = [NSMutableSet set];
            for (NSDictionary *raw in rawItems) {
                if (![raw isKindOfClass:[NSDictionary class]]) continue;
                NSString *type = [raw[@"type"] isKindOfClass:[NSString class]] ? raw[@"type"] : nil;
                if (!DXIsValidAppShortcutType(type) || [seenTypes containsObject:type]) continue;
                [seenTypes addObject:type];

                DXPAppShortcutItem *item = [[DXPAppShortcutItem alloc] init];
                item.type = type;
                NSString *title = [raw[@"title"] isKindOfClass:[NSString class]] ? raw[@"title"] : nil;
                item.title = title.length ? title : type;
                item.subtitle = [raw[@"subtitle"] isKindOfClass:[NSString class]] ? raw[@"subtitle"] : nil;
                NSString *source = [raw[@"source"] isKindOfClass:[NSString class]] ? raw[@"source"] : nil;
                item.source = [source isEqualToString:@"dynamic"]
                    ? DXPAppShortcutSourceDynamic : DXPAppShortcutSourceStatic;
                [items addObject:item];
            }
            if (items.count == 0) continue;

            NSString *entryName = [entry[@"name"] isKindOfClass:[NSString class]] ? entry[@"name"] : nil;
            NSString *name = entryName.length > 0 ? entryName : bundleID;
            [groups addObject:@{@"name": name, @"bundleID": bundleID, @"items": items}];
        }
        [groups sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
            return [left[@"name"] localizedStandardCompare:right[@"name"]];
        }];
        NSLog(@"[MUBX] shortcuts: %ld groups from the shared catalogue", (long)groups.count);
        return groups;
    } @catch (NSException *exception) {
        NSLog(@"[MUBX] shortcuts: shared catalogue unreadable (%@)", exception);
        return @[];
    }
}

+ (BOOL)requestShortcutSnapshotRefresh {
    [self ensureLaunchServicesLoaded];
    NSMutableOrderedSet<NSString *> *identifiers = [NSMutableOrderedSet orderedSet];
    @try {
        Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        LSApplicationWorkspace *workspace = [workspaceClass respondsToSelector:@selector(defaultWorkspace)]
            ? [workspaceClass defaultWorkspace] : nil;
        void (^collect)(LSApplicationProxy *) = ^(LSApplicationProxy *proxy) {
            if (![proxy respondsToSelector:@selector(applicationIdentifier)]) return;
            NSString *identifier = proxy.applicationIdentifier;
            if (DXIsValidBundleIdentifier(identifier) && identifiers.count < 2048) [identifiers addObject:identifier];
        };
        if ([workspace respondsToSelector:@selector(enumerateApplicationsOfType:block:)]) {
            [workspace enumerateApplicationsOfType:0 block:collect];
            [workspace enumerateApplicationsOfType:1 block:collect];
        } else if ([workspace respondsToSelector:@selector(allApplications)]) {
            for (LSApplicationProxy *proxy in [workspace allApplications]) collect(proxy);
        }
    } @catch (NSException *exception) {
        NSLog(@"[MUBX] quickaction catalogue enumeration exception=%@", exception.name);
    }
    // An empty list asks the existing provider to use SpringBoard's registry.
    NSDictionary *request = @{@"requestID": NSUUID.UUID.UUIDString, @"bundles": identifiers.array};
    if (!DXSetQuickActionSharedValue(request, MUBXQuickActionRequestKey)) return NO;
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)kShortcutRefreshRequestIdentifier, NULL, NULL, YES);
    return YES;
}

+ (UIImage *)iconForBundleID:(NSString *)bundleID {
    static NSCache *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 512;
    });
    if (bundleID.length == 0) return [UIImage systemImageNamed:@"app"];
    UIImage *cached = [cache objectForKey:bundleID];
    if (cached) return cached;

    CGFloat side = 44;
    UIImage *base = nil;
    if ([UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:)]) {
        base = [UIImage _applicationIconImageForBundleIdentifier:bundleID format:2];
        if (!base) base = [UIImage _applicationIconImageForBundleIdentifier:bundleID format:0];
    }

    UIImage *icon;
    if (base) {
        UIGraphicsImageRendererFormat *format = [[UIGraphicsImageRendererFormat alloc] init];
        format.scale = [UIScreen mainScreen].scale;
        format.opaque = NO;
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:format];
        icon = [renderer imageWithActions:^(UIGraphicsImageRendererContext *rendererContext) {
            // Home-screen icons are square; round them like SpringBoard does.
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, side, side)
                                        cornerRadius:side * 0.225] addClip];
            [base drawInRect:CGRectMake(0, 0, side, side)];
        }];
    } else {
        icon = [UIImage systemImageNamed:@"app"];
    }
    if (icon) [cache setObject:icon forKey:bundleID];
    return icon;
}

@end
