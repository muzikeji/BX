#import "../DXPanelRegistry.h"
#import "DXPDockGestureController.h"
#import "DXPLinkActionEditorController.h"
#import "DXPGestureActionCell.h"
#import "../DXDockGesturePolicy.h"
#import "../DXHelper.h"
#import "../common.h"
#import <Preferences/PSSpecifier.h>

static NSString *DXDockLocalized(NSString *key) {
    return [[NSBundle bundleWithPath:bundlePath] localizedStringForKey:key value:key table:nil];
}
static BOOL DXDockSaveSelector(NSString *direction, NSString *selector) {
    if (!DXDockGestureEnabledKey(direction) || ![selector isKindOfClass:NSString.class]) return NO;
    DXPrefsManager *manager = DXPrefsManager.sharedInstance;
    NSMutableDictionary *preferences = [[manager readPrefs] mutableCopy];
    if (!preferences) return NO;
    id stored = preferences[kDXDockGestureBindings];
    NSMutableDictionary *bindings = [stored isKindOfClass:NSDictionary.class] ? [stored mutableCopy] : [NSMutableDictionary dictionary];
    bindings[direction] = selector;
    preferences[kDXDockGestureBindings] = bindings;
    [manager writePrefs:preferences];
    id saved = [manager readPrefs][kDXDockGestureBindings];
    BOOL success = [saved isKindOfClass:NSDictionary.class] && [saved[direction] isEqual:selector];
    NSLog(@"[MUBX][DockSettings] save direction=%@ success=%d", direction, success);
    return success;
}

@interface DXPDockActionPicker : PSListController
@property(nonatomic) BOOL selectAfterSave;
@end

@implementation DXPDockGestureController
- (void)viewDidLoad { [super viewDidLoad]; self.title = DXDockLocalized(@"DOCK_GESTURE_SETTINGS"); }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reloadSpecifiers]; }
- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *direction in DXDockGestureDirections()) {
        PSSpecifier *group = [PSSpecifier groupSpecifierWithName:nil];
        if ([direction isEqual:@"up"]) [group setProperty:DXDockLocalized(@"DOCK_GESTURE_FOOTER") forKey:@"footerText"];
        [items addObject:group];
        NSString *suffix = direction.uppercaseString;
        PSSpecifier *enabled = [PSSpecifier preferenceSpecifierNamed:DXDockLocalized([@"DOCK_ENABLE_" stringByAppendingString:suffix]) target:self
            set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:PSSwitchCell edit:nil];
        [enabled setProperty:direction forKey:@"dockDirection"];
        [enabled setProperty:@([direction isEqual:@"up"]) forKey:@"default"];
        [items addObject:enabled];
        PSSpecifier *action = [PSSpecifier preferenceSpecifierNamed:DXDockLocalized([@"DOCK_ACTION_" stringByAppendingString:suffix]) target:self
            set:nil get:@selector(readActionName:) detail:DXPDockActionPicker.class cell:PSLinkCell edit:nil];
        [action setProperty:direction forKey:@"dockDirection"];
        [items addObject:action];
    }
    _specifiers = items; return items;
}
- (id)readPreferenceValue:(PSSpecifier *)specifier {
    return @(DXDockGestureEnabled([[DXPrefsManager sharedInstance] readPrefs], [specifier propertyForKey:@"dockDirection"]));
}
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = DXDockGestureEnabledKey([specifier propertyForKey:@"dockDirection"]);
    if (key && [value isKindOfClass:NSNumber.class]) [[DXPrefsManager sharedInstance] setValue:@([value boolValue]) forKey:key];
}
- (id)readActionName:(PSSpecifier *)specifier {
    NSDictionary *preferences = [[DXPrefsManager sharedInstance] readPrefs];
    NSString *selector = DXDockGestureConfiguredSelector(preferences, [specifier propertyForKey:@"dockDirection"]);
    NSDictionary *panel = DXPanelDefinition(preferences, selector);
    if ([panel[@"kind"] isEqual:DXPanelGestureKind]) return DXPanelString(panel[@"name"]);
    NSDictionary *entry = DXDockGestureDefinition(preferences, selector, kLinkActionskey);
    if (!DXIsLinkActionSelector(selector) || !DXGlobalCustomActionSupported(entry)) return DXDockLocalized(@"DOCK_ACTION_NONE");
    NSString *name = DXGlobalPanelString(entry[@"name"]);
    return name.length ? name : DXDockLocalized(@"DEFAULT_BUTTON_NAME");
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *item = [self specifierAtIndexPath:indexPath];
    if (item.cellType == PSLinkCell && [item propertyForKey:@"dockDirection"])
        return DXPGestureActionCell(tableView, @"DXPDockActionRecord", item.name, [self readActionName:item], nil,
            UITableViewCellAccessoryDisclosureIndicator);
    return [super tableView:tableView cellForRowAtIndexPath:indexPath];
}
@end

