#import "../DXPanelRegistry.h"
#import "DXPGesturePickerController.h"
#import "DXPSubActionsController.h"
#import "DXPSFSymbolPickerController.h"
#import "DXPGestureActionCell.h"
#import "../DXHelper.h"
#import "../DXShortcutsGenerator.h"
#import "../common.h"

static NSBundle *tweakBundle;

// Set while pushing the tap action picker so the return trip can sync the
// chosen action's name/icon into an otherwise-unconfigured entry. The dirty
// flags track unsaved name/icon edits on saved buttons: they are only applied
// when the user taps Save.
@interface DXPGesturePickerController ()
@property (nonatomic, assign) BOOL pushedTapActionPicker;
@property (nonatomic, assign) BOOL nameDirty;
@property (nonatomic, assign) BOOL iconDirty;
// 显示组里的「从图标库选择」行：预览 + 推入 SF 图标库。
@property (nonatomic, strong) PSSpecifier *iconLibrarySpec;
// 显示组里的「图标」输入行：imageView 承载实时预览。
@property (nonatomic, strong) PSSpecifier *customIconSpec;
@end

@implementation DXPGesturePickerController

#pragma mark - Per-shortcut custom name/icon storage

- (NSString *)scopedShortcutsKey {
    return [self.configuration isEqualToString:@"top"] ? kTopShortcutskey : kShortcutskey;
}

// Finds the stored shortcut dictionary (enabled or disabled section) whose
// selector matches this page's identifier, so custom overrides live on the same
// entry the toolbar already reads.
- (NSMutableDictionary *)storedShortcutEntry {
    NSDictionary *prefs = [[DXPrefsManager sharedInstance] readPrefs];
    NSArray *sections = prefs[[self scopedShortcutsKey]];
    if (![sections isKindOfClass:[NSArray class]]) return nil;
    for (NSArray *section in sections) {
        if (![section isKindOfClass:[NSArray class]]) continue;
        for (NSDictionary *item in section) {
            if ([item isKindOfClass:[NSDictionary class]] &&
                [item[@"selector"] isKindOfClass:[NSString class]] &&
                [item[@"selector"] isEqualToString:self.identifier]) {
                return [item mutableCopy];
            }
        }
    }
    return nil;
}

- (void)updateStoredShortcutEntryWithMutator:(void (^)(NSMutableDictionary *entry))mutator {
    NSMutableDictionary *prefs = [[[DXPrefsManager sharedInstance] readPrefs] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSString *shortcutsKey = [self scopedShortcutsKey];
    NSArray *sections = prefs[shortcutsKey];
    if (![sections isKindOfClass:[NSArray class]]) return;

    NSMutableArray *mutableSections = [sections mutableCopy];
    BOOL found = NO;
    for (NSUInteger sectionIndex = 0; sectionIndex < mutableSections.count; sectionIndex++) {
        if (![mutableSections[sectionIndex] isKindOfClass:[NSArray class]]) continue;
        NSMutableArray *rows = [mutableSections[sectionIndex] mutableCopy];
        for (NSUInteger rowIndex = 0; rowIndex < rows.count; rowIndex++) {
            if (![rows[rowIndex] isKindOfClass:[NSDictionary class]]) continue;
            NSMutableDictionary *entry = [rows[rowIndex] mutableCopy];
            if (![entry[@"selector"] isKindOfClass:[NSString class]] ||
                ![entry[@"selector"] isEqualToString:self.identifier]) {
                continue;
            }
            mutator(entry);
            // Blank values clear the override so the built-in label/icon applies.
            for (NSString *customKey in @[@"name", @"icon"]) {
                NSString *value = entry[customKey];
                if (![value isKindOfClass:[NSString class]] || value.length == 0) {
                    [entry removeObjectForKey:customKey];
                }
            }
            rows[rowIndex] = entry;
            found = YES;
        }
        mutableSections[sectionIndex] = rows;
    }
    if (!found) return;

    prefs[shortcutsKey] = mutableSections;
    // writePrefs replaces the authoritative domain, mirrors the shared snapshot
    // and posts kPrefsChangedIdentifier so open toolbars reload immediately.
    [[DXPrefsManager sharedInstance] writePrefs:prefs];
}

#pragma mark - Gesture action lookup

- (NSString *)selectedActionForGesture:(DXShortcutGestureType)gesture identifier:(NSString *)identifier {
    NSDictionary *prefs = [[DXPrefsManager sharedInstance] readPrefs];
    return DXGestureActionSelectors(prefs, identifier, (int)gesture, self.configuration).firstObject;
}
- (NSString *)readGestureActionSummary:(PSSpecifier *)specifier {
    NSNumber *kind = [specifier propertyForKey:@"mubxGestureType"];
    if (![kind isKindOfClass:NSNumber.class]) return LOCALIZED(@"STATUS_BAR_UNASSIGNED");
    NSString *identifier = self.pendingNewEntry ? kNewButtonPendingIdentifier : self.identifier;
    NSArray *selectors = DXGestureActionSelectors([DXPrefsManager.sharedInstance readPrefs], identifier, kind.intValue, self.configuration);
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *selector in selectors) {
        NSString *name = [self canonicalEntryForSelector:selector][@"label"];
        if (!name.length) name = [DXHelper localizedStringForActionNamed:selector shortName:NO bundle:tweakBundle];
        if (name.length) [names addObject:name];
    }
    return names.count ? [names componentsJoinedByString:@" · "] : LOCALIZED(@"STATUS_BAR_UNASSIGNED");
}

