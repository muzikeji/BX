#import <Preferences/PSViewController.h>
@class DXPAppShortcutItem;

@interface DXPAppShortcutPickerController : PSViewController
@property (nonatomic, copy) NSString *selectedBundleIdentifier;
@property (nonatomic, copy) NSString *selectedShortcutType;
@property (nonatomic, copy) void (^completion)(NSString *bundleIdentifier, NSString *appName, DXPAppShortcutItem *item);
@end
