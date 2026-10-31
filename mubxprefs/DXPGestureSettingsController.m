#import "DXPGestureSettingsController.h"
#import "DXPStatusBarGestureController.h"
#import "DXPDockGestureController.h"
#import "../DXKeyboardPanelPreferences.h"
#import "../DXHelper.h"
#import "../common.h"
#import "DXPSubActionPickerController.h"
#import "DXPPanelActionCatalog.h"
#import "DXPGestureActionCell.h"
#import <Preferences/PSSpecifier.h>

static NSString *DXGestureLocalized(NSString *key) {
    return [[NSBundle bundleWithPath:bundlePath] localizedStringForKey:key value:key table:nil];
}

// Both the gesture list and its editor resolve the current saved binding.
static NSString *DXToolbarActionName(PSSpecifier *specifier) {
    NSDictionary *preferences = [DXPrefsManager.sharedInstance readPrefs];
    NSString *selector = DXToolbarAction(preferences, [specifier propertyForKey:@"toolbarConfiguration"],
        [specifier propertyForKey:@"toolbarDirection"]);
    NSDictionary *entry = selector.length ? DXPPanelDisplayDefinition(preferences, selector) : nil;
    if (!entry) return DXGestureLocalized(@"STATUS_BAR_UNASSIGNED");
    NSString *name = DXPanelString(entry[@"name"]);
    return name.length ? name : DXGestureLocalized(@"DEFAULT_BUTTON_NAME");
}

// The moved switches retain their original keys and defaults.
@interface DXPPanelGestureController : PSListController
- (PSSpecifier *)toggle:(NSString *)label key:(NSString *)key;
@end
@interface DXPKeyboardGestureController : DXPPanelGestureController
@end

@implementation DXPGestureSettingsController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = DXGestureLocalized(@"GESTURE_SETTINGS");
}
- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;
    NSMutableArray *items = [NSMutableArray array];
    for (NSArray *category in @[
        @[@"DOCK_GESTURE_SETTINGS", DXPDockGestureController.class, @"rectangle.bottomthird.inset.filled"],
        @[@"STATUS_BAR_SETTINGS", DXPStatusBarGestureController.class, @"arrow.up.square"],
        @[@"KEYBOARD_GESTURE_SETTINGS", DXPKeyboardGestureController.class, @"keyboard"]
    ]) {
        [items addObject:[PSSpecifier groupSpecifierWithName:nil]];
        PSSpecifier *link = [PSSpecifier preferenceSpecifierNamed:DXGestureLocalized(category[0]) target:self
            set:nil get:nil detail:category[1] cell:PSLinkCell edit:nil];
        [link setProperty:[DXHelper imageForIconConfig:category[2] defaultSymbolName:@"hand.draw"] forKey:@"iconImage"];
        [items addObject:link];
    }
    _specifiers = items;
    return _specifiers;
}
@end

@implementation DXPPanelGestureController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.specifier.name;
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadSpecifiers];
}
- (PSSpecifier *)toggle:(NSString *)label key:(NSString *)key {
    PSSpecifier *item = [PSSpecifier preferenceSpecifierNamed:DXGestureLocalized(label) target:self
        set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:PSSwitchCell edit:nil];
    [item setProperty:key forKey:@"key"];
    [item setProperty:@YES forKey:@"default"];
    return item;
}
- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSDictionary *preferences = [[DXPrefsManager sharedInstance] readPrefs];
    return @(DXKeyboardPanelBool(preferences, [specifier propertyForKey:@"key"], YES));
}
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (key.length && [value isKindOfClass:NSNumber.class])
        [[DXPrefsManager sharedInstance] setValue:@([value boolValue]) forKey:key];
}
@end

@interface DXPToolbarBindingController : PSListController
@end

@implementation DXPKeyboardGestureController
- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *configuration in @[@"top", @"bottom"]) {
        PSSpecifier *group = [PSSpecifier groupSpecifierWithName:DXGestureLocalized([configuration isEqual:@"top"] ? @"KEYBOARD_PANEL_TOP" : @"KEYBOARD_PANEL_BOTTOM")];
        [group setProperty:DXGestureLocalized(@"PANEL_TOOLBAR_FOOTER") forKey:@"footerText"]; [items addObject:group];
        [items addObject:[self toggle:@"ENABLED" key:[configuration isEqual:@"top"] ? kDXPanelTopEnabled : kDXPanelBottomEnabled]];
        for (NSString *direction in @[@"left", @"right"]) {
            PSSpecifier *link = [PSSpecifier preferenceSpecifierNamed:DXGestureLocalized([direction isEqual:@"left"] ? @"STATUS_BAR_LEFTSWIPE" : @"STATUS_BAR_RIGHTSWIPE") target:self set:nil get:@selector(readActionName:) detail:DXPToolbarBindingController.class cell:PSLinkCell edit:nil];
            [link setProperty:configuration forKey:@"toolbarConfiguration"]; [link setProperty:direction forKey:@"toolbarDirection"]; [items addObject:link];
        }
    }
    _specifiers = items;
    return _specifiers;
}
- (id)readActionName:(PSSpecifier *)specifier { return DXToolbarActionName(specifier); }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    PSSpecifier *item = [self specifierAtIndexPath:path];
    if (item.cellType == PSLinkCell && DXToolbarBindingSlot([item propertyForKey:@"toolbarConfiguration"], [item propertyForKey:@"toolbarDirection"]))
        return DXPGestureActionCell(tableView, @"DXPToolbarGestureRecord", item.name, [self readActionName:item], nil,
            UITableViewCellAccessoryDisclosureIndicator);
    return [super tableView:tableView cellForRowAtIndexPath:path];
}
@end