// All preference stores that carry per-button entries: six gesture stores
// plus the legacy ordered sub-action list. Pending new buttons stage under one
// sentinel identifier in every store; cleanup/re-key must cover all of them.
- (NSArray<NSString *> *)perButtonPreferenceKeys {
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    for (NSInteger gesture = DXShortcutGestureLongPress; gesture <= DXShortcutGestureTap; gesture++) {
        [keys addObject:DXCustomActionsKeyForGesture((int)gesture, self.configuration)];
    }
    [keys addObject:DXScopedPreferenceKey(kSubActionskey, self.configuration)];
    return keys;
}

- (void)removeCustomActionEntriesWithIdentifier:(NSString *)identifier {
    if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0) return;
    NSMutableDictionary *prefs = [[[DXPrefsManager sharedInstance] readPrefs] mutableCopy] ?: [NSMutableDictionary dictionary];
    BOOL changed = NO;
    for (NSString *key in [self perButtonPreferenceKeys]) {
        NSArray *entries = prefs[key];
        if (![entries isKindOfClass:[NSArray class]]) continue;
        NSArray *filtered = [entries filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"identifier != %@", identifier]];
        if ([filtered isEqualToArray:entries]) continue;
        prefs[key] = filtered;
        changed = YES;
    }
    if (changed) [[DXPrefsManager sharedInstance] writePrefs:prefs];
}

// While a new button is pending, its gesture choices and sub-actions are
// stored under one sentinel identifier across all stores; on save they are
// re-keyed to the button's real identifier.
- (void)rekeyPendingGestureEntriesToIdentifier:(NSString *)identifier prefs:(NSMutableDictionary *)prefs {
    for (NSString *key in [self perButtonPreferenceKeys]) {
        NSArray *entries = prefs[key];
        if (![entries isKindOfClass:[NSArray class]]) continue;
        NSMutableArray *mutableEntries = [entries mutableCopy];
        BOOL changed = NO;
        for (NSUInteger index = 0; index < mutableEntries.count; index++) {
            NSDictionary *entry = mutableEntries[index];
            if (![entry isKindOfClass:[NSDictionary class]] || ![entry[@"identifier"] isEqual:kNewButtonPendingIdentifier]) continue;
            NSMutableDictionary *rekeyed = [entry mutableCopy];
            rekeyed[@"identifier"] = identifier;
            mutableEntries[index] = rekeyed;
            changed = YES;
        }
        if (changed) prefs[key] = mutableEntries;
    }
}

