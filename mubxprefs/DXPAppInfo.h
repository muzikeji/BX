#import <UIKit/UIKit.h>

// The authoritative SBApplication collection that supplied the item.
typedef NS_ENUM(NSInteger, DXPAppShortcutSource) {
    DXPAppShortcutSourceStatic = 0,
    DXPAppShortcutSourceDynamic,
};

// One home-screen quick action (a row of the menu shown when long-pressing an
// app icon). `type` is the stable identifier the system dispatches back to the
// app. The persistent selection is bundleID + type; SpringBoard re-resolves
// the current object at execution time so userInfo remains current.
@interface DXPAppShortcutItem : NSObject
@property (nonatomic, copy) NSString *type;
@property (nonatomic, copy) NSString *title;    // localized
@property (nonatomic, copy) NSString *subtitle; // localized or nil
@property (nonatomic, assign) DXPAppShortcutSource source;
@end

// Value object and lookups for the custom-action editor: the bundleID/name
// pairs handed back by the AltList app pickers (生效应用 multi-select page,
// 打开应用 single-select picker), each app's static/dynamic home-screen quick
// actions, and display-name/icon resolution for an already-configured bundle
// identifier. Application enumeration itself lives in the vendored AltList
// controllers; SpringBoard resolves the actual shortcut items and replaces one
// complete shared snapshot.
@interface DXPAppInfo : NSObject
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *name;

// Localized display name for a bundle identifier via LaunchServices; nil when
// LaunchServices is unavailable (callers fall back to the raw identifier).
// Works for filtered/unlisted apps too: it never enumerates, it resolves
// directly.
+ (NSString *)displayNameForBundleID:(NSString *)bundleID;

// Apps that declare at least one quick action. Each entry is
// @{@"name": NSString, @"bundleID": NSString, @"items": NSArray<DXPAppShortcutItem *>}
// sorted by localized name, read from the format-3 SpringBoard snapshot.
// Never throws and never returns nil.
+ (NSArray<NSDictionary *> *)appShortcutGroups;

// Call off the main thread. Enumerates bundle IDs and asks SpringBoard to
// replace the shared catalogue; the snapshot-change notification follows.
+ (BOOL)requestShortcutSnapshotRefresh;

// 44x44 rounded home-screen icon for a bundle identifier; falls back to a
// generic symbol when the private icon service returns nothing.
+ (UIImage *)iconForBundleID:(NSString *)bundleID;
@end
