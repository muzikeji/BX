#import "DXPManageShortcutsController.h"
#import "DXPGesturePickerController.h"
#import "../DXShortcutsGenerator.h"
#import "../DXHelper.h"
#import "../DXCollectionView.h"
#import "../common.h"
#import <objc/runtime.h>
#include <math.h>

static NSBundle *tweakBundle;

@interface DXPManageShortcutsController ()
@property (nonatomic, strong) UIView *toolbarPreviewHeader;
@property (nonatomic, strong) UILabel *toolbarPreviewCaption;
@property (nonatomic, strong) UILabel *toolbarPreviewStatus;
@property (nonatomic, strong) DXCollectionView *toolbarPreview;
@property (nonatomic, copy) NSDictionary *toolbarPreviewPreferences;
@property (nonatomic, strong) UIView *toolbarPreviewDock;
@property (nonatomic, strong) UIImageView *toolbarPreviewGlobe;
@property (nonatomic, strong) UIImageView *toolbarPreviewDictation;
@property (nonatomic, assign) CGFloat toolbarPreviewDockHeight;
@end

// Height of the section header hosting the test field above the
// button-settings rows: field title + field + section title + padding.
#define kTestFieldSectionHeaderHeight 110.0

static BOOL DXIsHiddenShortcutSelector(NSString *selector) {
    return ![DXShortcutsGenerator isVisibleShortcutSelector:selector];
}

// One row of the toolbar-scoped settings sections. Sliders snap to `step` and
// fall back to `defaultValue` while the preference key is unset.
@interface DXSettingsRow : NSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *label;
@property (nonatomic, assign) BOOL isSwitch;
@property (nonatomic, assign) BOOL isSegment;
@property (nonatomic, copy) NSArray<NSString *> *segmentTitles;
@property (nonatomic, assign) float minValue;
@property (nonatomic, assign) float maxValue;
@property (nonatomic, assign) float step;
@property (nonatomic, assign) float defaultValue;
@property (nonatomic, copy) NSString *valueSuffix;
@end

@implementation DXSettingsRow
+ (DXSettingsRow *)switchRowWithKey:(NSString *)key label:(NSString *)label defaultValue:(BOOL)defaultValue {
    DXSettingsRow *row = [[DXSettingsRow alloc] init];
    row.key = key;
    row.label = label;
    row.isSwitch = YES;
    row.defaultValue = defaultValue ? 1.0 : 0.0;
    return row;
}

// Index-valued row rendered as a segmented control; the selected segment index
// is the stored value.
+ (DXSettingsRow *)segmentRowWithKey:(NSString *)key label:(NSString *)label titles:(NSArray<NSString *> *)titles defaultValue:(float)defaultValue {
    DXSettingsRow *row = [[DXSettingsRow alloc] init];
    row.key = key;
    row.label = label;
    row.isSegment = YES;
    row.segmentTitles = titles;
    row.defaultValue = defaultValue;
    return row;
}

+ (DXSettingsRow *)sliderRowWithKey:(NSString *)key label:(NSString *)label minValue:(float)minValue maxValue:(float)maxValue step:(float)step defaultValue:(float)defaultValue {
    DXSettingsRow *row = [[DXSettingsRow alloc] init];
    row.key = key;
    row.label = label;
    row.minValue = minValue;
    row.maxValue = maxValue;
    row.step = step > 0 ? step : 1.0;
    row.defaultValue = defaultValue;
    return row;
}
@end

static void DXAppendUniqueShortcuts(NSArray *shortcuts,
                                    NSMutableArray *destination,
                                    NSMutableSet *seenSelectors,
                                    NSUInteger limit) {
    for (id object in shortcuts) {
        if (destination.count >= limit) break;
        if (![object isKindOfClass:[NSDictionary class]]) continue;

        NSDictionary *shortcut = (NSDictionary *)object;
        NSString *selector = shortcut[@"selector"];
        // Draft buttons (saved without a tap action) carry a synthetic
        // selector and must survive normalization untouched.
        if (!DXIsDraftActionSelector(selector)) {
            if (![selector isKindOfClass:[NSString class]] ||
                DXIsHiddenShortcutSelector(selector) ||
                [seenSelectors containsObject:selector]) {
                continue;
            }
            [seenSelectors addObject:selector];
        }

        [destination addObject:shortcut];
    }
}


@implementation DXPManageShortcutsController

- (NSString *)scopedKey:(NSString *)bottomKey topKey:(NSString *)topKey {
    return self.topConfiguration ? topKey : bottomKey;
}

#pragma mark - Table view: configured buttons only