- (NSDictionary *)canonicalEntryForSelector:(NSString *)selector {
    if (![selector isKindOfClass:[NSString class]]) return nil;
    for (NSDictionary *item in self.fullOrder) {
        if ([item isKindOfClass:[NSDictionary class]] && [item[@"selector"] isEqualToString:selector]) {
            return item;
        }
    }
    if (DXIsPanelSelector(selector)) {
        NSDictionary *panel = DXPanelDefinition([DXPrefsManager.sharedInstance readPrefs], selector);
        if (![panel[@"kind"] isEqual:DXPanelKeyboardKind]) return nil;
        NSString *icon = DXPanelString(panel[@"icon"]);
        return @{@"selector": selector, @"label": DXPanelString(panel[@"name"]), @"images12": icon, @"images13": icon};
    }
    if (DXIsLinkActionSelector(selector)) {
        NSDictionary *prefs = [[DXPrefsManager sharedInstance] readPrefs];
        for (NSDictionary *action in prefs[kLinkActionskey]) {
            if (![action isKindOfClass:[NSDictionary class]] || ![action[@"selector"] isEqual:selector]) continue;
            NSString *name = [action[@"name"] isKindOfClass:[NSString class]] ? action[@"name"] : @"";
            NSString *icon = [action[@"icon"] isKindOfClass:[NSString class]] ? action[@"icon"] : @"";
            return @{
                @"selector": selector,
                @"label": name.length ? name : LOCALIZED(@"DEFAULT_BUTTON_NAME"),
                @"images12": @"UIButtonBarListIcon",
                @"images13": icon.length ? icon : @"link",
            };
        }
    }
    return nil;
}

// After the tap action picker returns for an existing button: while both the
// name and icon overrides are still empty, the chosen action's name and icon
// are synced into the entry (and therefore into the fields).
- (void)syncNameAndIconFromTapActionIfNeeded {
    NSString *tapAction = [self selectedActionForGesture:DXShortcutGestureTap identifier:self.identifier];
    if (tapAction.length == 0) return;
    // The user is mid-edit: their unsaved values decide on Save instead.
    if (self.nameDirty || self.iconDirty) return;

    NSDictionary *stored = [self storedShortcutEntry];
    NSString *name = stored[@"name"];
    NSString *icon = stored[@"icon"];
    BOOL nameEmpty = ![name isKindOfClass:[NSString class]] || name.length == 0;
    BOOL iconEmpty = ![icon isKindOfClass:[NSString class]] || icon.length == 0;
    if (!nameEmpty || !iconEmpty) return;

    NSDictionary *canonical = [self canonicalEntryForSelector:tapAction];
    if (!canonical) return;

    [self updateStoredShortcutEntryWithMutator:^(NSMutableDictionary *entry) {
        if (nameEmpty) entry[@"name"] = canonical[@"label"] ?: [DXHelper localizedStringForActionNamed:tapAction shortName:NO bundle:tweakBundle];
        if (iconEmpty) entry[@"icon"] = canonical[@"images13"];
    }];
}

// PSEditTextCell only focuses its field on a precise tap; tapping anywhere on
// the row should start editing, so the field is looked up and focused here.
- (UITextField *)editableTextFieldInView:(UIView *)view {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:[UITextField class]]) return (UITextField *)subview;
        UITextField *found = [self editableTextFieldInView:subview];
        if (found) return found;
    }
    return nil;
}

#pragma mark - Save (new button)

// Resolution for the name/icon of a saved button: with both fields empty, a
// configured tap action supplies both values (mirroring what the fields show);
// otherwise each empty field falls back to the built-in default ("动作" /
// doc.text) and filled fields win as-is.
- (void)resolveNameAndIconForTapAction:(NSString *)tapAction
                                  name:(NSString **)nameOut
                                  icon:(NSString **)iconOut {
    if (self.pendingName.length == 0 && self.pendingIcon.length == 0 && tapAction.length > 0) {
        NSDictionary *canonical = [self canonicalEntryForSelector:tapAction];
        if (nameOut) *nameOut = canonical[@"label"] ?: [DXHelper localizedStringForActionNamed:tapAction shortName:NO bundle:tweakBundle];
        if (iconOut) *iconOut = canonical[@"images13"] ?: @"doc.text";
        return;
    }
    if (nameOut) *nameOut = self.pendingName.length ? self.pendingName : LOCALIZED(@"DEFAULT_BUTTON_NAME");
    if (iconOut) *iconOut = self.pendingIcon.length ? self.pendingIcon : @"doc.text";
}