@implementation DXPToolbarBindingController
- (NSString *)slot { return DXToolbarBindingSlot([self.specifier propertyForKey:@"toolbarConfiguration"], [self.specifier propertyForKey:@"toolbarDirection"]); }
- (void)viewDidLoad { [super viewDidLoad]; self.title = self.specifier.name; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reloadSpecifiers]; }
- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;
    PSSpecifier *group = [PSSpecifier groupSpecifierWithName:nil];
    [group setProperty:DXGestureLocalized(@"PANEL_TOOLBAR_FOOTER") forKey:@"footerText"];
    PSSpecifier *choose = [PSSpecifier preferenceSpecifierNamed:DXGestureLocalized(@"CHOOSE_ACTION") target:self set:nil get:@selector(readActionName:) detail:nil cell:PSButtonCell edit:nil]; choose->action = @selector(chooseAction:);
    PSSpecifier *clear = [PSSpecifier preferenceSpecifierNamed:DXGestureLocalized(@"STATUS_BAR_CLEAR") target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil]; clear->action = @selector(clearAction:);
    _specifiers = [@[group, choose, clear] mutableCopy]; return _specifiers;
}
- (id)readActionName:(PSSpecifier *)specifier { (void)specifier; return DXToolbarActionName(self.specifier); }
- (BOOL)saveSelector:(NSString *)selector {
    NSString *slot = [self slot]; if (!slot || ![selector isKindOfClass:NSString.class]) return NO;
    DXPrefsManager *manager = DXPrefsManager.sharedInstance;
    NSMutableDictionary *preferences = [[manager readPrefs] mutableCopy];
    if (!preferences || (selector.length && !DXPanelItemAllowed(preferences, selector, DXPanelKeyboardKind))) return NO;
    id stored = preferences[kDXToolbarBindings];
    NSMutableDictionary *bindings = [stored isKindOfClass:NSDictionary.class] ? [stored mutableCopy] : [NSMutableDictionary dictionary];
    bindings[slot] = selector; preferences[kDXToolbarBindings] = bindings; [manager writePrefs:preferences];
    id latest = [manager readPrefs][kDXToolbarBindings];
    BOOL success = [latest isKindOfClass:NSDictionary.class] && [latest[slot] isEqual:selector];
    NSLog(@"[MUBX][ToolbarSettings] save slot=%@ assigned=%d success=%d", slot, selector.length > 0, success);
    [self reloadSpecifiers]; return success;
}
- (void)chooseAction:(PSSpecifier *)specifier {
    (void)specifier;
    DXPSubActionPickerController *picker = [DXPSubActionPickerController new];
    picker.actionContextKind = DXPanelKeyboardKind; picker.fullOrder = DXPPanelBuiltInActions(); picker.title = DXGestureLocalized(@"CHOOSE_ACTION");
    NSDictionary *preferences = [DXPrefsManager.sharedInstance readPrefs];
    picker.selectedSelector = DXToolbarAction(preferences, [self.specifier propertyForKey:@"toolbarConfiguration"], [self.specifier propertyForKey:@"toolbarDirection"]);
    __weak typeof(self) weakSelf = self;
    __weak DXPSubActionPickerController *weakPicker = picker;
    NSString *slot = [[self slot] copy];
    __block BOOL completed = NO;
    picker.completion = ^(NSString *selector) {
        DXPToolbarBindingController *owner = weakSelf;
        if (completed || !owner || ![slot isEqual:[owner slot]] ||
            ![owner.navigationController.viewControllers containsObject:owner] || owner.navigationController.topViewController != weakPicker) return;
        completed = [owner saveSelector:selector];
    };
    [picker setRootController:self.rootController]; [picker setParentController:self]; [self pushController:picker];
}
- (void)clearAction:(PSSpecifier *)specifier { (void)specifier; [self saveSelector:@""]; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    PSSpecifier *item = [self specifierAtIndexPath:path];
    if (item && item->action == @selector(chooseAction:)) {
        return DXPGestureActionCell(tableView, @"DXPToolbarActionRecord", item.name, [self readActionName:item], nil,
            UITableViewCellAccessoryDisclosureIndicator);
    }
    return [super tableView:tableView cellForRowAtIndexPath:path];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    PSSpecifier *item = [self specifierAtIndexPath:path];
    if (item && (item->action == @selector(chooseAction:) || item->action == @selector(clearAction:))) {
        [tableView deselectRowAtIndexPath:path animated:YES];
        if (item && item->action == @selector(chooseAction:)) [self chooseAction:item]; else [self clearAction:item]; return;
    }
    [super tableView:tableView didSelectRowAtIndexPath:path];
}
@end