// Section 0 lists buttons, section 1 controls button appearance (including the
// top column count), and section 2 controls the sub-action panel. Section 3
// carries the top row spacing or the bottom toolbar height.
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 1) return LOCALIZED(@"BUTTON_SETTINGS");
    if (section == 2) return LOCALIZED(@"PANEL_SETTINGS");
    if (section == 3) return self.topConfiguration ? LOCALIZED(@"MULTILINE_SETTINGS") : LOCALIZED(@"OFFSETS");
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 1: return self.appearanceRows.count;
        case 2: return self.panelRows.count;
        case 3: return self.topConfiguration ? self.multiRowRows.count : self.offsetRows.count;
        default: return [self.currentOrder[0] count];
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0)
        return self.topConfiguration ? LOCALIZED(@"FOOTER_TOP_TOOLBAR_BUTTONS")
                                     : LOCALIZED(@"FOOTER_TOOLBAR_BUTTONS");
    if (section == 1) {
        if (!self.topConfiguration) return [NSString stringWithFormat:@"%@\n%@", LOCALIZED(@"FOOTER_BUTTON_SETTINGS"), LOCALIZED(@"FLOATING_SHELF_FOOTER")];
        return LOCALIZED(@"FOOTER_BUTTON_SETTINGS_TOP");
    }
    if (section == 2) return LOCALIZED(@"FOOTER_PANEL_SETTINGS");
    if (section == 3 && self.topConfiguration) return LOCALIZED(@"FOOTER_MULTILINE");
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section > 0) return [self settingsCellForRowAtIndexPath:indexPath];

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"TypeXItemCell" forIndexPath:indexPath];

    if (cell == nil)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"TypeXItemCell"];

    if (self.currentOrder[0] == nil || indexPath.row >= [self.currentOrder[0] count])
        return cell;

    UIImage *image;
    NSString *label;

    dispatch_semaphore_t smp = dispatch_semaphore_create(0);
    __block BOOL isCustomImagePath = NO;
    __block BOOL isThirteen = NO;

    label = [DXHelper localizedStringForActionNamed:[DXHelper actionNameFromArray:self.currentOrder[0] atIndex:indexPath.row] shortName:NO bundle:tweakBundle];
    image = [DXHelper imageFromArray:self.currentOrder[0] atIndex:indexPath.row withSystemColor:YES completion:^(BOOL thirteen, BOOL customPath){
        isThirteen = thirteen;
        isCustomImagePath = customPath;
        dispatch_semaphore_signal(smp);
    }];
    dispatch_semaphore_wait(smp, DISPATCH_TIME_FOREVER);
    if (!isThirteen && isCustomImagePath){
        [cell.imageView setTintColor:[UIColor blackColor]];
    }

    NSDictionary *shortcutItem = self.currentOrder[indexPath.section][indexPath.row];

    // Per-shortcut overrides set in the button's own settings page: a custom
    // name replaces the localized label and a valid SF Symbol or app bundle
    // identifier replaces the icon.
    NSString *customName = [DXHelper customNameForShortcutItem:shortcutItem];
    if (customName) label = customName;
    else if ([shortcutItem[@"label"] isKindOfClass:[NSString class]] && [(NSString *)shortcutItem[@"label"] length])
        label = shortcutItem[@"label"];
    NSString *customIcon = [DXHelper customIconForShortcutItem:shortcutItem];
    if (customIcon) image = [DXHelper imageForName:customIcon withSystemColor:YES completion:nil];
    else {
        NSString *iconBundleID = [DXHelper appIconBundleIDForShortcutItem:shortcutItem];
        if (iconBundleID) image = [DXHelper appIconImageForBundleID:iconBundleID];
    }

    // Enable switch: off keeps the button stored but hides it from the
    // toolbar. The table lives in editing mode permanently, so the switch is
    // mounted as the editing accessory view (the one actually displayed).
    UISwitch *toggle = (UISwitch *)cell.editingAccessoryView;
    if (![toggle isKindOfClass:[UISwitch class]]) {
        toggle = [[UISwitch alloc] init];
        [toggle addTarget:self action:@selector(buttonEnabledToggleChanged:) forControlEvents:UIControlEventValueChanged];
    }
    cell.accessoryView = nil;
    cell.editingAccessoryView = toggle;
    BOOL buttonDisabled = [shortcutItem[@"disabled"] boolValue];
    toggle.on = !buttonDisabled;

    cell.textLabel.text = label;
    cell.textLabel.textColor = buttonDisabled ? [UIColor secondaryLabelColor] : [UIColor labelColor];
    cell.imageView.image = image;
    return cell;
}