// Rendering a bundle-ID icon needs an app-icon lookup that sandboxed toolbar
// hosts may not be able to perform themselves, so a successful Settings-side
// load is staged as a PNG under the shared snapshot for them.
- (void)stageAppIconCacheForIconConfig:(NSString *)icon {
    NSString *bundleID = [DXHelper appIconBundleIDForShortcutItem:@{@"icon": icon}];
    if (bundleID) [DXHelper appIconImageForBundleID:bundleID];
}

- (void)saveButtonTapped {
    // A nav-bar tap does not resign the keyboard by itself; commit any
    // in-progress edit first so the pending values are current.
    [self.view endEditing:YES];
    if (self.pendingNewEntry) {
        [self saveNewButton];
        return;
    }
    [self saveNameAndIconEdits];
}

// Applies unsaved name/icon edits on a saved button. Blank values clear the
// override so the built-in label/icon applies again.
- (void)saveNameAndIconEdits {
    if (!self.nameDirty && !self.iconDirty) return;
    NSString *name = self.pendingName ?: @"";
    NSString *icon = self.pendingIcon ?: @"";
    BOOL nameDirty = self.nameDirty;
    BOOL iconDirty = self.iconDirty;

    [self updateStoredShortcutEntryWithMutator:^(NSMutableDictionary *entry) {
        if (nameDirty) entry[@"name"] = name;
        if (iconDirty) entry[@"icon"] = icon;
    }];
    [self stageAppIconCacheForIconConfig:icon];

    self.pendingName = nil;
    self.pendingIcon = nil;
    self.nameDirty = NO;
    self.iconDirty = NO;
    [self updateSaveButtonItem];
    [self reloadSpecifiers];
}