@implementation DXPDockActionPicker
- (NSString *)direction { return [self.specifier propertyForKey:@"dockDirection"]; }
- (void)viewDidLoad { [super viewDidLoad]; self.title = DXDockLocalized(@"CHOOSE_ACTION"); }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reloadSpecifiers]; }
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.selectAfterSave) { self.selectAfterSave = NO; [self.navigationController popViewControllerAnimated:YES]; }
}
- (PSSpecifier *)action:(NSString *)name selector:(NSString *)selector {
    PSSpecifier *item = [PSSpecifier preferenceSpecifierNamed:name target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
    [item setProperty:selector forKey:@"actionSelector"];
    item->action = @selector(selectAction:);
    return item;
}
- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;
    NSMutableArray *items = [NSMutableArray array];
    [items addObject:[PSSpecifier groupSpecifierWithName:nil]];
    [items addObject:[self action:DXDockLocalized(@"DOCK_ACTION_NONE") selector:@""]];
    [items addObject:[PSSpecifier groupSpecifierWithName:DXDockLocalized(@"PANEL_KIND_GESTURE")]];
    for (NSDictionary *panel in DXPanelDefinitions([DXPrefsManager.sharedInstance readPrefs], DXPanelGestureKind))
        [items addObject:[self action:DXPanelString(panel[@"name"]) selector:DXPanelSelector(panel[@"id"])]];
    PSSpecifier *group = [PSSpecifier groupSpecifierWithName:DXDockLocalized(@"CUSTOM_ACTIONS")];
    [group setProperty:DXDockLocalized(@"DOCK_ACTION_PICKER_FOOTER") forKey:@"footerText"];
    [items addObject:group];
    id definitions = [[DXPrefsManager sharedInstance] readPrefs][kLinkActionskey];
    for (id entry in [definitions isKindOfClass:NSArray.class] ? definitions : @[]) {
        if (!DXGlobalCustomActionSupported(entry) || !DXIsLinkActionSelector(entry[@"selector"])) continue;
        NSString *name = DXGlobalPanelString(entry[@"name"]);
        PSSpecifier *item = [self action:name.length ? name : DXDockLocalized(@"DEFAULT_BUTTON_NAME") selector:entry[@"selector"]];
        [item setProperty:[DXHelper imageForIconConfig:entry[@"icon"] defaultSymbolName:@"link"] forKey:@"iconImage"];
        [items addObject:item];
    }
    PSSpecifier *add = [PSSpecifier preferenceSpecifierNamed:DXDockLocalized(@"ADD") target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
    add->action = @selector(addAction:); [items addObject:add];
    _specifiers = items; return items;
}
- (void)selectAction:(PSSpecifier *)specifier {
    NSString *selector = [specifier propertyForKey:@"actionSelector"];
    if (![selector isKindOfClass:NSString.class]) return;
    NSDictionary *entry = DXDockGestureDefinition([[DXPrefsManager sharedInstance] readPrefs], selector, kLinkActionskey);
    if (selector.length && !DXPanelAllowed([DXPrefsManager.sharedInstance readPrefs], selector, DXPanelGestureKind) && (!DXIsLinkActionSelector(selector) || !DXGlobalCustomActionSupported(entry))) {
        [self reloadSpecifiers]; return;
    }
    if (DXDockSaveSelector(self.direction, selector)) [self.navigationController popViewControllerAnimated:YES];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *item = [self specifierAtIndexPath:indexPath];
    if (item && (item->action == @selector(selectAction:) || item->action == @selector(addAction:))) {
        NSString *chosen = DXGlobalPanelString(DXDockGestureConfiguredSelector([DXPrefsManager.sharedInstance readPrefs], self.direction));
        BOOL checked = [chosen isEqual:[item propertyForKey:@"actionSelector"]];
        return DXPGestureActionCell(tableView, @"DXPDockActionChoice", item.name, nil, [item propertyForKey:@"iconImage"],
            checked ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone);
    }
    return [super tableView:tableView cellForRowAtIndexPath:indexPath];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *item = [self specifierAtIndexPath:indexPath];
    if (item && (item->action == @selector(selectAction:) || item->action == @selector(addAction:))) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        if (item->action == @selector(selectAction:)) [self selectAction:item]; else [self addAction:item];
        return;
    }
    [super tableView:tableView didSelectRowAtIndexPath:indexPath];
}
- (void)addAction:(PSSpecifier *)specifier {
    (void)specifier;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:DXDockLocalized(@"ADD") message:nil preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    for (NSString *type in @[kCustomActionTypeURLScheme, kCustomActionTypeOpenApp, kCustomActionTypeShortcut, kCustomActionTypeSystem])
        [alert addAction:[UIAlertAction actionWithTitle:[DXPLinkActionEditorController displayNameForType:type] style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) { [weakSelf addType:type]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:DXDockLocalized(@"ANSWER_CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)addType:(NSString *)type {
    DXPLinkActionEditorController *editor = [DXPLinkActionEditorController new];
    editor.entry = [@{@"selector": [kLinkActionSelectorPrefix stringByAppendingString:NSUUID.UUID.UUIDString],
        @"type": type, @"name": [DXPLinkActionEditorController displayNameForType:type],
        @"icon": [DXPLinkActionEditorController defaultIconForType:type], @"link": @""} mutableCopy];
    __weak typeof(self) weakSelf = self;
    __weak DXPLinkActionEditorController *weakEditor = editor;
    NSString *direction = [self.direction copy];
    __block BOOL completed = NO;
    editor.completion = ^(NSDictionary *entry) {
        DXPDockActionPicker *picker = weakSelf;
        if (completed || !picker || ![picker.direction isEqual:direction] || ![picker.navigationController.viewControllers containsObject:picker] ||
            picker.navigationController.topViewController != weakEditor || !DXDockGestureEnabledKey(direction)) return;
        DXPrefsManager *manager = DXPrefsManager.sharedInstance;
        NSMutableDictionary *preferences = [[manager readPrefs] mutableCopy];
        if (!preferences || ![entry isKindOfClass:NSDictionary.class] || !DXIsLinkActionSelector(entry[@"selector"])) return;
        id stored = preferences[kLinkActionskey];
        NSMutableArray *definitions = [stored isKindOfClass:NSArray.class] ? [stored mutableCopy] : [NSMutableArray array];
        [definitions addObject:entry]; preferences[kLinkActionskey] = definitions;
        completed = YES;
        [manager writePrefs:preferences];
        if (DXGlobalCustomActionSupported(DXDockGestureDefinition([manager readPrefs], entry[@"selector"], kLinkActionskey)))
            picker.selectAfterSave = DXDockSaveSelector(direction, entry[@"selector"]);
    };
    [editor setRootController:self.rootController]; [editor setParentController:self]; [self pushController:editor];
}
@end