// Row recovered from the switch's cell: rows move and delete, so a cached
// index would go stale. The list itself is unlimited, but the top toolbar may
// enable only the current one-screen capacity.
- (void)buttonEnabledToggleChanged:(UISwitch *)sender {
    UIView *view = sender;
    while (view && ![view isKindOfClass:[UITableViewCell class]]) view = view.superview;
    NSIndexPath *indexPath = [self.tableView indexPathForCell:(UITableViewCell *)view];
    if (!indexPath || indexPath.section != 0 || indexPath.row >= (NSInteger)[self.currentOrder[0] count]) return;

    NSDictionary *preferences = [[DXPrefsManager sharedInstance] readPrefs];
    NSInteger capacity = DXToolbarCapacityForPreferences(preferences, self.topConfiguration ? @"top" : @"bottom");
    if (sender.isOn && [self enabledButtonCount] >= capacity) {
        [sender setOn:NO animated:YES];
        NSString *message = [NSString stringWithFormat:LOCALIZED(@"KEYBOARD_TOOLBAR_CAPACITY"), (long)capacity];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"TypeX" message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:LOCALIZED(@"ANSWER_OK") style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    NSMutableDictionary *entry = [self.currentOrder[0][indexPath.row] mutableCopy];
    if (sender.on) [entry removeObjectForKey:@"disabled"];
    else entry[@"disabled"] = @YES;
    self.currentOrder[0][indexPath.row] = entry;
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
    cell.textLabel.textColor = sender.on ? [UIColor labelColor] : [UIColor secondaryLabelColor];
    [self writeToFile];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath{
    if (indexPath.section != 0) return;
    DXPGesturePickerController *gesturePickerController = [[DXPGesturePickerController alloc] init];

    gesturePickerController.fullOrder = self.fullOrder;
    gesturePickerController.identifier = self.currentOrder[indexPath.section][indexPath.row][@"selector"];
    gesturePickerController.configuration = self.topConfiguration ? @"top" : @"bottom";
    NSDictionary *shortcutItem = self.currentOrder[indexPath.section][indexPath.row];
    // Draft buttons have a synthetic selector, so prefer the stored label.
    gesturePickerController.title = [DXHelper customNameForShortcutItem:shortcutItem]
        ?: [shortcutItem[@"label"] isKindOfClass:[NSString class]] && [(NSString *)shortcutItem[@"label"] length] ? shortcutItem[@"label"]
        : [DXHelper localizedStringForActionNamed:shortcutItem[@"selector"] shortName:NO bundle:tweakBundle];

    [gesturePickerController setRootController: [self rootController]];
    [gesturePickerController setParentController: [self parentController]];
    [self pushController:gesturePickerController];

    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destinationIndexPath {
    if (self.tableView == nil)
        return;

    NSString *objectToMove = [self.currentOrder[0] objectAtIndex:sourceIndexPath.row];
    [self.currentOrder[0] removeObjectAtIndex:sourceIndexPath.row];
    [self.currentOrder[0] insertObject:objectToMove atIndex:destinationIndexPath.row];
    [self.tableView reloadData];
    [self writeToFile];
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 0;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath{
    return indexPath.section == 0;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete || indexPath.section != 0) return;

    // Deleting forgets the button entirely: the entry leaves the toolbar and
    // its per-button gesture configuration is cleared with it.
    NSString *identifier = self.currentOrder[0][indexPath.row][@"selector"];
    [tableView beginUpdates];
    [self.currentOrder[0] removeObjectAtIndex:indexPath.row];
    [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationFade];
    [tableView endUpdates];
    [self removeCustomActionsForIdentifier:identifier];
    [self writeToFile];
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 0 ? UITableViewCellEditingStyleDelete : UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    return NO;
}

-(NSIndexPath *)tableView:(UITableView *)tableView targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)sourceIndexPath toProposedIndexPath:(NSIndexPath *)proposedDestinationIndexPath
{
    if( sourceIndexPath.section != proposedDestinationIndexPath.section )
    {
        return sourceIndexPath;
    }
    else
    {
        return proposedDestinationIndexPath;
    }
}

#pragma mark - Toolbar preview

// Resolve the injected renderer dynamically: the preferences bundle does not
// link a second copy of the keyboard/action implementation into Settings.
- (void)installToolbarPreview {
    if (self.toolbarPreviewHeader) return;
    self.toolbarPreviewHeader = [[UIView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(self.tableView.bounds), 94)];
    self.toolbarPreviewHeader.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.toolbarPreviewCaption = [UILabel new];
    self.toolbarPreviewCaption.text = LOCALIZED(@"TOOLBAR_PREVIEW");
    self.toolbarPreviewCaption.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.toolbarPreviewCaption.textColor = UIColor.secondaryLabelColor;
    [self.toolbarPreviewHeader addSubview:self.toolbarPreviewCaption];

    self.toolbarPreviewStatus = [UILabel new];
    self.toolbarPreviewStatus.font = [UIFont systemFontOfSize:14];
    self.toolbarPreviewStatus.textColor = UIColor.secondaryLabelColor;
    self.toolbarPreviewStatus.textAlignment = NSTextAlignmentCenter;
    self.toolbarPreviewStatus.numberOfLines = 0;
    [self.toolbarPreviewHeader addSubview:self.toolbarPreviewStatus];

    UIView *previewHost = self.toolbarPreviewHeader;
    if (!self.topConfiguration) {
        self.toolbarPreviewDockHeight = heightOffsetDefault;
        self.toolbarPreviewDock = [UIView new];
        self.toolbarPreviewDock.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithWhite:0.16 alpha:1.0]
                : [UIColor colorWithRed:0.82 green:0.83 blue:0.85 alpha:1.0];
        }];
        self.toolbarPreviewDock.layer.cornerRadius = 12;
        self.toolbarPreviewDock.clipsToBounds = YES;
        self.toolbarPreviewDock.userInteractionEnabled = NO;
        [self.toolbarPreviewHeader addSubview:self.toolbarPreviewDock];
        // Stock dock controls provide visual context; only the shortcut strip
        // is rendered by TypeX, and no keyboard controls are activated here.
        UIImageSymbolConfiguration *symbol = [UIImageSymbolConfiguration configurationWithPointSize:26 weight:UIImageSymbolWeightRegular];
        self.toolbarPreviewGlobe = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"globe" withConfiguration:symbol]];
        self.toolbarPreviewDictation = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"mic" withConfiguration:symbol]];
        for (UIImageView *imageView in @[self.toolbarPreviewGlobe, self.toolbarPreviewDictation]) {
            imageView.contentMode = UIViewContentModeScaleAspectFit;
            imageView.tintColor = UIColor.secondaryLabelColor;
            [self.toolbarPreviewDock addSubview:imageView];
        }
        previewHost = self.toolbarPreviewDock;
    }

    NSString *configuration = self.topConfiguration ? @"top" : @"bottom";
    Class renderer = NSClassFromString(@"DXCollectionView");
    if ([renderer isSubclassOfClass:UICollectionView.class] &&
        [renderer instancesRespondToSelector:@selector(initWithConfiguration:preview:)] &&
        [renderer instancesRespondToSelector:@selector(configurePreviewWithPreferences:)]) {
        self.toolbarPreview = [(DXCollectionView *)[renderer alloc] initWithConfiguration:configuration preview:YES];
        self.toolbarPreview.backgroundColor = self.topConfiguration ? UIColor.secondarySystemGroupedBackgroundColor : UIColor.clearColor;
        [previewHost addSubview:self.toolbarPreview];
    } else {
        NSLog(@"[TypeX][ToolbarPreview] unavailable renderer in Settings configuration=%@", configuration);
    }
    [self.toolbarPreviewHeader bringSubviewToFront:self.toolbarPreviewStatus];
    self.tableView.tableHeaderView = self.toolbarPreviewHeader;
}

- (void)refreshToolbarPreview {
    if (!self.toolbarPreviewHeader) return;
    self.toolbarPreviewPreferences = [[DXPrefsManager sharedInstance] readPrefs];
    [self applyToolbarPreviewPreferences:self.toolbarPreviewPreferences];
}

- (void)applyToolbarPreviewPreferences:(NSDictionary *)preferences {
    if (!self.toolbarPreviewHeader) return;
    [self.toolbarPreview configurePreviewWithPreferences:preferences];
    if (!self.topConfiguration) {
        id value = preferences[kHeightOffsetkey];
        CGFloat height = [value respondsToSelector:@selector(floatValue)] ? [value floatValue] : heightOffsetDefault;
        self.toolbarPreviewDockHeight = isfinite(height) ? MIN(80.0, MAX(50.0, height)) : heightOffsetDefault;
    }
    BOOL shelfMode = !self.topConfiguration && [preferences[kFloatingShelfEnabledKey] isKindOfClass:NSNumber.class] && [preferences[kFloatingShelfEnabledKey] boolValue];
    BOOL hasButtons = !shelfMode && [self.toolbarPreview.shortcuts[kselectors] count] > 0;
    self.toolbarPreviewStatus.text = LOCALIZED(shelfMode ? @"FLOATING_SHELF_PREVIEW" :
        (self.toolbarPreview ? @"TOOLBAR_PREVIEW_EMPTY" : @"TOOLBAR_PREVIEW_UNAVAILABLE"));
    self.toolbarPreviewStatus.hidden = hasButtons;
    self.toolbarPreview.hidden = !hasButtons;
    [self layoutToolbarPreviewHeader];
}