- (void)saveNewButton {
    NSString *tapAction = [self selectedActionForGesture:DXShortcutGestureTap identifier:kNewButtonPendingIdentifier] ?: @"";
    BOOL hasTap = [DXShortcutsGenerator isVisibleShortcutSelector:tapAction] ||
                  [self canonicalEntryForSelector:tapAction] != nil;

    NSMutableDictionary *prefs = [[[DXPrefsManager sharedInstance] readPrefs] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSString *shortcutsKey = [self scopedShortcutsKey];
    NSArray *sections = prefs[shortcutsKey];
    NSMutableArray *mutableSections = ([sections isKindOfClass:[NSArray class]] && sections.count == 2)
        ? [sections mutableCopy]
        : [NSMutableArray arrayWithObjects:[NSMutableArray array], [NSMutableArray array], nil];
    NSMutableArray *enabled = [mutableSections[0] isKindOfClass:[NSArray class]]
        ? [mutableSections[0] mutableCopy] : [NSMutableArray array];

    NSInteger enabledCount = 0;
    for (NSDictionary *entry in enabled) {
        if ([entry isKindOfClass:[NSDictionary class]] && ![entry[@"disabled"] boolValue]) enabledCount++;
    }
    BOOL disableNewEntry = enabledCount >= DXToolbarCapacityForPreferences(prefs, self.configuration);

    // Every saved button gets its own synthetic identifier (draft prefix), so
    // the same action can be added repeatedly while each copy keeps independent
    // gesture/name/icon configuration. Buttons without a tap action stay inert.
    NSString *identifier = [kDraftActionPrefix stringByAppendingString:[NSUUID UUID].UUIDString];
    NSDictionary *canonical = hasTap ? [self canonicalEntryForSelector:tapAction] : nil;

    NSString *name = nil;
    NSString *icon = nil;
    [self resolveNameAndIconForTapAction:hasTap ? tapAction : @"" name:&name icon:&icon];
    [self stageAppIconCacheForIconConfig:icon];

    NSMutableDictionary *entry = canonical ? [canonical mutableCopy] : [NSMutableDictionary dictionary];
    entry[@"selector"] = identifier;
    entry[@"label"] = name;
    entry[@"name"] = name;
    entry[@"icon"] = icon;
    if (!entry[@"images12"]) entry[@"images12"] = canonical[@"images12"] ?: @"UIButtonBarListIcon";
    if (!entry[@"images13"]) entry[@"images13"] = icon;
    // Adding is unlimited. Once the active capacity is full, save the new
    // button in the same list but keep its switch off until another is closed.
    if (disableNewEntry) entry[@"disabled"] = @YES;
    [enabled addObject:entry];
    mutableSections[0] = enabled;
    prefs[shortcutsKey] = mutableSections;

    [self rekeyPendingGestureEntriesToIdentifier:identifier prefs:prefs];
    [[DXPrefsManager sharedInstance] writePrefs:prefs];

    self.identifier = identifier;
    self.pendingNewEntry = NO;
    self.title = name;
    [self.navigationController popViewControllerAnimated:YES];
}

#pragma mark - Specifier value handlers

- (id)readNameValue:(PSSpecifier *)specifier {
    if (self.pendingNewEntry) {
        NSString *tapAction = [self selectedActionForGesture:DXShortcutGestureTap identifier:kNewButtonPendingIdentifier] ?: @"";
        // Fields carry user input only; the default ("动作") is applied at
        // save time. With both fields empty, a configured tap action mirrors
        // its name/icon into the fields instead.
        BOOL bothEmpty = self.pendingName.length == 0 && self.pendingIcon.length == 0;
        if (tapAction.length > 0 && bothEmpty) {
            NSDictionary *canonical = [self canonicalEntryForSelector:tapAction];
            return canonical[@"label"] ?: [DXHelper localizedStringForActionNamed:tapAction shortName:NO bundle:tweakBundle] ?: @"";
        }
        return self.pendingName ?: @"";
    }
    // Unsaved edits are shown until saved or discarded by leaving the page.
    if (self.nameDirty) return self.pendingName ?: @"";
    return [self storedShortcutEntry][@"name"] ?: @"";
}

- (void)setNameValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *name = [value isKindOfClass:[NSString class]]
        ? [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
        : @"";
    if (self.pendingNewEntry) {
        self.pendingName = name;
        return;
    }
    // Saved buttons only apply the edit on Save, so a stray change can be
    // discarded by leaving without saving.
    self.pendingName = name;
    self.nameDirty = YES;
    [self updateSaveButtonItem];
}

- (id)readIconValue:(PSSpecifier *)specifier {
    if (self.pendingNewEntry) {
        NSString *tapAction = [self selectedActionForGesture:DXShortcutGestureTap identifier:kNewButtonPendingIdentifier] ?: @"";
        BOOL bothEmpty = self.pendingName.length == 0 && self.pendingIcon.length == 0;
        if (tapAction.length > 0 && bothEmpty)
            return [self canonicalEntryForSelector:tapAction][@"images13"] ?: @"";
        return self.pendingIcon ?: @"";
    }
    if (self.iconDirty) return self.pendingIcon ?: @"";
    return [self storedShortcutEntry][@"icon"] ?: @"";
}

- (void)setIconValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *icon = [value isKindOfClass:[NSString class]]
        ? [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
        : @"";

    // SF Symbol names and app bundle identifiers are both accepted; anything
    // else keeps the default icon instead of silently rendering a blank
    // shortcut.
    if (icon.length > 0
        && ![DXHelper customIconForShortcutItem:@{@"icon": icon}]
        && ![DXHelper appIconBundleIDForShortcutItem:@{@"icon": icon}]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"MUBX"
                                                                       message:LOCALIZED(@"CUSTOM_ICON_INVALID")
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:LOCALIZED(@"ANSWER_YES")
                                                  style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }

    if (self.pendingNewEntry) {
        self.pendingIcon = icon;
        return;
    }
    self.pendingIcon = icon;
    self.iconDirty = YES;
    [self updateSaveButtonItem];
}

#pragma mark - Specifiers

// Every gesture opens its own ordered sub-action editor.
- (NSArray<NSArray *> *)gestureRows {
    return @[
        @[@(DXShortcutGestureTap), @"GESTURE_TAP"],
        @[@(DXShortcutGestureLongPress), @"LONG_PRESS"],
        @[@(DXShortcutGestureSwipeUp), @"SWIPE_UP"],
        @[@(DXShortcutGestureSwipeDown), @"SWIPE_DOWN"],
        @[@(DXShortcutGestureSwipeLeft), @"SWIPE_LEFT"],
        @[@(DXShortcutGestureSwipeRight), @"SWIPE_RIGHT"],
    ];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *snippetEntrySpecifiers = [[NSMutableArray alloc] init];

        PSSpecifier *displayGroup = [PSSpecifier preferenceSpecifierNamed:LOCALIZED(@"CUSTOM_APPEARANCE") target:nil set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [displayGroup setProperty:LOCALIZED(@"FOOTER_CUSTOM_APPEARANCE") forKey:@"footerText"];
        [snippetEntrySpecifiers addObject:displayGroup];

        PSSpecifier *customNameSpec = [PSSpecifier preferenceSpecifierNamed:LOCALIZED(@"CUSTOM_NAME") target:self set:@selector(setNameValue:specifier:) get:@selector(readNameValue:) detail:nil cell:PSEditTextCell edit:nil];
        [customNameSpec setProperty:@YES forKey:@"noAutoCorrect"];
        [customNameSpec setProperty:LOCALIZED(@"CUSTOM_NAME") forKey:@"label"];
        [snippetEntrySpecifiers addObject:customNameSpec];

        PSSpecifier *customIconSpec = [PSSpecifier preferenceSpecifierNamed:LOCALIZED(@"CUSTOM_ICON") target:self set:@selector(setIconValue:specifier:) get:@selector(readIconValue:) detail:nil cell:PSEditTextCell edit:nil];
        [customIconSpec setProperty:@YES forKey:@"noAutoCorrect"];
        [customIconSpec setProperty:LOCALIZED(@"CUSTOM_ICON") forKey:@"label"];
        self.customIconSpec = customIconSpec;
        [snippetEntrySpecifiers addObject:customIconSpec];

        // 图标库入口行：左侧实时预览当前图标，点击推入 SF 图标库；回写走
        // setIconValue: 的既有校验与保存按钮脏标记链。
        PSSpecifier *iconLibrarySpec = [PSSpecifier preferenceSpecifierNamed:LOCALIZED(@"ICON_LIBRARY_ROW") target:self set:nil get:nil detail:nil cell:PSLinkCell edit:nil];
        [iconLibrarySpec setProperty:LOCALIZED(@"ICON_LIBRARY_ROW") forKey:@"label"];
        self.iconLibrarySpec = iconLibrarySpec;
        [snippetEntrySpecifiers addObject:iconLibrarySpec];

        PSSpecifier *gestureTypeGroup = [PSSpecifier preferenceSpecifierNamed:LOCALIZED(@"GESTURES") target:nil set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [snippetEntrySpecifiers addObject:gestureTypeGroup];

        for (NSArray *gestureRow in [self gestureRows]) {
            NSString *label = LOCALIZED(gestureRow[1]);
            PSSpecifier *gestureSpec = [PSSpecifier preferenceSpecifierNamed:label target:self set:nil get:@selector(readGestureActionSummary:) detail:NSClassFromString(@"DXPSubActionsController") cell:PSLinkCell edit:nil];
            [gestureSpec setProperty:label forKey:@"label"];
            [gestureSpec setProperty:gestureRow[0] forKey:@"mubxGestureType"];
            [snippetEntrySpecifiers addObject:gestureSpec];
        }

        _specifiers = snippetEntrySpecifiers;

    }

    return _specifiers;
}

// 图标配置的预览渲染：自定义覆盖优先，其次点按动作的目录图标（内置 SF 名/
// 自定义动作图标通吃），两者皆无显示问号占位。isPlaceholder 带回是否占位。
- (UIImage *)previewImageForIconConfig:(NSString *)icon placeholder:(BOOL *)isPlaceholder {
    if (![icon isKindOfClass:NSString.class]) icon = @"";
    icon = [icon stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    UIImage *image = nil;
    if (icon.length) {
        image = [DXHelper imageForIconConfig:icon defaultSymbolName:@"link"];
    } else {
        NSString *tapAction = [self selectedActionForGesture:DXShortcutGestureTap
                                                  identifier:self.pendingNewEntry ? kNewButtonPendingIdentifier : self.identifier] ?: @"";
        NSString *builtIn = [self canonicalEntryForSelector:tapAction][@"images13"];
        if ([builtIn isKindOfClass:NSString.class] && builtIn.length) {
            image = [DXHelper imageForIconConfig:builtIn defaultSymbolName:@"link"];
        }
    }
    BOOL placeholder = (image == nil);
    if (isPlaceholder) *isPlaceholder = placeholder;
    return placeholder ? [UIImage systemImageNamed:@"questionmark.square"] : image;
}

// 显示组三行的 cell 定制：图标行 imageView 实时预览（键入即刷新，去重注册），
// 名称行清掉复用残留的预览图，图标库行预览生效图标。
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *gestureItem = [self specifierAtIndexPath:indexPath];
    if ([[gestureItem propertyForKey:@"mubxGestureType"] isKindOfClass:NSNumber.class])
        return DXPGestureActionCell(tableView, @"DXPToolbarGestureRecord", gestureItem.name, [self readGestureActionSummary:gestureItem], nil,
            UITableViewCellAccessoryDisclosureIndicator);
    // 图标库行整行用自绘 cell（标准 textLabel/imageView/chevron），彻底绕开
    // PSTableCell 对无 detail PSLinkCell 的弱化灰渲染与私有标题标签——此前
    // 改 textLabel 颜色与按 textLabel 文本匹配点击全部落空即根因于此。
    if (self.iconLibrarySpec && [self specifierAtIndexPath:indexPath] == self.iconLibrarySpec) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"DXPIconLibraryRow"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"DXPIconLibraryRow"];
        BOOL placeholder = NO;
        UIImage *image = [self previewImageForIconConfig:[self readIconValue:nil] placeholder:&placeholder];
        cell.imageView.image = image;
        cell.imageView.tintColor = placeholder ? UIColor.secondaryLabelColor : nil;
        cell.textLabel.text = LOCALIZED(@"ICON_LIBRARY_ROW");
        cell.textLabel.textColor = UIColor.labelColor;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.detailTextLabel.text = nil;
        return cell;
    }
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    if (self.customIconSpec && specifier == self.customIconSpec) {
        BOOL placeholder = NO;
        cell.imageView.image = [self previewImageForIconConfig:[self readIconValue:nil] placeholder:&placeholder];
        cell.imageView.tintColor = placeholder ? UIColor.secondaryLabelColor : nil;
        cell.detailTextLabel.text = nil;
        UITextField *field = [self editableTextFieldInView:cell];
        if (field && ![field actionsForTarget:self forControlEvent:UIControlEventEditingChanged]) {
            [field addTarget:self action:@selector(iconFieldTextChanged:) forControlEvents:UIControlEventEditingChanged];
        }
    }
    if (!self.customIconSpec || specifier != self.customIconSpec) {
        // PSEditTextCell 复用池共享：非图标行清掉可能残留的预览图。
        if ([cell isKindOfClass:NSClassFromString(@"PSEditTextCell")]) {
            cell.imageView.image = nil;
            cell.imageView.tintColor = nil;
        }
    }
    return cell;
}

