#import "DXPKeyboardPanelController.h"
#import "DXPSubActionPickerController.h"
#import "DXPKeyboardPanelPreviewHeader.h"
#import "DXPPanelSliderCell.h"
#import "DXPLinkActionEditorController.h"
#import "DXPPanelActionCatalog.h"
#import "../DXKeyboardPanelPreferences.h"
#import "../DXHelper.h"
#import "../common.h"
#import <Preferences/PSSpecifier.h>

static NSString *DXPanelLocalized(NSString *key) {
    return [[NSBundle bundleWithPath:bundlePath] localizedStringForKey:key value:key table:nil];
}

// Keyboard context shows every action; gesture context excludes keyboard
// operations. Both offer same-type panels and custom-action creation.
@interface DXPKeyboardPanelActionPicker : DXPSubActionPickerController
@end
@implementation DXPKeyboardPanelActionPicker
- (void)viewDidLoad {
    self.allowsDeletingCustomActions = YES;
    [super viewDidLoad];
}
- (BOOL)showsBuiltInActionsSection { return ![self.actionContextKind isEqual:DXPanelGestureKind]; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return DXPanelLocalized(@"KEYBOARD_PANEL_PICKER_DELETE_FOOTER");
}
@end

@interface DXPKeyboardPanelController ()
@property(nonatomic, strong) DXPKeyboardPanelPreviewHeader *previewHeader;
@property(nonatomic, strong) UISearchController *keyboardTestSearch;
- (NSString *)panelSelector;
@end
@implementation DXPKeyboardPanelController
- (NSString *)panelSelector { return [self.specifier propertyForKey:@"panelSelector"]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    NSString *selector = [self panelSelector];
    self.title = selector ? DXPanelString(DXPanelDefinition([DXPrefsManager.sharedInstance readPrefs], selector)[@"name"]) : DXPanelLocalized(@"KEYBOARD_PANEL_SETTINGS");
    if (selector) {
        self.previewHeader = [[DXPKeyboardPanelPreviewHeader alloc] initWithPanelSelector:selector];
        self.previewHeader.frame = CGRectMake(0, 0, self.table.bounds.size.width, self.previewHeader.bounds.size.height);
        self.table.tableHeaderView = self.previewHeader;
        if (DXPanelAllowed([DXPrefsManager.sharedInstance readPrefs], selector, DXPanelKeyboardKind)) {
            self.keyboardTestSearch = [[UISearchController alloc] initWithSearchResultsController:nil];
            self.keyboardTestSearch.obscuresBackgroundDuringPresentation = NO;
            self.keyboardTestSearch.hidesNavigationBarDuringPresentation = NO;
            self.keyboardTestSearch.searchBar.placeholder = DXPanelLocalized(@"PANEL_KEYBOARD_TEST");
            self.navigationItem.searchController = self.keyboardTestSearch;
            self.definesPresentationContext = YES;
        }
    } else {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addPanel)];
    }
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reloadSpecifiers]; [self.previewHeader refresh]; }
- (void)viewWillDisappear:(BOOL)animated {
    self.keyboardTestSearch.active = NO; [self.view endEditing:YES]; [super viewWillDisappear:animated];
}
- (CGFloat)tableView:(UITableView *)table heightForRowAtIndexPath:(NSIndexPath *)path {
    if ([[self specifierAtIndexPath:path] propertyForKey:@"cellClass"] == DXPPanelSliderCell.class) return 80;
    return [super tableView:table heightForRowAtIndexPath:path];
}
- (PSSpecifier *)setting:(NSString *)label key:(NSString *)key defaultValue:(id)value cell:(PSCellType)cell {
    PSSpecifier *item = [PSSpecifier preferenceSpecifierNamed:DXPanelLocalized(label) target:self set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:cell edit:nil];
    [item setProperty:key forKey:@"key"]; [item setProperty:value forKey:@"default"];
    return item;
}
- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;
    NSMutableArray *items = [NSMutableArray array];
    NSString *selector = [self panelSelector];
    NSDictionary *preferences = [DXPrefsManager.sharedInstance readPrefs];
    if (!selector) {
        PSSpecifier *group = [PSSpecifier groupSpecifierWithName:DXPanelLocalized(@"PANEL_SETTINGS")];
        [group setProperty:DXPanelLocalized(@"PANEL_TYPES_FOOTER") forKey:@"footerText"]; [items addObject:group];
        [items addObject:[self setting:@"GLOBAL_PANEL_ENABLED" key:kDXPanelGlobalEnabled defaultValue:@YES cell:PSSwitchCell]];
        for (NSString *kind in @[DXPanelKeyboardKind, DXPanelGestureKind]) {
            [items addObject:[PSSpecifier groupSpecifierWithName:DXPanelLocalized([kind isEqual:DXPanelKeyboardKind] ? @"PANEL_KIND_KEYBOARD" : @"PANEL_KIND_GESTURE")]];
            for (NSDictionary *panel in DXPanelDefinitions(preferences, kind)) {
                PSSpecifier *link = [PSSpecifier preferenceSpecifierNamed:DXPanelString(panel[@"name"]) target:self set:nil get:nil detail:DXPKeyboardPanelController.class cell:PSLinkCell edit:nil];
                [link setProperty:DXPanelSelector(panel[@"id"]) forKey:@"panelSelector"];
                [link setProperty:[DXHelper imageForIconConfig:DXPanelDefaultIconName(panel[@"kind"]) defaultSymbolName:@"square.grid.2x2"] forKey:@"iconImage"];
                [items addObject:link];
            }
        }
        _specifiers = items; return items;
    }
    NSDictionary *panel = DXPanelDefinition(preferences, selector);
    if (!panel) { _specifiers = items; return items; }
    PSSpecifier *group = [PSSpecifier groupSpecifierWithName:DXPanelLocalized([panel[@"kind"] isEqual:DXPanelKeyboardKind] ? @"PANEL_KIND_KEYBOARD" : @"PANEL_KIND_GESTURE")];
    [group setProperty:DXPanelLocalized([panel[@"kind"] isEqual:DXPanelKeyboardKind] ? @"PANEL_KEYBOARD_FOOTER" : @"PANEL_GESTURE_FOOTER") forKey:@"footerText"];
    [items addObject:group];
    [items addObject:[self setting:@"PANEL_NAME" key:@"name" defaultValue:@"" cell:PSEditTextCell]];
    [items addObject:[self setting:@"KEYBOARD_PANEL_SYSTEM_TOGGLES" key:kDXPanelSystemTogglesVisible defaultValue:@YES cell:PSSwitchCell]];
    [items addObject:[self setting:@"KEYBOARD_PANEL_SYSTEM_SLIDERS" key:kDXPanelSystemSlidersVisible defaultValue:@YES cell:PSSwitchCell]];
    PSSpecifier *actions = [PSSpecifier preferenceSpecifierNamed:DXPanelLocalized(@"KEYBOARD_PANEL_ACTIONS") target:self set:nil get:nil detail:DXPKeyboardPanelItemsController.class cell:PSLinkCell edit:nil];
    [actions setProperty:selector forKey:@"panelSelector"]; [items addObject:actions];
    [items addObject:[PSSpecifier groupSpecifierWithName:DXPanelLocalized(@"KEYBOARD_PANEL_APPEARANCE")]];
    [items addObject:[self setting:@"KEYBOARD_PANEL_DARK" key:kDXPanelDark defaultValue:@YES cell:PSSwitchCell]];
    for (NSArray *row in @[@[@"KEYBOARD_PANEL_COLUMNS", kDXPanelColumns, @4, @3, @5], @[@"KEYBOARD_PANEL_SCALE", kDXPanelScale, @100, @70, @120]]) {
        PSSpecifier *slider = [self setting:row[0] key:row[1] defaultValue:row[2] cell:PSStaticTextCell];
        [slider setProperty:DXPPanelSliderCell.class forKey:@"cellClass"]; [slider setProperty:row[3] forKey:@"min"]; [slider setProperty:row[4] forKey:@"max"];
        [slider setProperty:@YES forKey:@"showValue"]; [items addObject:slider];
    }
    _specifiers = items; return items;
}
- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSDictionary *preferences = [DXPrefsManager.sharedInstance readPrefs];
    NSString *key = [specifier propertyForKey:@"key"], *selector = [self panelSelector];
    if (!selector) return preferences[key] ?: [specifier propertyForKey:@"default"];
    NSDictionary *panel = DXPanelDefinition(preferences, selector);
    return ([key isEqual:@"name"] ? panel[key] : DXPanelPreferences(preferences, selector)[key]) ?: [specifier propertyForKey:@"default"];
}
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"], *selector = [self panelSelector];
    if (!key.length || !value) return;
    if (!selector) { [DXPrefsManager.sharedInstance setValue:value forKey:key]; return; }
    NSMutableDictionary *preferences = [[DXPrefsManager.sharedInstance readPrefs] mutableCopy];
    if (!DXPanelDefinition(preferences, selector)) return;
    if ([key isEqual:@"name"]) {
        value = [DXPanelString(value) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (![value length]) return;
        DXPanelUpdate(preferences, selector, @{key: value});
    } else {
        if ([key isEqual:kDXPanelColumns]) value = @(MIN(5, MAX(3, lround([value doubleValue]))));
        if ([key isEqual:kDXPanelScale]) value = @(MIN(120, MAX(70, lround([value doubleValue] / 5) * 5)));
        id stored = DXPanelDefinition(preferences, selector)[@"preferences"];
        NSMutableDictionary *options = [stored isKindOfClass:NSDictionary.class] ? [stored mutableCopy] : [NSMutableDictionary dictionary];
        options[key] = value; DXPanelUpdate(preferences, selector, @{@"preferences": options});
    }
    [DXPrefsManager.sharedInstance writePrefs:preferences];
    self.title = DXPanelString(DXPanelDefinition(preferences, selector)[@"name"]); [self.previewHeader refresh];
}
- (void)addPanel {
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:DXPanelLocalized(@"PANEL_ADD") message:nil preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    for (NSString *kind in @[DXPanelKeyboardKind, DXPanelGestureKind])
        [menu addAction:[UIAlertAction actionWithTitle:DXPanelLocalized([kind isEqual:DXPanelKeyboardKind] ? @"PANEL_KIND_KEYBOARD" : @"PANEL_KIND_GESTURE") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [weakSelf addPanelOfKind:kind]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:DXPanelLocalized(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:menu animated:YES completion:nil];
}
- (void)addPanelOfKind:(NSString *)kind {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:DXPanelLocalized(@"PANEL_ADD") message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = DXPanelLocalized(@"PANEL_NAME"); }];
    __weak typeof(self) weakSelf = self;
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:DXPanelLocalized(@"KEYBOARD_PANEL_SAVE") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !DXPanelKindValid(kind) || self.navigationController.topViewController != self) return;
        NSMutableDictionary *preferences = [[DXPrefsManager.sharedInstance readPrefs] mutableCopy];
        NSMutableArray *panels = [DXPanelDefinitions(preferences, nil) mutableCopy];
        NSString *name = [weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!name.length) name = DXPanelLocalized([kind isEqual:DXPanelKeyboardKind] ? @"PANEL_KIND_KEYBOARD" : @"PANEL_KIND_GESTURE");
        NSDictionary *panel = @{@"id": NSUUID.UUID.UUIDString, @"kind": kind, @"name": name, @"icon": DXPanelDefaultIconName(kind), @"items": @[], @"preferences": @{}};
        [panels addObject:panel]; preferences[kDXPanels] = panels;
        [DXPrefsManager.sharedInstance writePrefs:preferences]; [self reloadSpecifiers];
        DXPKeyboardPanelController *editor = [DXPKeyboardPanelController new];
        PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:name target:nil set:nil get:nil detail:nil cell:PSLinkCell edit:nil];
        [specifier setProperty:DXPanelSelector(panel[@"id"]) forKey:@"panelSelector"]; editor.specifier = specifier;
        [editor setRootController:self.rootController]; [editor setParentController:self]; [self pushController:editor];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:DXPanelLocalized(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)path {
    (void)tableView; return ![self panelSelector] && [[self specifierAtIndexPath:path] propertyForKey:@"panelSelector"] != nil;
}
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)path {
    (void)tableView;
    if (style == UITableViewCellEditingStyleDelete) [self deletePanelSelector:[[self specifierAtIndexPath:path] propertyForKey:@"panelSelector"]];
}
- (BOOL)deletePanelSelector:(NSString *)selector {
    if (!selector || [self panelSelector]) return NO;
    NSMutableDictionary *preferences = [[DXPrefsManager.sharedInstance readPrefs] mutableCopy];
    NSDictionary *panel = DXPanelDefinition(preferences, selector);
    if (!panel) return NO;
    NSMutableArray *panels = [DXPanelDefinitions(preferences, nil) mutableCopy]; [panels removeObject:panel]; preferences[kDXPanels] = panels;
    [[DXPCustomActionViewController new] removeReferencesToSelector:selector fromPreferences:preferences];
    [DXPrefsManager.sharedInstance writePrefs:preferences]; [self reloadSpecifiers]; return YES;
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)path {
    if (![self tableView:tableView canEditRowAtIndexPath:path]) return nil;
    NSString *selector = [[self specifierAtIndexPath:path] propertyForKey:@"panelSelector"];
    __weak typeof(self) weakSelf = self;
    UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:DXPanelLocalized(@"DELETE") handler:^(__unused UIContextualAction *action, __unused UIView *view, void (^completion)(BOOL)) { completion([weakSelf deletePanelSelector:selector]); }];
    UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[remove]];
    configuration.performsFirstActionWithFullSwipe = NO; return configuration;
}
@end
// 面板条目只编辑名称，图标跟随引用的动作或面板。
@interface DXPPanelItemAppearanceController : PSViewController <UITableViewDataSource, UITableViewDelegate>
@property(nonatomic, copy) NSDictionary *entry;
@property(nonatomic, strong) UITextField *nameField;
@property(nonatomic, copy) void (^completion)(NSDictionary *updatedEntry);
@end