- (void)layoutToolbarPreviewHeader {
    if (!self.toolbarPreviewHeader) return;
    CGFloat width = CGRectGetWidth(self.tableView.bounds);
    CGFloat toolbarHeight = self.topConfiguration ? MAX(41.5, [self.toolbarPreview preferredToolbarHeight]) : self.toolbarPreviewDockHeight;
    CGFloat leading = self.tableView.safeAreaInsets.left;
    CGFloat trailing = self.tableView.safeAreaInsets.right;
    CGFloat contentWidth = MAX(0, width - leading - trailing);
    self.toolbarPreviewCaption.frame = CGRectMake(leading + 16, 12, MAX(0, contentWidth - 32), 20);
    CGFloat panelHeight = toolbarHeight;
    CGRect toolbarFrame = CGRectMake(leading, 36, contentWidth, toolbarHeight);
    CGRect statusFrame = CGRectMake(leading + 16, 36, MAX(0, contentWidth - 32), toolbarHeight);
    if (!self.topConfiguration) {
        CGFloat leftInset = MIN(DXBottomToolbarLeadingInset, contentWidth);
        CGFloat rightInset = MIN(DXBottomToolbarTrailingInset, MAX(0, contentWidth - leftInset));
        CGFloat stripWidth = MAX(0, contentWidth - leftInset - rightInset);
        panelHeight += DXBottomToolbarBottomInset;
        self.toolbarPreviewDock.frame = CGRectMake(leading, 36, contentWidth, panelHeight);
        toolbarFrame = CGRectMake(leftInset, 0, stripWidth, toolbarHeight);
        statusFrame = CGRectMake(leading + leftInset + 8, 36, MAX(0, stripWidth - 16), toolbarHeight);
        CGFloat buttonHeight = self.toolbarPreview ? self.toolbarPreview.buttonHeight : cellsHeightDefault;
        CGFloat symbolY = DXBottomToolbarCellTopInset + (buttonHeight - 28.0) / 2.0;
        self.toolbarPreviewGlobe.frame = CGRectMake(MAX(0, (leftInset - 28.0) / 2.0), symbolY, 28, 28);
        self.toolbarPreviewDictation.frame = CGRectMake(contentWidth - rightInset + MAX(0, (rightInset - 28.0) / 2.0), symbolY, 28, 28);
    }
    BOOL widthChanged = CGRectGetWidth(self.toolbarPreview.bounds) != CGRectGetWidth(toolbarFrame);
    self.toolbarPreview.frame = toolbarFrame;
    self.toolbarPreviewStatus.frame = statusFrame;
    if (widthChanged) {
        [self.toolbarPreview.collectionViewLayout invalidateLayout];
        [self.toolbarPreview reloadData];
    }
    CGRect headerFrame = CGRectMake(0, 0, width, 36 + panelHeight + 16);
    if (!CGRectEqualToRect(self.toolbarPreviewHeader.frame, headerFrame)) {
        self.toolbarPreviewHeader.frame = headerFrame;
        self.tableView.tableHeaderView = self.toolbarPreviewHeader;
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutToolbarPreviewHeader];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
        [self refreshToolbarPreview];
    }
}

#pragma mark - Test input field

// The test field is the header of the button-settings section, i.e. the middle
// of the page: the sliders being tuned and the field stay on screen together,
// so tapping the field summons the keyboard (with the TypeX toolbar attached)
// right below them for a live preview.
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if (section != 1) return nil;

    CGFloat width = CGRectGetWidth(self.tableView.bounds);
    UIView *block = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, kTestFieldSectionHeaderHeight)];
    block.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UILabel *fieldTitle = [[UILabel alloc] initWithFrame:CGRectMake(16, 10, MAX(0, width - 32), 16)];
    fieldTitle.text = LOCALIZED(@"TEST_INPUT_FIELD");
    fieldTitle.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    fieldTitle.textColor = [UIColor secondaryLabelColor];
    fieldTitle.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [block addSubview:fieldTitle];

    self.testInputField = [[UITextField alloc] initWithFrame:CGRectMake(16, 30, MAX(0, width - 32), 36)];
    self.testInputField.placeholder = LOCALIZED(@"TEST_INPUT_FIELD_PLACEHOLDER");
    self.testInputField.font = [UIFont systemFontOfSize:15];
    self.testInputField.borderStyle = UITextBorderStyleRoundedRect;
    self.testInputField.delegate = self;
    self.testInputField.returnKeyType = UIReturnKeyDone;
    self.testInputField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.testInputField.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [block addSubview:self.testInputField];

    UILabel *sectionTitle = [[UILabel alloc] initWithFrame:CGRectMake(16, 78, MAX(0, width - 32), 18)];
    sectionTitle.text = LOCALIZED(@"BUTTON_SETTINGS");
    sectionTitle.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    sectionTitle.textColor = [UIColor secondaryLabelColor];
    sectionTitle.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [block addSubview:sectionTitle];

    return block;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return section == 1 ? kTestFieldSectionHeaderHeight : UITableViewAutomaticDimension;
}

// On keyboard show the table scrolls the test field to the top and pads the
// bottom inset by the keyboard height, so the button-settings sliders stay
// above the keyboard instead of being covered by it.
- (void)handleKeyboardWillShow:(NSNotification *)notification {
    if (!self.testInputField.isFirstResponder) return;
    [self applyKeyboardInfo:notification.userInfo scrollTestFieldToTop:YES];
}

// Interactive dismissal drags fire repeated frame changes: track the keyboard
// with the inset but never re-scroll mid-drag.
- (void)handleKeyboardFrameWillChange:(NSNotification *)notification {
    if (!self.testInputField.isFirstResponder) return;
    [self applyKeyboardInfo:notification.userInfo scrollTestFieldToTop:NO];
}

- (void)handleKeyboardWillHide:(NSNotification *)notification {
    CGFloat duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] floatValue];
    UIViewAnimationOptions options = [notification.userInfo[UIKeyboardAnimationCurveUserInfoKey] unsignedIntegerValue] << 16;
    [UIView animateWithDuration:duration delay:0 options:options | UIViewAnimationOptionBeginFromCurrentState animations:^{
        UIEdgeInsets inset = self.tableView.contentInset;
        inset.bottom = 0;
        self.tableView.contentInset = inset;
        self.tableView.scrollIndicatorInsets = inset;
    } completion:nil];
}