- (void)iconFieldTextChanged:(UITextField *)field {
    UIView *view = field;
    while (view && ![view isKindOfClass:[UITableViewCell class]]) view = view.superview;
    UITableViewCell *cell = (UITableViewCell *)view;
    if (!cell) return;
    BOOL placeholder = NO;
    cell.imageView.image = [self previewImageForIconConfig:field.text placeholder:&placeholder];
    cell.imageView.tintColor = placeholder ? UIColor.secondaryLabelColor : nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath{

    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];

    // Commit any in-progress text edit (e.g. another name/icon field) before
    // acting on this row.
    [self.view endEditing:YES];

    // Name/icon rows: tapping anywhere on the row starts editing.
    UITextField *editField = [self editableTextFieldInView:cell];
    if (editField) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        [editField becomeFirstResponder];
        return;
    }

    // 图标库行：推入 SF 图标库；选中后经 setIconValue: 的既有校验回写并刷新。
    // specifier 指针比对为主，标签匹配兜底。
    BOOL isLibraryRow = (self.iconLibrarySpec && [self specifierAtIndexPath:indexPath] == self.iconLibrarySpec) ||
        [cell.textLabel.text isEqualToString:LOCALIZED(@"ICON_LIBRARY_ROW")];
    if (isLibraryRow) {
        NSLog(@"[MUBX][SFSymbol] library row tapped, pushing picker");
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        DXPSFSymbolPickerController *picker = [[DXPSFSymbolPickerController alloc] init];
        NSString *current = [self readIconValue:nil];
        picker.selectedSymbolName = [current isKindOfClass:NSString.class] ? current : nil;
        __weak typeof(self) weakSelf = self;
        picker.completion = ^(NSString *symbolName) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || !symbolName.length) return;
            if (strongSelf.pendingNewEntry) {
                // 新建未保存按钮没有可落盘的条目：保持暂存，随页面保存一并写入。
                NSLog(@"[MUBX][SFSymbol] stage icon=%@ (pendingNewEntry)", symbolName);
                [strongSelf setIconValue:symbolName specifier:strongSelf.iconLibrarySpec];
                [strongSelf reloadSpecifiers];
                return;
            }
            // 已保存按钮：图标库选中立即落盘生效（目录选出的名字必过 systemImageNamed
            // 校验）；字段里未保存的手输图标暂存被本次选择覆盖，名称暂存不受影响。
            NSLog(@"[MUBX][SFSymbol] apply immediate icon=%@", symbolName);
            [strongSelf updateStoredShortcutEntryWithMutator:^(NSMutableDictionary *entry) {
                entry[@"icon"] = symbolName;
            }];
            [strongSelf stageAppIconCacheForIconConfig:symbolName];
            strongSelf.pendingIcon = nil;
            strongSelf.iconDirty = NO;
            [strongSelf updateSaveButtonItem];
            [strongSelf reloadSpecifiers];
        };
        [picker setRootController:[self rootController]];
        [picker setParentController:[self parentController]];
        [self pushController:picker];
        return;
    }

    // Match the row's stable metadata, never a private Preferences label.
    id kind = [[self specifierAtIndexPath:indexPath] propertyForKey:@"mubxGestureType"];
    NSInteger gestureType = [kind isKindOfClass:NSNumber.class] ? [kind integerValue] : -1;
    if (gestureType < DXShortcutGestureLongPress || gestureType > DXShortcutGestureTap) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        return;
    }

    DXPSubActionsController *actionViewController = [[DXPSubActionsController alloc] init];

    actionViewController.fullOrder = self.fullOrder;
    // While the new button is unsaved, gesture choices accumulate under one
    // sentinel identifier and are re-keyed on Save.
    actionViewController.identifier = self.pendingNewEntry ? kNewButtonPendingIdentifier : self.identifier;
    actionViewController.configuration = self.configuration;
    // Each gesture type keeps its custom action under its own preference key.
    actionViewController.gestureType = gestureType;
    if (gestureType == DXShortcutGestureTap) self.pushedTapActionPicker = YES;

    actionViewController.title = LOCALIZED(@"SUB_ACTIONS");

    [actionViewController setRootController: [self rootController]];
    [actionViewController setParentController: [self parentController]];
    [self pushController:actionViewController];

    [tableView deselectRowAtIndexPath:indexPath animated:YES];


}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Coming back from the tap action picker with both name and icon still
    // empty syncs the chosen action's identity into the entry.
    if (!self.pendingNewEntry && self.pushedTapActionPicker) {
        self.pushedTapActionPicker = NO;
        [self syncNameAndIconFromTapActionIfNeeded];
    }
    // Name/icon fields read through the specifiers; refresh them so a choice
    // made in the action picker is mirrored into the fields right away.
    [self reloadSpecifiers];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // Leaving the new-button page without saving discards the gesture choices
    // made so far (they were staged under the pending identifier). Popping
    // after Save has already re-keyed them, so pendingNewEntry is NO by then.
    if ([self isMovingFromParentViewController]) {
        if (self.pendingNewEntry) {
            [self removeCustomActionEntriesWithIdentifier:kNewButtonPendingIdentifier];
        }
        // Unsaved name/icon edits are never written; drop them so backing out
        // is always a clean discard.
        self.pendingName = nil;
        self.pendingIcon = nil;
        self.nameDirty = NO;
        self.iconDirty = NO;
    }
}

// Save is always offered on the new-button page; on saved buttons it only
// appears once name/icon edits are pending.
- (void)updateSaveButtonItem {
    if (!self.pendingNewEntry && !self.nameDirty && !self.iconDirty) {
        self.navigationItem.rightBarButtonItem = nil;
        return;
    }
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:LOCALIZED(@"SAVE")
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(saveButtonTapped)];
}

- (void)viewDidLoad {
    tweakBundle = [NSBundle bundleWithPath:bundlePath];
    [tweakBundle load];
    [super viewDidLoad];
    [self updateSaveButtonItem];
}
@end