@implementation DXPPanelItemAppearanceController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = DXPanelLocalized(@"KEYBOARD_PANEL_ITEM_APPEARANCE");
    self.nameField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 180, 36)];
    self.nameField.textAlignment = NSTextAlignmentRight;
    self.nameField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.nameField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.nameField.placeholder = DXPanelLocalized(@"KEYBOARD_PANEL_NAME");
    self.nameField.text = [self.entry[@"name"] isKindOfClass:NSString.class] ? self.entry[@"name"] : @"";

    UITableView *table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    table.dataSource = self;
    table.delegate = self;
    self.view = table;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:DXPanelLocalized(@"KEYBOARD_PANEL_SAVE")
        style:UIBarButtonItemStyleDone target:self action:@selector(saveTapped)];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"PanelAppearanceCell"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"PanelAppearanceCell"];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    (void)indexPath;
    cell.textLabel.text = DXPanelLocalized(@"KEYBOARD_PANEL_NAME");
    cell.textLabel.font = [UIFont systemFontOfSize:16];
    cell.imageView.image = nil;
    cell.accessoryView = self.nameField;
    return cell;
}

- (void)saveTapped {
    [self.view endEditing:YES];
    NSMutableDictionary *updated = [self.entry mutableCopy] ?: [NSMutableDictionary dictionary];
    updated[@"name"] = [self.nameField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    [updated removeObjectForKey:@"icon"];
    if (self.completion) self.completion(updated);
    [self.navigationController popViewControllerAnimated:YES];
}
@end

@interface DXPKeyboardPanelItemsController () <UITableViewDragDelegate, UITableViewDropDelegate>
@property(nonatomic, strong) UITableView *table;
@property(nonatomic, strong) DXPKeyboardPanelPreviewHeader *previewHeader;
@property(nonatomic, copy) NSString *panelSelector;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *entries;
@end

@implementation DXPKeyboardPanelItemsController
- (NSMutableArray *)configuredEntries {
    NSDictionary *preferences = [[DXPrefsManager sharedInstance] readPrefs];
    return [DXPanelItems(preferences, self.panelSelector) mutableCopy];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.panelSelector = [self.specifier propertyForKey:@"panelSelector"];
    self.title = self.specifier.name;
    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.delegate = self;
    self.table.dataSource = self;
    [self.view addSubview:self.table];
    self.previewHeader = [[DXPKeyboardPanelPreviewHeader alloc] initWithPanelSelector:self.panelSelector];
    self.previewHeader.frame = CGRectMake(0, 0, self.table.bounds.size.width, self.previewHeader.bounds.size.height);
    self.table.tableHeaderView = self.previewHeader;
    UIBarButtonItem *addButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addActions)];
    self.navigationItem.rightBarButtonItem = addButton;
    self.entries = [self configuredEntries];
    // 排序不设编辑模式：长按直接拖动（drag & drop），左滑删除照旧。
    self.table.dragInteractionEnabled = YES;
    self.table.dragDelegate = self;
    self.table.dropDelegate = self;
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.entries = [self configuredEntries];
    [self.previewHeader refresh];
    [self.table reloadData];
}
- (void)save {
    NSMutableDictionary *preferences = [[DXPrefsManager.sharedInstance readPrefs] mutableCopy];
    if (!DXPanelDefinition(preferences, self.panelSelector)) return;
    DXPanelUpdate(preferences, self.panelSelector, @{@"items": [self.entries copy]});
    [DXPrefsManager.sharedInstance writePrefs:preferences];
    [self.previewHeader refresh];
}
- (NSDictionary *)definitionForSelector:(NSString *)selector {
    NSDictionary *preferences = [DXPrefsManager.sharedInstance readPrefs];
    return DXPPanelDisplayDefinition(preferences, selector);
}
- (NSDictionary *)customDefinitionForSelector:(NSString *)selector {
    id stored = [[DXPrefsManager sharedInstance] readPrefs][kLinkActionskey];
    if (![stored isKindOfClass:NSArray.class]) return nil;
    for (id entry in stored) if ([entry isKindOfClass:NSDictionary.class] && [entry[@"selector"] isEqual:selector]) return entry;
    return nil;
}
- (NSString *)nameForEntry:(NSDictionary *)entry {
    NSString *name = entry[@"name"];
    if (name.length) return name;
    name = [self definitionForSelector:entry[@"selector"]][@"name"];
    return name.length ? name : [DXHelper localizedStringForActionNamed:entry[@"selector"] shortName:NO bundle:[NSBundle bundleWithPath:bundlePath]];
}
- (UIImage *)imageForEntry:(NSDictionary *)entry {
    NSString *icon = [self definitionForSelector:entry[@"selector"]][@"icon"];
    if (icon.length) return [DXHelper imageForIconConfig:icon defaultSymbolName:@"link"];
    return [UIImage systemImageNamed:@"square.grid.2x2"];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return self.entries.count;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return DXPanelLocalized(@"KEYBOARD_PANEL_ITEMS_FOOTER");
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"PanelItem"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"PanelItem"];
    NSDictionary *entry = self.entries[indexPath.row];
    cell.textLabel.text = [self nameForEntry:entry];
    cell.imageView.image = [self imageForEntry:entry];
    // 行尾固定拖动把手，让可拖动性可见；拖动本身仍由表格的长按 drag & drop 承担。
    UIImageView *handle = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"line.3.horizontal"]];
    handle.contentMode = UIViewContentModeScaleAspectFit;
    handle.tintColor = UIColor.secondaryLabelColor;
    handle.frame = CGRectMake(0, 0, 24, 24);
    cell.accessoryView = handle;
    return cell;
}
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete || indexPath.section != 0 || indexPath.row < 0 || indexPath.row >= (NSInteger)self.entries.count) return;
    [self removeEntry:self.entries[indexPath.row] fromTable:tableView];
}
- (BOOL)removeEntry:(NSDictionary *)entry fromTable:(UITableView *)tableView {
    // Resolve the captured item again, so a stale swipe cannot delete a different
    // item after reload/reorder. Delete only this panel's reference, not its definition.
    NSUInteger row = [self.entries indexOfObjectIdenticalTo:entry];
    if (row == NSNotFound) return NO;
    [self.entries removeObjectAtIndex:row];
    [self save];
    [tableView deleteRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:row inSection:0]] withRowAnimation:UITableViewRowAnimationAutomatic];
    return YES;
}
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    return indexPath.section == 0 && indexPath.row >= 0 && indexPath.row < (NSInteger)self.entries.count;
}
- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; (void)indexPath;
    return UITableViewCellEditingStyleDelete;
}
- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; (void)indexPath;
    return DXPanelLocalized(@"DELETE");
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != 0 || indexPath.row < 0 || indexPath.row >= (NSInteger)self.entries.count) return nil;
    NSDictionary *entry = self.entries[indexPath.row];
    __weak typeof(self) weakSelf = self;
    __weak UITableView *weakTable = tableView;
    UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:DXPanelLocalized(@"DELETE") handler:^(__unused UIContextualAction *action, __unused UIView *view, void (^completion)(BOOL)) {
            __strong typeof(weakSelf) self = weakSelf;
            UITableView *table = weakTable;
            completion(self && table && [self removeEntry:entry fromTable:table]);
        }];
    UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[remove]];
    configuration.performsFirstActionWithFullSwipe = NO;
    return configuration;
}
// 长按拖动排序：本地拖动会话由表格跟踪落点间隙，落点即最终数组位置，
// 数据源更新与 moveRow 动画在同一 beginUpdates 里提交。
- (NSArray<UIDragItem *> *)tableView:(UITableView *)tableView itemsForBeginningDragSession:(id<UIDragSession>)session atIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; (void)session;
    if (indexPath.section != 0 || indexPath.row < 0 || indexPath.row >= (NSInteger)self.entries.count) return @[];
    NSDictionary *entry = self.entries[indexPath.row];
    UIDragItem *item = [[UIDragItem alloc] initWithItemProvider:[[NSItemProvider alloc] initWithObject:entry[@"id"] ?: @""]];
    item.localObject = entry;
    return @[item];
}