- (void)applyKeyboardInfo:(NSDictionary *)info scrollTestFieldToTop:(BOOL)scroll {
    CGRect endFrame = [info[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    if (CGRectIsNull(endFrame) || CGRectGetHeight(endFrame) <= 0) return;

    CGFloat duration = [info[UIKeyboardAnimationDurationUserInfoKey] floatValue];
    UIViewAnimationOptions options = [info[UIKeyboardAnimationCurveUserInfoKey] unsignedIntegerValue] << 16;
    CGRect localFrame = [self.tableView convertRect:endFrame fromView:nil];
    CGFloat overlap = MAX(0, CGRectGetMaxY(self.tableView.bounds) - CGRectGetMinY(localFrame));

    [UIView animateWithDuration:duration delay:0 options:options | UIViewAnimationOptionBeginFromCurrentState animations:^{
        UIEdgeInsets inset = self.tableView.contentInset;
        inset.bottom = overlap;
        self.tableView.contentInset = inset;
        self.tableView.scrollIndicatorInsets = inset;

        if (scroll) {
            UIView *block = [self.tableView headerViewForSection:1];
            if (block) {
                CGFloat maxOffset = self.tableView.contentSize.height
                    + self.tableView.adjustedContentInset.bottom
                    - CGRectGetHeight(self.tableView.bounds);
                CGFloat target = MAX(-self.tableView.adjustedContentInset.top,
                                     MIN(CGRectGetMinY(block.frame) - 4.0, MAX(0.0, maxOffset)));
                [self.tableView setContentOffset:CGPointMake(0, target) animated:NO];
            }
        }
    } completion:nil];
}

- (void)textFieldDidBeginEditing:(UITextField *)textField {
    DXPlaceCaretAtEnd(textField);
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

#pragma mark - Toolbar-scoped button settings

// Every appearance key is scoped: the top page writes "top"-prefixed keys, the
// bottom page writes the unprefixed ones. The tweak reads the same scoped keys
// per toolbar, so the two toolbars are styled independently.
- (NSString *)scopedAppearanceKey:(NSString *)baseKey {
    return self.topConfiguration ? [@"top" stringByAppendingString:baseKey] : baseKey;
}

- (BOOL)storedBoolForKey:(NSString *)key fallback:(BOOL)fallback {
    id value = [[DXPrefsManager sharedInstance] getValueForKey:key];
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}

- (NSInteger)enabledButtonCount {
    NSInteger count = 0;
    for (NSDictionary *entry in self.currentOrder.firstObject) {
        if ([entry isKindOfClass:[NSDictionary class]] && ![entry[@"disabled"] boolValue]) count++;
    }
    return count;
}

- (void)buildSettingsRows {
    // The runtime adds +5 to the unprefixed height fallback while the shared
    // background tint is on; mirror that so the slider shows the effective
    // default instead of silently jumping on first drag.
    BOOL backgroundTintOn = [self storedBoolForKey:kColorEnabledkey fallback:NO] &&
                            [self storedBoolForKey:kShortcutsBackgroundTintEnabled fallback:YES];
    float heightDefault = self.topConfiguration ? 33.33
        : (backgroundTintOn ? cellsHeightDefault + 5 : cellsHeightDefault);

    NSMutableArray<DXSettingsRow *> *appearanceRows = [@[
        [DXSettingsRow segmentRowWithKey:[self scopedAppearanceKey:kShortLabelEnabledKey]
                                  label:LOCALIZED(@"DISPLAY_STYLE")
                                 titles:@[LOCALIZED(@"ICON"), LOCALIZED(@"TEXT")]
                           defaultValue:0],
        [DXSettingsRow switchRowWithKey:[self scopedAppearanceKey:kCellBorderEnabledkey]
                                  label:LOCALIZED(@"BORDER_ENABLED") defaultValue:NO],
        [DXSettingsRow sliderRowWithKey:[self scopedAppearanceKey:kCellBorderWidthkey]
                                  label:LOCALIZED(@"BORDER_WIDTH") minValue:0.5 maxValue:10 step:0.5
                            defaultValue:buttonBorderWidthDefault],
        [DXSettingsRow sliderRowWithKey:[self scopedAppearanceKey:kButtonWidthScalekey]
                                  label:LOCALIZED(@"BUTTON_WIDTH") minValue:30 maxValue:100 step:0.5
                            defaultValue:buttonWidthScaleDefault],
        [DXSettingsRow sliderRowWithKey:[self scopedAppearanceKey:kCellHeightkey]
                                  label:LOCALIZED(@"HEIGHT") minValue:25 maxValue:50 step:0.5
                            defaultValue:heightDefault],
        [DXSettingsRow sliderRowWithKey:[self scopedAppearanceKey:kCellRadiuskey]
                                  label:LOCALIZED(@"RADIUS") minValue:0 maxValue:30 step:0.5
                            defaultValue:cellsRadiusDefault],
        [DXSettingsRow sliderRowWithKey:[self scopedAppearanceKey:kCellSpacingkey]
                                  label:LOCALIZED(@"SPACING") minValue:0 maxValue:20 step:0.5
                            defaultValue:spacingBetweenCellsDefault],
    ] mutableCopy];
    if (!self.topConfiguration) [appearanceRows insertObject:
        [DXSettingsRow switchRowWithKey:kFloatingShelfEnabledKey label:LOCALIZED(@"FLOATING_SHELF_SWITCH") defaultValue:NO] atIndex:0];
    if (self.topConfiguration) {
        [appearanceRows addObject:
            [DXSettingsRow sliderRowWithKey:[self scopedAppearanceKey:kBottomSpacingKey]
                                      label:LOCALIZED(@"BOTTOM_SPACING") minValue:0 maxValue:20 step:0.1
                                  defaultValue:topBottomSpacingDefault]];
        // Column count controls the one-row/two-row active capacity.
        [appearanceRows addObject:
            [DXSettingsRow sliderRowWithKey:[self scopedAppearanceKey:kButtonsPerRowKey]
                                      label:LOCALIZED(@"BUTTONS_PER_ROW") minValue:1 maxValue:8 step:1
                                  defaultValue:buttonsPerRowDefault]];
    }
    self.appearanceRows = appearanceRows;

    DXSettingsRow *panelScaleRow = [DXSettingsRow sliderRowWithKey:[self scopedAppearanceKey:kSubActionPanelScaleKey]
                                                              label:LOCALIZED(@"PANEL_SIZE")
                                                           minValue:50 maxValue:120 step:5
                                                        defaultValue:subActionPanelScaleDefault];
    panelScaleRow.valueSuffix = @"%";
    self.panelRows = @[panelScaleRow];

    if (self.topConfiguration) {
        // 顶部固定多行布局，此分组只调整按钮行距；每行个数在按钮设置中调整。
        self.multiRowRows = @[
            [DXSettingsRow sliderRowWithKey:[self scopedAppearanceKey:kMultiRowSpacingKey]
                                      label:LOCALIZED(@"BUTTON_ROW_SPACING") minValue:0 maxValue:20 step:0.1
                                  defaultValue:multiRowSpacingDefault],
        ];
        return;
    }

    // The toolbar height is the only remaining positioning control; the
    // leading/trailing/vertical offsets and the insets are fixed in the tweak.
    self.offsetRows = @[
        [DXSettingsRow sliderRowWithKey:kHeightOffsetkey label:LOCALIZED(@"TOOLBAR_HEIGHT") minValue:50 maxValue:80 step:1 defaultValue:heightOffsetDefault],
    ];
}

- (DXSettingsRow *)settingsRowForIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case 1: return self.appearanceRows[indexPath.row];
        case 2: return self.panelRows[indexPath.row];
        case 3: return self.topConfiguration ? self.multiRowRows[indexPath.row] : self.offsetRows[indexPath.row];
        default: return nil;
    }
}

- (float)storedFloatForRow:(DXSettingsRow *)row {
    id value = [[DXPrefsManager sharedInstance] getValueForKey:row.key];
    return [value respondsToSelector:@selector(floatValue)] ? [value floatValue] : row.defaultValue;
}

static NSString *DXFormatSettingsValue(float value, float step, NSString *suffix) {
    NSString *number = step < 0.99f ? [NSString stringWithFormat:@"%.1f", value]
                                   : [NSString stringWithFormat:@"%.0f", value];
    return suffix.length ? [number stringByAppendingString:suffix] : number;
}

// Snap to the row's step so the stored value matches what the slider showed.
- (void)persistRowValue:(DXSettingsRow *)row rawValue:(float)rawValue {
    float stepped = row.minValue + roundf((rawValue - row.minValue) / row.step) * row.step;
    stepped = MIN(row.maxValue, MAX(row.minValue, stepped));
    [[DXPrefsManager sharedInstance] setValue:@(stepped) forKey:row.key];
}

- (UITableViewCell *)settingsCellForRowAtIndexPath:(NSIndexPath *)indexPath {
    DXSettingsRow *row = [self settingsRowForIndexPath:indexPath];
    if (row.isSwitch) return [self switchCellForRow:row];
    if (row.isSegment) return [self segmentCellForRow:row indexPath:indexPath];

    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"TypeXSettingsSlider" forIndexPath:indexPath];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = nil;

    UILabel *titleLabel = (UILabel *)[cell viewWithTag:1];
    UILabel *valueLabel = (UILabel *)[cell viewWithTag:2];
    UISlider *slider = (UISlider *)[cell viewWithTag:3];
    if (!titleLabel) {
        titleLabel = [[UILabel alloc] init];
        titleLabel.tag = 1;
        titleLabel.font = [UIFont systemFontOfSize:15];
        titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:titleLabel];

        valueLabel = [[UILabel alloc] init];
        valueLabel.tag = 2;
        valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightRegular];
        valueLabel.textColor = [UIColor secondaryLabelColor];
        valueLabel.textAlignment = NSTextAlignmentRight;
        valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:valueLabel];

        slider = [[UISlider alloc] init];
        slider.tag = 3;
        slider.translatesAutoresizingMaskIntoConstraints = NO;
        [slider addTarget:self action:@selector(settingsSliderChanged:) forControlEvents:UIControlEventValueChanged];
        [slider addTarget:self action:@selector(settingsSliderReleased:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
        [slider addTarget:self action:@selector(settingsSliderCancelled:) forControlEvents:UIControlEventTouchCancel];
        [cell.contentView addSubview:slider];

        [NSLayoutConstraint activateConstraints:@[
            [titleLabel.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
            [titleLabel.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [titleLabel.widthAnchor constraintLessThanOrEqualToConstant:110],
            [valueLabel.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
            [valueLabel.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [valueLabel.widthAnchor constraintEqualToConstant:50],
            [slider.leadingAnchor constraintEqualToAnchor:titleLabel.trailingAnchor constant:8],
            [slider.trailingAnchor constraintEqualToAnchor:valueLabel.leadingAnchor constant:-8],
            [slider.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        ]];
    }

    titleLabel.text = row.label;
    slider.minimumValue = row.minValue;
    slider.maximumValue = row.maxValue;
    slider.value = MIN(row.maxValue, MAX(row.minValue, [self storedFloatForRow:row]));
    valueLabel.text = DXFormatSettingsValue(slider.value, row.step, row.valueSuffix);
    objc_setAssociatedObject(slider, @selector(key), row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return cell;
}

- (UITableViewCell *)switchCellForRow:(DXSettingsRow *)row {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"TypeXSettingsSwitch"];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = row.label;
    cell.textLabel.font = [UIFont systemFontOfSize:15];

    UISwitch *switchView = (UISwitch *)cell.accessoryView;
    if (![switchView isKindOfClass:[UISwitch class]]) {
        switchView = [[UISwitch alloc] init];
        cell.accessoryView = switchView;
        [switchView addTarget:self action:@selector(settingsSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    }
    [switchView setOn:[self storedFloatForRow:row] >= 0.5 animated:NO];
    objc_setAssociatedObject(switchView, @selector(key), row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return cell;
}

// Full-width segmented control row (PSSegmentCell style): the control spans
// the cell so the two options are large and obvious, no leading label.
- (UITableViewCell *)segmentCellForRow:(DXSettingsRow *)row indexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"TypeXSettingsSegment" forIndexPath:indexPath];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    UISegmentedControl *segment = (UISegmentedControl *)[cell.contentView viewWithTag:4];
    if (!segment) {
        segment = [[UISegmentedControl alloc] init];
        segment.tag = 4;
        segment.translatesAutoresizingMaskIntoConstraints = NO;
        [segment addTarget:self action:@selector(settingsSegmentChanged:) forControlEvents:UIControlEventValueChanged];
        [cell.contentView addSubview:segment];
        [NSLayoutConstraint activateConstraints:@[
            [segment.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
            [segment.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
            [segment.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:8],
            [segment.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-8],
            [segment.heightAnchor constraintGreaterThanOrEqualToConstant:32],
        ]];
    }
    [segment removeAllSegments];
    [row.segmentTitles enumerateObjectsUsingBlock:^(NSString *title, NSUInteger idx, BOOL *stop) {
        [segment insertSegmentWithTitle:title atIndex:idx animated:NO];
    }];
    NSInteger selected = (NSInteger)[self storedFloatForRow:row];
    segment.selectedSegmentIndex = MAX(0, MIN((NSInteger)row.segmentTitles.count - 1, selected));
    objc_setAssociatedObject(segment, @selector(key), row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return cell;
}

- (void)settingsSwitchChanged:(UISwitch *)sender {
    DXSettingsRow *row = objc_getAssociatedObject(sender, @selector(key));
    [[DXPrefsManager sharedInstance] setValue:@(sender.isOn) forKey:row.key];
    [self refreshToolbarPreview];
}

- (void)settingsSegmentChanged:(UISegmentedControl *)sender {
    DXSettingsRow *row = objc_getAssociatedObject(sender, @selector(key));
    [[DXPrefsManager sharedInstance] setValue:@(sender.selectedSegmentIndex) forKey:row.key];
    [self refreshToolbarPreview];
}

- (void)settingsSliderChanged:(UISlider *)sender {
    // Live label feedback; the preference write itself waits for touch-up so
    // dragging does not spam the preference domain and reload notifications.
    UILabel *valueLabel = (UILabel *)[(UIView *)sender.superview viewWithTag:2];
    DXSettingsRow *row = objc_getAssociatedObject(sender, @selector(key));
    valueLabel.text = DXFormatSettingsValue(sender.value, row.step, row.valueSuffix);
    // Preview the snapped value while dragging without writing preferences or
    // reloading the live keyboard until the existing touch-up save happens.
    if (self.toolbarPreviewPreferences && row.key) {
        NSMutableDictionary *snapshot = [self.toolbarPreviewPreferences mutableCopy];
        float stepped = row.minValue + roundf((sender.value - row.minValue) / row.step) * row.step;
        snapshot[row.key] = @(MIN(row.maxValue, MAX(row.minValue, stepped)));
        [self applyToolbarPreviewPreferences:snapshot];
    }
}

- (void)settingsSliderReleased:(UISlider *)sender {
    DXSettingsRow *row = objc_getAssociatedObject(sender, @selector(key));
    float stepped = row.minValue + roundf((sender.value - row.minValue) / row.step) * row.step;
    stepped = MIN(row.maxValue, MAX(row.minValue, stepped));

    sender.value = stepped;
    UILabel *valueLabel = (UILabel *)[(UIView *)sender.superview viewWithTag:2];
    valueLabel.text = DXFormatSettingsValue(stepped, row.step, row.valueSuffix);
    [self persistRowValue:row rawValue:sender.value];
    if ([row.key isEqualToString:DXScopedPreferenceKey(kButtonsPerRowKey, @"top")]) {
        [self updateOrder:NO];
        [self.tableView reloadData];
    }
    [self refreshToolbarPreview];
}

- (void)settingsSliderCancelled:(UISlider *)sender {
    DXSettingsRow *row = objc_getAssociatedObject(sender, @selector(key));
    sender.value = [self storedFloatForRow:row];
    UILabel *valueLabel = (UILabel *)[sender.superview viewWithTag:2];
    valueLabel.text = DXFormatSettingsValue(sender.value, row.step, row.valueSuffix);
    [self refreshToolbarPreview];
}

#pragma mark - Add button

- (void)addButtonTapped{
    DXPGesturePickerController *gesturePickerController = [[DXPGesturePickerController alloc] init];
    gesturePickerController.fullOrder = self.fullOrder;
    gesturePickerController.configuration = self.topConfiguration ? @"top" : @"bottom";
    // A new button has no action yet: its tap action (chosen in the pushed
    // page) defines it, so the identifier is left nil until the user picks.
    gesturePickerController.pendingNewEntry = YES;
    gesturePickerController.title = LOCALIZED(@"NEW_BUTTON");

    [gesturePickerController setRootController: [self rootController]];
    [gesturePickerController setParentController: [self parentController]];
    [self pushController:gesturePickerController];
}

#pragma mark - Storage

- (void)writeToFile{
    [[DXPrefsManager sharedInstance] setValue:self.currentOrder forKey:self.shortcutsPreferenceKey ?: kShortcutskey];
    [self refreshToolbarPreview];
}

// Removes the per-gesture custom actions and the ordered sub-actions recorded
// for a deleted button so a later re-add starts clean instead of silently
// inheriting old gestures.
- (void)removeCustomActionsForIdentifier:(NSString *)identifier {
    if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0) return;
    NSString *configuration = self.topConfiguration ? @"top" : @"bottom";

    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    for (NSInteger gesture = DXShortcutGestureLongPress; gesture <= DXShortcutGestureTap; gesture++) {
        [keys addObject:DXCustomActionsKeyForGesture((int)gesture, configuration)];
    }
    [keys addObject:DXScopedPreferenceKey(kSubActionskey, configuration)];

    NSMutableDictionary *prefs = [[[DXPrefsManager sharedInstance] readPrefs] mutableCopy] ?: [NSMutableDictionary dictionary];
    BOOL changed = NO;
    for (NSString *key in keys) {
        NSArray *entries = prefs[key];
        if (![entries isKindOfClass:[NSArray class]]) continue;
        NSArray *filtered = [entries filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"identifier != %@", identifier]];
        if (![filtered isEqualToArray:entries]) {
            prefs[key] = filtered;
            changed = YES;
        }
    }
    if (changed) [[DXPrefsManager sharedInstance] writePrefs:prefs];
}

- (void)updateOrder:(BOOL)reset{
    NSMutableDictionary *prefs = [[[DXPrefsManager sharedInstance] readPrefs] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSString *shortcutsKey = self.shortcutsPreferenceKey ?: kShortcutskey;

    DXShortcutsGenerator *shortcutsGenerator = [DXShortcutsGenerator sharedInstance];
    NSMutableArray *defaultOrderLabel = [[shortcutsGenerator labelName] mutableCopy];
    NSMutableArray *defaultOrderSelector = [[shortcutsGenerator selectorNames] mutableCopy];
    NSMutableArray *defaultOrder12 = [[shortcutsGenerator imageNameArrayForiOS:0] mutableCopy];
    NSMutableArray *defaultOrder13 = [[shortcutsGenerator imageNameArrayForiOS:1] mutableCopy];

    NSMutableArray *fullOrderDict = [[NSMutableArray alloc] init];

    for (int i = 0; i < [defaultOrderLabel count]; i++){
        if (DXIsHiddenShortcutSelector(defaultOrderSelector[i])) {
            continue;
        }
        // ShellX 截图按钮只在检测到 com.iosdump.shellx 已安装且总开关开启时进入目录
        if ([defaultOrderSelector[i] isEqualToString:@"shellxScreenshotAction:"] &&
            ![DXShortcutsGenerator isShellXScreenshotAvailable]) {
            continue;
        }
        // 剪贴板按钮只在检测到 Kayoko/KayokoX 已安装时进入目录
        if ([defaultOrderSelector[i] isEqualToString:@"clipboardAction:"] &&
            ![DXShortcutsGenerator isKayokoInstalled]) {
            continue;
        }
        // 小把手按钮只在检测到 PullOver X 已安装时进入目录
        if ([defaultOrderSelector[i] isEqualToString:@"pulloverWakeAction:"] &&
            ![DXShortcutsGenerator isPullOverXInstalled]) {
            continue;
        }
        [fullOrderDict addObject: @{
            @"label" : defaultOrderLabel[i],
            @"images12" : defaultOrder12[i],
            @"images13" : defaultOrder13[i],
            @"selector" : defaultOrderSelector[i],
        }];
    }

    self.fullOrder = fullOrderDict;

    id storedOrder = prefs[shortcutsKey];
    BOOL hasStoredOrder = !reset && [storedOrder isKindOfClass:[NSArray class]] && [storedOrder count] >= 2;
    NSArray *storedEnabled = hasStoredOrder && [storedOrder[0] isKindOfClass:[NSArray class]] ? storedOrder[0] : @[];
    NSArray *storedDisabled = hasStoredOrder && [storedOrder[1] isKindOfClass:[NSArray class]] ? storedOrder[1] : @[];

    NSMutableArray *enabled = [NSMutableArray array];
    NSMutableArray *disabled = [NSMutableArray array];
    NSMutableSet *seenSelectors = [NSMutableSet set];

    if (hasStoredOrder) {
        // The stored list holds every added button, switched on or off; the
        // enable cap is enforced at toggle time, not by trimming the list.
        DXAppendUniqueShortcuts(storedEnabled, enabled, seenSelectors, NSUIntegerMax);
    }
    // Defaults seed only a configuration that was never stored. An explicitly
    // emptied toolbar (user deleted every button) stays empty.
    if (!hasStoredOrder) {
        DXAppendUniqueShortcuts(fullOrderDict, enabled, seenSelectors, maxdefaultshortcuts);
    }

    // Preserve every record while disabling only the overflow.
    enabled = [DXToolbarOrderFittingCapacity(@[enabled, @[]], prefs,
        self.topConfiguration ? @"top" : @"bottom")[0] mutableCopy];

    if (hasStoredOrder) {
        DXAppendUniqueShortcuts(storedDisabled, disabled, seenSelectors, NSUIntegerMax);
    }
    // Compare shortcut identity by selector.  Stored entries from older versions
    // may contain obsolete metadata (for example selectorlp), so dictionary
    // equality would incorrectly append a second copy of the same action.
    DXAppendUniqueShortcuts(fullOrderDict, disabled, seenSelectors, NSUIntegerMax);

    self.currentOrder = [NSMutableArray arrayWithObjects:enabled, disabled, nil];

    // The page only manages the enabled section; the disabled section is kept
    // in the stored schema so the toolbar keeps reading the two-section format.
    NSArray *normalizedOrder = @[[enabled copy], [disabled copy]];
    if (reset || ![storedOrder isEqual:normalizedOrder]) {
        prefs[shortcutsKey] = normalizedOrder;
        [[DXPrefsManager sharedInstance] writePrefs:prefs];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateOrder:NO];
    [self.tableView reloadData];
    [self refreshToolbarPreview];
}

- (void)viewDidLoad {
    self.topConfiguration = [[self.specifier propertyForKey:@"configuration"] isEqualToString:@"top"];
    self.shortcutsPreferenceKey = self.topConfiguration ? kTopShortcutskey : kShortcutskey;
    tweakBundle = [NSBundle bundleWithPath:bundlePath];
    [tweakBundle load];
    [super viewDidLoad];
    self.tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, 0, self.view.frame.size.width, self.view.frame.size.height) style:UITableViewStyleGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    [self.tableView setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"TypeXItemCell"];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"TypeXSettingsSwitch"];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"TypeXSettingsSegment"];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"TypeXSettingsSlider"];
    [self buildSettingsRows];
    [self.tableView setEditing:YES];
    self.tableView.allowsSelectionDuringEditing=YES;

    // Keyboard avoidance for the mid-page test field: track show/frame-change/
    // hide so the button-settings sliders stay above the keyboard while it is
    // open; dragging the table can dismiss the keyboard to see the full list.
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(handleKeyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [center addObserver:self selector:@selector(handleKeyboardFrameWillChange:) name:UIKeyboardWillChangeFrameNotification object:nil];
    [center addObserver:self selector:@selector(handleKeyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];

    ((UIViewController *)self).title = self.topConfiguration ? @"顶部设置" : @"底部设置";
    self.view = self.tableView;
    [self installToolbarPreview];

    self.addBtn = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addButtonTapped)];
    self.navigationItem.rightBarButtonItem = self.addBtn;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