- (UITableViewDropProposal *)tableView:(UITableView *)tableView dropSessionDidUpdate:(id<UIDropSession>)session withDestinationIndexPath:(NSIndexPath *)destinationIndexPath {
    (void)tableView; (void)destinationIndexPath;
    if (!session.localDragSession) return nil;
    return [[UITableViewDropProposal alloc] initWithDropOperation:UIDropOperationMove
        intent:UITableViewDropIntentInsertAtDestinationIndexPath];
}

- (void)tableView:(UITableView *)tableView performDropWithCoordinator:(id<UITableViewDropCoordinator>)coordinator {
    NSIndexPath *destination = coordinator.destinationIndexPath;
    id<UITableViewDropItem> dropItem = coordinator.items.firstObject;
    if (!destination || !dropItem.sourceIndexPath) return;
    NSDictionary *entry = dropItem.dragItem.localObject;
    if (![entry isKindOfClass:NSDictionary.class]) return;
    NSUInteger sourceRow = [self.entries indexOfObjectIdenticalTo:entry];
    if (sourceRow == NSNotFound) return;
    // 落点按当前序的插入位计（末尾追加=行数）；先移除源行，向下移动回缩一位。
    NSInteger targetRow = MIN(MAX(destination.row, 0), (NSInteger)self.entries.count);
    if (targetRow > (NSInteger)sourceRow) targetRow--;
    if (targetRow == (NSInteger)sourceRow) return;
    [tableView beginUpdates];
    [self.entries removeObjectAtIndex:sourceRow];
    [self.entries insertObject:entry atIndex:targetRow];
    [tableView moveRowAtIndexPath:[NSIndexPath indexPathForRow:sourceRow inSection:0]
        toIndexPath:[NSIndexPath indexPathForRow:targetRow inSection:0]];
    [tableView endUpdates];
    [self save];
}
- (void)pushPicker:(DXPSubActionPickerController *)picker {
    NSDictionary *panel = DXPanelDefinition([DXPrefsManager.sharedInstance readPrefs], self.panelSelector);
    if (!panel) return;
    picker.actionContextKind = panel[@"kind"];
    picker.fullOrder = [panel[@"kind"] isEqual:DXPanelKeyboardKind] ? DXPPanelBuiltInActions() : @[];
    picker.title = DXPanelLocalized(@"CHOOSE_ACTION");
    [picker setRootController:[self rootController]];
    [picker setParentController:[self parentController]];
    [self pushController:picker];
}
- (void)addActions {
    DXPSubActionPickerController *picker = [[DXPKeyboardPanelActionPicker alloc] init];
    picker.allowsMultipleSelection = YES;
    __weak typeof(self) weakSelf = self;
    __weak DXPSubActionPickerController *weakPicker = picker;
    picker.multiSelectionCompletion = ^(NSArray<NSString *> *selectors) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.navigationController.topViewController != weakPicker || ![self.navigationController.viewControllers containsObject:self]) return;
        // The picker can delete definitions and saved panel references. Start
        // from that latest configuration instead of restoring the parent's copy.
        self.entries = [self configuredEntries];
        for (NSString *selector in selectors) {
            if (DXPanelItemAllowed([DXPrefsManager.sharedInstance readPrefs], selector, DXPanelDefinition([DXPrefsManager.sharedInstance readPrefs], self.panelSelector)[@"kind"]) && [self definitionForSelector:selector])
                [self.entries addObject:@{@"id": NSUUID.UUID.UUIDString, @"selector": selector}];
        }
        [self save];
        [self.table reloadData];
    };
    [self pushPicker:picker];
}
- (void)replaceActionAtRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.entries.count) return;
    NSDictionary *original = self.entries[row];
    DXPSubActionPickerController *picker = [[DXPKeyboardPanelActionPicker alloc] init];
    picker.selectedSelector = original[@"selector"];
    __weak typeof(self) weakSelf = self;
    __weak DXPSubActionPickerController *weakPicker = picker;
    picker.completion = ^(NSString *selector) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.navigationController.topViewController != weakPicker || ![self.navigationController.viewControllers containsObject:self] || ![self definitionForSelector:selector] || !DXPanelItemAllowed([DXPrefsManager.sharedInstance readPrefs], selector, DXPanelDefinition([DXPrefsManager.sharedInstance readPrefs], self.panelSelector)[@"kind"])) return;
        self.entries = [self configuredEntries];
        NSUInteger currentRow = [self.entries indexOfObject:original];
        if (currentRow == NSNotFound) return;
        NSMutableDictionary *entry = [original mutableCopy];
        entry[@"selector"] = selector;
        self.entries[currentRow] = entry;
        [self save];
        [self.table reloadData];
    };
    [self pushPicker:picker];
}
// 名称编辑保留独立页面；图标不提供条目覆盖。
- (void)pushAppearanceEditorAtRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.entries.count) return;
    NSDictionary *original = self.entries[row];
    DXPPanelItemAppearanceController *editor = [[DXPPanelItemAppearanceController alloc] init];
    editor.entry = original;
    __weak typeof(self) weakSelf = self;
    editor.completion = ^(NSDictionary *updated) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || ![updated isKindOfClass:NSDictionary.class]) return;
        // Resolve against the latest saved items; a deleted reference stays deleted.
        strongSelf.entries = [strongSelf configuredEntries];
        NSUInteger currentRow = [strongSelf.entries indexOfObject:original];
        if (currentRow == NSNotFound) return;
        strongSelf.entries[currentRow] = updated;
        [strongSelf save];
        [strongSelf.table reloadData];
    };
    [editor setRootController:[self rootController]];
    [editor setParentController:[self parentController]];
    [self pushController:editor];
}
- (void)editDefinition:(NSDictionary *)definition {
    DXPLinkActionEditorController *editor = [[DXPLinkActionEditorController alloc] init];
    editor.entry = [definition mutableCopy];
    __weak typeof(self) weakSelf = self;
    editor.completion = ^(NSDictionary *saved) {
        NSMutableDictionary *preferences = [[[DXPrefsManager sharedInstance] readPrefs] mutableCopy];
        id stored = preferences[kLinkActionskey];
        if (![stored isKindOfClass:NSArray.class]) return;
        NSMutableArray *actions = [stored mutableCopy];
        for (NSUInteger index = 0; index < actions.count; index++) {
            if ([actions[index] isKindOfClass:NSDictionary.class] && [actions[index][@"selector"] isEqual:saved[@"selector"]]) {
                actions[index] = saved;
                preferences[kLinkActionskey] = actions;
                [[DXPrefsManager sharedInstance] writePrefs:preferences];
                [weakSelf.previewHeader refresh];
                [weakSelf.table reloadData];
                break;
            }
        }
    };
    [editor setRootController:[self rootController]];
    [editor setParentController:[self parentController]];
    [self pushController:editor];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSInteger row = indexPath.row;
    if (row < 0 || row >= (NSInteger)self.entries.count) return;
    NSDictionary *entry = self.entries[row];
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:[self nameForEntry:entry] message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [menu addAction:[UIAlertAction actionWithTitle:DXPanelLocalized(@"KEYBOARD_PANEL_ITEM_APPEARANCE") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [weakSelf pushAppearanceEditorAtRow:row]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:DXPanelLocalized(@"KEYBOARD_PANEL_REPLACE_ACTION") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [weakSelf replaceActionAtRow:row]; }]];
    NSDictionary *definition = [self customDefinitionForSelector:entry[@"selector"]];
    if (definition) [menu addAction:[UIAlertAction actionWithTitle:DXPanelLocalized(@"KEYBOARD_PANEL_EDIT_ACTION") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [weakSelf editDefinition:definition]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:DXPanelLocalized(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView = [tableView cellForRowAtIndexPath:indexPath];
    menu.popoverPresentationController.sourceRect = menu.popoverPresentationController.sourceView.bounds;
    [self presentViewController:menu animated:YES completion:nil];
}
@end
