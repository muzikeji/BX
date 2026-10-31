#import "DXPLinkActionEditorController.h"
#import "DXPActionGroups.h"
#import "DXPActionOrganizationController.h"
#import "DXPAppInfo.h"
#import "DXPOpenAppPickerController.h"
#import "DXPAppShortcutPickerController.h"
#import "DXPSystemActionPickerController.h"
#import "DXPSFSymbolPickerController.h"
#import "DXPIconInputView.h"
#import "DXPKeyboardAvoider.h"
#import "../DXSystemActionCatalog.h"
#import "../DXFloatingAppSession.h"
#import "DXPJavaScriptTestController.h"
#import "../DXHelper.h"
#import "../common.h"

static NSBundle *tweakBundle;

// Typed rows. 0-2 are shared by every type (类型 / 名称 / 图标); the payload
// row depends on the entry's type:
// - urlscheme: section 1 = full-width 文本框 (multi-line payload box), then
//              the 剪切替换 switch (the box types that support @@@)
// - text:      section 1 = ordered records and an Add row
// - url:       3 = URL 设置 (field), 4 = APP内打开 switch, 5 = 剪切替换 switch
// - openapp:   3 = installed-app picker, 4 = MUBX floating switch
// - urlscheme: section 2 = MUBX floating switch
// 剪切替换 appears wherever the payload supports @@@ (legacy / url /
// urlscheme): ON clears the input field after its text is passed in (cut),
// OFF keeps the field's content (copy, the default).
// The box types use two sections: section 0 holds the shared rows, section 1
// the payload box with the type label as its header and hint as its footer.
// Entries without a type keep the legacy layout (动作链接) plus the 剪切替换
// row, so existing definitions keep editing almost exactly as before.
static NSInteger const DXActionRowType = 0;
static NSInteger const DXActionRowName = 1;
static NSInteger const DXActionRowIcon = 2;
static NSInteger const DXActionRowPayload = 3;
static NSInteger const DXActionRowInApp = 4;

static NSInteger const DXLegacyRowName = 0;
static NSInteger const DXLegacyRowIcon = 1;
static NSInteger const DXLegacyRowLink = 2;

// Label left, current value right: the type row and the payload picker rows.
@interface DXPLinkActionValueCell : UITableViewCell
@end

@implementation DXPLinkActionValueCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    return [super initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:reuseIdentifier];
}
@end

// Full-width multi-line text box (a UITextView filling the cell) used for the
// URL scheme / JavaScript payloads instead of a small accessory field.
@interface DXPLinkActionTextCell : UITableViewCell
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UILabel *placeholderLabel;
@end

@implementation DXPLinkActionTextCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        self.textView = [[UITextView alloc] init];
        self.textView.font = [UIFont systemFontOfSize:17];
        self.textView.backgroundColor = UIColor.clearColor;
        self.textView.textContainerInset = UIEdgeInsetsZero;
        self.textView.textContainer.lineFragmentPadding = 0;
        self.textView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:self.textView];

        self.placeholderLabel = [[UILabel alloc] init];
        self.placeholderLabel.font = self.textView.font;
        self.placeholderLabel.textColor = [UIColor placeholderTextColor];
        self.placeholderLabel.numberOfLines = 0;
        self.placeholderLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:self.placeholderLabel];

        [NSLayoutConstraint activateConstraints:@[
            [self.textView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12],
            [self.textView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-12],
            [self.textView.leadingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.leadingAnchor],
            [self.textView.trailingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.trailingAnchor],

            [self.placeholderLabel.topAnchor constraintEqualToAnchor:self.textView.topAnchor],
            [self.placeholderLabel.leadingAnchor constraintEqualToAnchor:self.textView.leadingAnchor],
            [self.placeholderLabel.trailingAnchor constraintEqualToAnchor:self.textView.trailingAnchor],
        ]];
    }
    return self;
}
@end

// A record is edited as literal multiline text. Back cancels this edit;
// Save updates the parent's draft, which is persisted by the action's Save.
@interface DXPTextRecordEditorController : UIViewController
@property (nonatomic, copy) NSString *recordText;
@property (nonatomic, copy) void (^completion)(NSString *text);
@property (nonatomic, strong) UITextView *textView;
@end

@implementation DXPTextRecordEditorController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.textView = [[UITextView alloc] init];
    self.textView.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.textView.text = self.recordText;
    self.textView.textContainerInset = UIEdgeInsetsMake(16, 16, 16, 16);
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    self.textView.smartQuotesType = UITextSmartQuotesTypeNo;
    self.textView.smartDashesType = UITextSmartDashesTypeNo;
    self.textView.autocorrectionType = UITextAutocorrectionTypeNo;
    [self.view addSubview:self.textView];
    [NSLayoutConstraint activateConstraints:@[
        [self.textView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.textView.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
    ]];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:LOCALIZED(@"SAVE")
        style:UIBarButtonItemStyleDone target:self action:@selector(saveTapped)];
}
- (void)saveTapped {
    if (self.completion) self.completion(self.textView.text ?: @"");
    [self.navigationController popViewControllerAnimated:YES];
}
@end

@interface DXPLinkActionEditorController ()
@property (nonatomic, strong) UITableView *tableView;
// 文本记录区头部右上角的 编辑/完成 按钮（原导航栏编辑入口移入此处）。
@property (nonatomic, strong) UIButton *recordsEditButton;
@property (nonatomic, strong) UITextField *nameField;
// 图标行 accessory 由 DXPIconInputView 承载（预览缩略图 + 输入框 + 图标库
// 入口）；iconField 即其 textField，保存/回传逻辑与普通字段保持一致。
@property (nonatomic, strong) UITextField *iconField;
@property (nonatomic, strong) DXPIconInputView *iconInputView;
@property (nonatomic, strong) UITextField *linkField;
@property (nonatomic, strong) UISwitch *inAppSwitch;
@property (nonatomic, strong) UISwitch *floatingSwitch;
@property (nonatomic, strong) UISwitch *cutReplaceSwitch;
@property (nonatomic, copy) NSString *selectedAppName;
// The one payload box cell for URL scheme / JavaScript; kept as a
// property so its text survives cell reuse while scrolling.
@property (nonatomic, strong) DXPLinkActionTextCell *payloadBoxCell;
@property (nonatomic, strong) NSMutableArray<NSString *> *textRecords;
@property (nonatomic, strong) UISegmentedControl *jsInputControl;
@property (nonatomic, strong) UISegmentedControl *jsOutputControl;
// Keeps the 脚本源码 / URL Scheme payload box and the field rows above the
// keyboard: this controller builds its own UITableView, so Preferences does
// no automatic keyboard avoidance for it.
@property (nonatomic, strong) DXPKeyboardAvoider *keyboardAvoider;
@end

@implementation DXPLinkActionEditorController {
    NSString *_displayedType;
}

#pragma mark - Type helpers

+ (void)loadTweakBundle {
    if (!tweakBundle) {
        tweakBundle = [NSBundle bundleWithPath:bundlePath];
        [tweakBundle load];
    }
}

+ (NSString *)displayNameForType:(NSString *)type {
    [self loadTweakBundle];
    if ([type isEqualToString:kCustomActionTypeJavaScript]) return LOCALIZED(@"ACTION_TYPE_JAVASCRIPT");
    if ([type isEqualToString:kCustomActionTypeURLScheme]) return LOCALIZED(@"ACTION_TYPE_URL_SCHEME");
    if ([type isEqualToString:kCustomActionTypeText]) return LOCALIZED(@"ACTION_TYPE_TEXT");
    if ([type isEqualToString:kCustomActionTypeURL]) return LOCALIZED(@"ACTION_TYPE_URL");
    if ([type isEqualToString:kCustomActionTypeOpenApp]) return LOCALIZED(@"ACTION_TYPE_OPEN_APP");
    if ([type isEqualToString:kCustomActionTypeShortcut]) return LOCALIZED(@"ACTION_TYPE_SHORTCUT");
    if ([type isEqualToString:kCustomActionTypeSystem]) return LOCALIZED(@"ACTION_TYPE_SYSTEM");
    return type;
}

+ (NSString *)defaultIconForType:(NSString *)type {
    if ([type isEqualToString:kCustomActionTypeJavaScript]) return @"curlybraces";
    if ([type isEqualToString:kCustomActionTypeText]) return @"doc.text";
    if ([type isEqualToString:kCustomActionTypeURL]) return @"globe";
    if ([type isEqualToString:kCustomActionTypeOpenApp]) return @"app";
    if ([type isEqualToString:kCustomActionTypeShortcut]) return @"bolt.fill";
    if ([type isEqualToString:kCustomActionTypeSystem]) return @"gearshape";
    return @"link";
}

// Used by the management page's 添加 flow: the type is chosen here and is
// then fixed for the entry's life — the editor's 类型 row only displays it.
// The order places URL Scheme first because it is the default for new actions.
// 网页链接不再开放新建（URL Scheme 覆盖 http(s) 载体），存量 url 条目仍按
// 原类型编辑与执行。
+ (void)presentTypeChooserFromController:(UIViewController *)controller
                             currentType:(NSString *)currentType
                              completion:(void (^)(NSString *type))completion {
    [self loadTweakBundle];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:LOCALIZED(@"CHOOSE_ACTION_TYPE")
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    NSArray<NSString *> *types = @[
        kCustomActionTypeURLScheme,
        kCustomActionTypeText,
        kCustomActionTypeOpenApp,
        kCustomActionTypeShortcut,
        kCustomActionTypeSystem,
        kCustomActionTypeJavaScript,
    ];
    for (NSString *type in types) {
        [alert addAction:[UIAlertAction actionWithTitle:[self displayNameForType:type]
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
            if (completion) completion(type);
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:LOCALIZED(@"ANSWER_CANCEL")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Layout

- (BOOL)isLegacyEntry {
    return _displayedType.length == 0;
}

- (BOOL)isSystemEntry { return [_displayedType isEqualToString:kCustomActionTypeSystem]; }

- (BOOL)isTextEntry { return [_displayedType isEqualToString:kCustomActionTypeText]; }

- (BOOL)isJavaScriptEntry { return [_displayedType isEqualToString:kCustomActionTypeJavaScript]; }

- (BOOL)isOpenAppEntry {
    return [_displayedType isEqualToString:kCustomActionTypeOpenApp];
}

- (BOOL)isShortcutEntry {
    return [_displayedType isEqualToString:kCustomActionTypeShortcut];
}

- (NSInteger)rowCount {
    if (self.isLegacyEntry) return DXLegacyRowLink + 1 + (self.hasCutReplaceSwitch ? 1 : 0);
    BOOL hasSwitch = [_displayedType isEqualToString:kCustomActionTypeURL] ||
        self.isOpenAppEntry;
    NSInteger rows = DXActionRowPayload + 1 + (hasSwitch ? 1 : 0);
    if (self.hasCutReplaceSwitch) rows++;
    return rows;
}

// 剪切替换 is offered wherever the payload can pull in the field's text via
// @@@: legacy auto-detecting links, url, and url scheme. text stores
// literal records and openapp carries a bundle identifier, so neither ever
// reads the field through @@@ and neither gets the row.
- (BOOL)hasCutReplaceSwitch {
    if (self.isLegacyEntry) return YES;
    return [_displayedType isEqualToString:kCustomActionTypeURL] ||
        [_displayedType isEqualToString:kCustomActionTypeURLScheme];
}

// Last row of the single-section layouts (after 动作链接 or APP内打开); for
// the box layout it follows the payload box in section 1.
- (BOOL)isCutReplaceRow:(NSIndexPath *)indexPath {
    if (![self hasCutReplaceSwitch]) return NO;
    if ([self usesLargePayloadBox]) return indexPath.section == 1 && indexPath.row == 1;
    return indexPath.row == [self rowCount] - 1;
}

- (NSString *)typeFooter {
    if (self.isJavaScriptEntry) return LOCALIZED(@"JS_HELP");
    if (self.isLegacyEntry) return LOCALIZED(@"CUSTOM_LINK_ACTION_FOOTER");
    if ([_displayedType isEqualToString:kCustomActionTypeURLScheme]) return LOCALIZED(@"TYPE_FOOTER_URL_SCHEME");
    if ([_displayedType isEqualToString:kCustomActionTypeText]) return LOCALIZED(@"TYPE_FOOTER_TEXT");
    if ([_displayedType isEqualToString:kCustomActionTypeURL]) return LOCALIZED(@"TYPE_FOOTER_URL");
    if (self.isOpenAppEntry) return LOCALIZED(@"TYPE_FOOTER_OPEN_APP");
    if (self.isShortcutEntry) return LOCALIZED(@"TYPE_FOOTER_SHORTCUT");
    if (self.isSystemEntry) return LOCALIZED(@"TYPE_FOOTER_SYSTEM");
    return nil;
}

- (UITextField *)fieldForRow:(NSInteger)row {
    if (self.isLegacyEntry) {
        if (row == DXLegacyRowName) return self.nameField;
        if (row == DXLegacyRowIcon) return self.iconField;
        if (row == DXLegacyRowLink) return self.linkField;
        return nil;
    }
    if (row == DXActionRowName) return self.nameField;
    if (row == DXActionRowIcon) return self.iconField;
    if (row == DXActionRowPayload && !self.isOpenAppEntry && !self.isShortcutEntry && !self.isSystemEntry) return self.linkField;
    return nil;
}

- (NSString *)labelForRow:(NSInteger)row {
    if (self.isLegacyEntry) {
        if (row == DXLegacyRowName) return LOCALIZED(@"NAME");
        if (row == DXLegacyRowIcon) return LOCALIZED(@"ICON");
        return LOCALIZED(@"ACTION_LINK");
    }
    if (row == DXActionRowType) return LOCALIZED(@"ACTION_TYPE");
    if (row == DXActionRowName) return LOCALIZED(@"NAME");
    if (row == DXActionRowIcon) return LOCALIZED(@"ICON");
    if (row == DXActionRowPayload) {
        if ([_displayedType isEqualToString:kCustomActionTypeURLScheme]) return LOCALIZED(@"URL_SCHEME_SETTINGS");
        if ([_displayedType isEqualToString:kCustomActionTypeText]) return LOCALIZED(@"TEXT_SETTINGS");
        if ([_displayedType isEqualToString:kCustomActionTypeURL]) return LOCALIZED(@"URL_SETTINGS");
        if (self.isOpenAppEntry) return LOCALIZED(@"SELECT_APP");
        if (self.isShortcutEntry) return LOCALIZED(@"SELECT_SHORTCUT");
        if (self.isSystemEntry) return LOCALIZED(@"SELECT_SYSTEM_ACTION");
    }
    if (row == DXActionRowInApp) {
        return self.isOpenAppEntry ? LOCALIZED(@"OPEN_FLOATING_APP") : LOCALIZED(@"OPEN_IN_APP");
    }
    return @"";
}

// Adjust keyboard and placeholder so the payload field matches the type.
- (void)applyTypeToPayloadField {
    if (!self.linkField) return;
    NSString *placeholder = @"";
    if ([_displayedType isEqualToString:kCustomActionTypeURLScheme]) placeholder = @"example://open";
    else if ([_displayedType isEqualToString:kCustomActionTypeURL]) placeholder = @"https://";
    self.linkField.placeholder = placeholder;
    self.linkField.keyboardType = UIKeyboardTypeURL;
}

#pragma mark - Payload layout

// URL scheme and JavaScript payloads use the full-width multi-line text box
// (two-section layout) instead of a small accessory field.
- (BOOL)usesLargePayloadBox {
    return !self.isLegacyEntry &&
        (self.isJavaScriptEntry || [_displayedType isEqualToString:kCustomActionTypeURLScheme]);
}

// The payload value lives in the box for box types, in the small field
// elsewhere; both trim the same way on save.
- (NSString *)payloadCurrentValue {
    if (self.isTextEntry || self.isSystemEntry) return @"";
    if (self.isJavaScriptEntry) return self.payloadBoxCell.textView.text ?: self.entry[@"script"] ?: @"";
    if (self.usesLargePayloadBox) return [self trimmedValue:self.payloadBoxCell.textView.text];
    return [self trimmedValue:self.linkField.text];
}

- (NSString *)payloadBoxPlaceholder {
    if ([_displayedType isEqualToString:kCustomActionTypeURLScheme]) return @"example://open";
    return @"";
}

#pragma mark - Table view

- (NSInteger)payloadSectionCount {
    if (self.isTextEntry) return 2;
    if (self.isJavaScriptEntry) return 3;
    if ([_displayedType isEqualToString:kCustomActionTypeURLScheme]) return 3;
    return [self usesLargePayloadBox] ? 2 : 1;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return self.payloadSectionCount + 1; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == self.payloadSectionCount) return 1;
    if (self.isTextEntry) return section == 0 ? DXActionRowPayload : self.textRecords.count + 1;
    if (self.isJavaScriptEntry && section == 2) return 3;
    if ([_displayedType isEqualToString:kCustomActionTypeURLScheme] && section == 2) return 1;
    if (![self usesLargePayloadBox]) return [self rowCount];
    // Box layout: section 0 holds the shared rows (类型/名称/图标), section 1
    // the payload box followed by the 剪切替换 switch when the type supports @@@.
    return section == 0 ? DXActionRowPayload : (self.hasCutReplaceSwitch ? 2 : 1);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == self.payloadSectionCount) return LOCALIZED(@"ACTION_GROUP");
    if (self.isTextEntry) return section == 1 ? LOCALIZED(@"TEXT_RECORDS") : nil;
    if (self.isJavaScriptEntry && section == 1) return LOCALIZED(@"JS_SOURCE");
    if (self.isJavaScriptEntry && section == 2) return LOCALIZED(@"JS_BEHAVIOR");
    if ([_displayedType isEqualToString:kCustomActionTypeURLScheme] && section == 2) return nil;
    if (![self usesLargePayloadBox] || section == 0) return nil;
    return [_displayedType isEqualToString:kCustomActionTypeURLScheme]
        ? LOCALIZED(@"URL_SCHEME_SETTINGS") : LOCALIZED(@"TEXT_SETTINGS");
}

// 文本记录区的分区头：标题左侧、编辑/完成 按钮右侧。返回 nil 的分区自动回退
// 到 titleForHeaderInSection，其余类型的头部不受影响。
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if (!self.isTextEntry || section != 1) return nil;

    UIView *header = [[UIView alloc] init];
    header.layoutMargins = UIEdgeInsetsMake(4, 20, 2, 20);

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.font = [UIFont systemFontOfSize:13];
    titleLabel.textColor = UIColor.secondaryLabelColor;
    titleLabel.text = LOCALIZED(@"TEXT_RECORDS");
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:titleLabel];

    UIButton *editButton = [UIButton buttonWithType:UIButtonTypeSystem];
    editButton.titleLabel.font = [UIFont systemFontOfSize:15];
    [editButton setTitle:LOCALIZED(self.isEditing ? @"DONE" : @"EDIT") forState:UIControlStateNormal];
    [editButton addTarget:self action:@selector(toggleRecordsEditing) forControlEvents:UIControlEventTouchUpInside];
    self.recordsEditButton = editButton;
    editButton.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:editButton];

    [titleLabel.topAnchor constraintEqualToAnchor:header.layoutMarginsGuide.topAnchor].active = YES;
    [titleLabel.bottomAnchor constraintEqualToAnchor:header.layoutMarginsGuide.bottomAnchor].active = YES;
    [titleLabel.leadingAnchor constraintEqualToAnchor:header.layoutMarginsGuide.leadingAnchor].active = YES;
    [editButton.centerYAnchor constraintEqualToAnchor:header.centerYAnchor].active = YES;
    [editButton.trailingAnchor constraintEqualToAnchor:header.layoutMarginsGuide.trailingAnchor].active = YES;
    return header;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    // 代码创建的 UITableView 对自定 header view 的自增高在实机上不可靠（无
    // estimatedSectionHeaderHeight 时按 0 处理），而编辑入口就在这个头部里，
    // 高度塌陷会让删除/拖动排序整体不可达——必须给显式高度。
    if (self.isTextEntry && section == 1) return 34;
    return UITableViewAutomaticDimension;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == self.payloadSectionCount) return nil;
    // The type hint describes the payload, so it follows the payload: on the
    // box section for box types, on the single section otherwise.
    if (self.isTextEntry || [self usesLargePayloadBox]) return section == 1 ? [self typeFooter] : nil;
    return section == 0 ? [self typeFooter] : nil;
}

// Only the payload box gets a custom height; every other row (including the
// 剪切替换 row that follows it) keeps the system self-sizing it used before.
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == self.payloadSectionCount) return 44;
    if (self.isTextEntry && indexPath.section == 1) return indexPath.row < (NSInteger)self.textRecords.count ? 76 : 44;
    if (self.isJavaScriptEntry && indexPath.section == 1) return 260;
    if ([self usesLargePayloadBox] && indexPath.section == 1 && indexPath.row == 0) return 120.0;
    return UITableViewAutomaticDimension;
}

- (UITableViewCell *)fieldCellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"DXPLinkActionFieldCell" forIndexPath:indexPath];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.imageView.image = nil;
    cell.detailTextLabel.text = nil;
    cell.textLabel.text = [self labelForRow:indexPath.row];
    cell.textLabel.font = [UIFont systemFontOfSize:16];
    cell.accessoryView = [self fieldForRow:indexPath.row] == self.iconField
        ? [self iconAccessoryView]
        : [self fieldForRow:indexPath.row];
    return cell;
}

// The payload box is a single fixed cell: keeping it in a property preserves
// its text across table reloads, and its placeholder tracks the text.
- (UITableViewCell *)payloadBoxCellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!self.payloadBoxCell) {
        self.payloadBoxCell = [self.tableView dequeueReusableCellWithIdentifier:@"DXPLinkActionTextCell" forIndexPath:indexPath];
        self.payloadBoxCell.textView.delegate = self;
        NSString *key = self.isJavaScriptEntry ? @"script" : @"link";
        self.payloadBoxCell.textView.text = [self.entry[key] isKindOfClass:[NSString class]] ? self.entry[key] : @"";
        if (self.isJavaScriptEntry) {
            UITextView *text = self.payloadBoxCell.textView;
            text.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
            text.autocorrectionType = UITextAutocorrectionTypeNo;
            text.autocapitalizationType = UITextAutocapitalizationTypeNone;
            text.smartQuotesType = UITextSmartQuotesTypeNo;
            text.smartDashesType = UITextSmartDashesTypeNo;
            text.smartInsertDeleteType = UITextSmartInsertDeleteTypeNo;
        }
    }
    NSString *placeholder = [self payloadBoxPlaceholder];
    self.payloadBoxCell.placeholderLabel.text = placeholder;
    self.payloadBoxCell.placeholderLabel.hidden = placeholder.length == 0 || self.payloadBoxCell.textView.text.length > 0;
    return self.payloadBoxCell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == self.payloadSectionCount) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"DXPLinkActionValueCell" forIndexPath:indexPath];
        cell.textLabel.text = LOCALIZED(@"ACTION_GROUP");
        NSString *group = DXActionGroupNormalizedName(self.entry[kCustomActionGroupKey]);
        cell.detailTextLabel.text = group.length ? group : LOCALIZED(@"UNGROUPED");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    if ([_displayedType isEqualToString:kCustomActionTypeURLScheme] && indexPath.section == 2) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.textLabel.text = LOCALIZED(@"OPEN_FLOATING_APP");
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.accessoryView = self.floatingSwitch;
        return cell;
    }
    if (self.isTextEntry && indexPath.section == 1) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
        if (indexPath.row == (NSInteger)self.textRecords.count) {
            cell.textLabel.text = LOCALIZED(@"TEXT_RECORD_ADD");
            cell.textLabel.textColor = self.view.tintColor;
            cell.imageView.image = [UIImage systemImageNamed:@"plus.circle"];
        } else {
            NSString *text = self.textRecords[indexPath.row];
            if (text.length) {
                cell.textLabel.text = text;
                cell.textLabel.numberOfLines = 3;
            } else {
                cell.textLabel.text = LOCALIZED(@"TEXT_RECORD_EMPTY");
                cell.textLabel.textColor = UIColor.secondaryLabelColor;
            }
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        return cell;
    }
    if (self.isJavaScriptEntry && indexPath.section == 2) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.textLabel.text = LOCALIZED(indexPath.row == 0 ? @"JS_INPUT" : indexPath.row == 1 ? @"JS_OUTPUT" : @"JS_TEST");
        cell.accessoryView = indexPath.row == 0 ? self.jsInputControl : indexPath.row == 1 ? self.jsOutputControl : nil;
        cell.accessoryType = indexPath.row == 2 ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
        return cell;
    }
    // The 剪切替换 row shares section 1 with the payload box on box types, so
    // it must be intercepted before the box cell short-circuit below.
    if ([self isCutReplaceRow:indexPath]) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"DXPLinkActionFieldCell" forIndexPath:indexPath];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = LOCALIZED(@"CUT_REPLACE_FIELD");
        cell.textLabel.font = [UIFont systemFontOfSize:16];
        cell.imageView.image = nil;
        cell.detailTextLabel.text = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.accessoryView = self.cutReplaceSwitch;
        return cell;
    }

    if ([self usesLargePayloadBox] && indexPath.section == 1) {
        return [self payloadBoxCellForRowAtIndexPath:indexPath];
    }

    // Box layout reaches here only for section 0, whose rows keep the shared
    // indices; single-section typed entries use indexPath.row directly.
    NSInteger row = indexPath.row;

    if (row == DXActionRowType && !self.isLegacyEntry) {
        // The type is fixed for the life of the entry (chosen in the 添加
        // flow's type chooser); the row only displays it and is never tappable.
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"DXPLinkActionValueCell" forIndexPath:indexPath];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = [self labelForRow:row];
        cell.textLabel.font = [UIFont systemFontOfSize:16];
        cell.detailTextLabel.text = [DXPLinkActionEditorController displayNameForType:_displayedType];
        cell.imageView.image = nil;
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    if (row == DXActionRowPayload && (self.isOpenAppEntry || self.isShortcutEntry)) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"DXPLinkActionValueCell" forIndexPath:indexPath];
        NSString *bundleIdentifier = [self trimmedValue:self.linkField.text];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.textLabel.text = [self labelForRow:row];
        cell.textLabel.font = [UIFont systemFontOfSize:16];
        NSString *selection = self.selectedAppName;
        if (self.isShortcutEntry) {
            NSString *title = [self.entry[kCustomActionShortcutTitleKey] isKindOfClass:NSString.class]
                ? self.entry[kCustomActionShortcutTitleKey] : self.entry[kCustomActionShortcutTypeKey];
            if ([title isKindOfClass:NSString.class] && title.length) {
                selection = [NSString stringWithFormat:@"%@ · %@", selection ?: bundleIdentifier, title];
            } else selection = nil;
        }
        cell.detailTextLabel.text = selection.length ? selection : LOCALIZED(@"UNSELECTED");
        cell.imageView.image = bundleIdentifier.length ? [DXPAppInfo iconForBundleID:bundleIdentifier] : nil;
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    if (row == DXActionRowPayload && self.isSystemEntry) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"DXPLinkActionValueCell" forIndexPath:indexPath];
        NSDictionary *action = DXSystemActionDefinition(self.entry[kCustomActionSystemIdentifierKey]);
        cell.textLabel.text = LOCALIZED(@"SELECT_SYSTEM_ACTION");
        cell.detailTextLabel.text = action ? LOCALIZED(action[@"title"]) : LOCALIZED(@"UNSELECTED");
        cell.imageView.image = action ? [UIImage systemImageNamed:action[@"icon"]] : nil;
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }
    if (row == DXActionRowInApp && !self.isLegacyEntry) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"DXPLinkActionFieldCell" forIndexPath:indexPath];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = [self labelForRow:row];
        cell.textLabel.font = [UIFont systemFontOfSize:16];
        cell.imageView.image = nil;
        cell.detailTextLabel.text = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.accessoryView = self.isOpenAppEntry ? self.floatingSwitch : self.inAppSwitch;
        return cell;
    }
    return [self fieldCellForRowAtIndexPath:indexPath];
}

#pragma mark - Row actions

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == self.payloadSectionCount) {
        [self.view endEditing:YES];
        NSDictionary *prefs = [DXPrefsManager.sharedInstance readPrefs];
        NSMutableArray *groups = [DXActionGroupNames(prefs, DXActionMutableDefinitions(prefs)) mutableCopy];
        for (NSString *name in self.pendingGroupNames) if (![groups containsObject:name]) [groups addObject:name];
        __weak typeof(self) weakSelf = self;
        DXPPresentActionGroupChooser(self, groups, DXActionGroupNormalizedName(self.entry[kCustomActionGroupKey]),
            ^(NSString *group, BOOL created) {
                __strong typeof(weakSelf) owner = weakSelf;
                if (!owner) return;
                if (group.length) owner.entry[kCustomActionGroupKey] = group;
                else [owner.entry removeObjectForKey:kCustomActionGroupKey];
                if (created) owner.pendingGroupNames = [(owner.pendingGroupNames ?: @[]) arrayByAddingObject:group];
                [owner.tableView reloadData];
            });
        return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ([_displayedType isEqualToString:kCustomActionTypeURLScheme] && indexPath.section == 2) return;
    if (self.isTextEntry && indexPath.section == 1) {
        if (self.tableView.editing) return; // 编辑态只有删除圆圈与拖动把手，不进内容编辑
        [self.view endEditing:YES];
        NSUInteger index = indexPath.row;
        BOOL adding = index == self.textRecords.count;
        DXPTextRecordEditorController *editor = [DXPTextRecordEditorController new];
        editor.title = adding ? LOCALIZED(@"TEXT_RECORD_ADD")
            : [NSString stringWithFormat:LOCALIZED(@"TEXT_RECORD_NUMBER"), (long)index + 1];
        editor.recordText = adding ? @"" : self.textRecords[index];
        __weak typeof(self) weakSelf = self;
        editor.completion = ^(NSString *text) {
            typeof(self) owner = weakSelf;
            if (!owner) return;
            if (adding) [owner.textRecords addObject:text];
            else if (index < owner.textRecords.count) owner.textRecords[index] = text;
            [owner.tableView reloadData];
        };
        [self.navigationController pushViewController:editor animated:YES];
        return;
    }

    if (self.isJavaScriptEntry && indexPath.section == 2) {
        if (indexPath.row == 2) {
            DXPJavaScriptTestController *test = [DXPJavaScriptTestController new];
            test.source = [self payloadCurrentValue];
            [self.navigationController pushViewController:test animated:YES];
        }
        return;
    }

    // The payload box row handles its own taps (the text view takes focus).
    if ([self usesLargePayloadBox] && indexPath.section == 1) return;
    if (self.isSystemEntry && indexPath.row == DXActionRowPayload) {
        [self.view endEditing:YES];
        DXPSystemActionPickerController *picker = [DXPSystemActionPickerController new];
        picker.selectedIdentifier = self.entry[kCustomActionSystemIdentifierKey];
        __weak typeof(self) weakSelf = self;
        picker.completion = ^(NSDictionary *action) {
            typeof(self) owner = weakSelf;
            if (!owner || !DXSystemActionDefinition(action[@"id"])) return;
            NSDictionary *old = DXSystemActionDefinition(owner.entry[kCustomActionSystemIdentifierKey]);
            NSString *name = [owner trimmedValue:owner.nameField.text];
            if (!name.length || [name isEqual:LOCALIZED(@"DEFAULT_BUTTON_NAME")] ||
                [name isEqual:LOCALIZED(@"ACTION_TYPE_SYSTEM")] || (old && [name isEqual:LOCALIZED(old[@"title"])]))
                owner.nameField.text = LOCALIZED(action[@"title"]);
            owner.entry[kCustomActionSystemIdentifierKey] = action[@"id"];
            owner.iconField.text = action[@"icon"];
            [owner refreshIconPreview];
            [owner.tableView reloadData];
        };
        [picker setRootController:[self rootController]];
        [picker setParentController:[self parentController]];
        [self pushController:picker];
        return;
    }
    if (self.isShortcutEntry && indexPath.row == DXActionRowPayload) {
        [self.view endEditing:YES];
        DXPAppShortcutPickerController *picker = [DXPAppShortcutPickerController new];
        picker.selectedBundleIdentifier = [self trimmedValue:self.linkField.text];
        picker.selectedShortcutType = self.entry[kCustomActionShortcutTypeKey];
        __weak typeof(self) weakSelf = self;
        picker.completion = ^(NSString *bundleIdentifier, NSString *appName, DXPAppShortcutItem *item) {
            typeof(self) view = weakSelf;
            if (!view) return;
            NSString *currentName = [view trimmedValue:view.nameField.text];
            NSString *oldTitle = view.entry[kCustomActionShortcutTitleKey];
            BOOL replaceName = !currentName.length || [currentName isEqualToString:LOCALIZED(@"DEFAULT_BUTTON_NAME")] ||
                [currentName isEqualToString:LOCALIZED(@"ACTION_TYPE_SHORTCUT")] || [currentName isEqualToString:oldTitle];
            view.linkField.text = bundleIdentifier;
            view.selectedAppName = appName;
            view.entry[kCustomActionShortcutTypeKey] = item.type;
            view.entry[kCustomActionShortcutTitleKey] = item.title;
            view.iconField.text = bundleIdentifier;
            if (replaceName) view.nameField.text = item.title;
            [view refreshIconPreview];
            [view.tableView reloadData];
        };
        [picker setRootController:[self rootController]];
        [picker setParentController:[self parentController]];
        [self pushController:picker];
        return;
    }
    if (self.isOpenAppEntry && indexPath.row == DXActionRowPayload) {
        DXPOpenAppPickerController *picker = [[DXPOpenAppPickerController alloc] init];
        picker.selectedBundleIdentifier = [self trimmedValue:self.linkField.text];
        __weak typeof(self) weakSelf = self;
        picker.completion = ^(DXPAppInfo *app) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || app.bundleID.length == 0) return;

            NSString *currentName = [strongSelf trimmedValue:strongSelf.nameField.text];
            BOOL replaceDefaultName = currentName.length == 0 ||
                [currentName isEqualToString:LOCALIZED(@"DEFAULT_BUTTON_NAME")] ||
                [currentName isEqualToString:LOCALIZED(@"OPEN_APP")];
            strongSelf.linkField.text = app.bundleID;
            strongSelf.selectedAppName = app.name.length ? app.name : app.bundleID;
            strongSelf.iconField.text = app.bundleID;
            if (replaceDefaultName) strongSelf.nameField.text = strongSelf.selectedAppName;
            [strongSelf refreshIconPreview];
            [strongSelf.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:DXActionRowPayload inSection:0]]
                                         withRowAnimation:UITableViewRowAnimationNone];
        };
        [picker setRootController:[self rootController]];
        [picker setParentController:[self parentController]];
        [self pushController:picker];
    }
}

- (void)inAppSwitchChanged:(UISwitch *)sender {
    // The value is committed on Save together with the rest of the entry.
    (void)sender;
}

- (void)showSelectAppRequiredAlert {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:LOCALIZED(@"SELECT_APP")
                                                                   message:LOCALIZED(@"SELECT_APP_REQUIRED")
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:LOCALIZED(@"ANSWER_OK")
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// Record management never edits the shared name/icon rows.
- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    [super setEditing:editing animated:animated];
    [self.view endEditing:YES];
    [self.tableView setEditing:editing animated:animated];
    [self.recordsEditButton setTitle:LOCALIZED(editing ? @"DONE" : @"EDIT") forState:UIControlStateNormal];
}

// 文本记录区头部的 编辑/完成 按钮：与原导航栏 editButtonItem 同一
// setEditing: 通道，记录行的删除/拖动排序行为不变。
- (void)toggleRecordsEditing {
    [self setEditing:!self.isEditing animated:YES];
}
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)path {
    return self.isTextEntry && path.section == 1 && path.row < (NSInteger)self.textRecords.count;
}
- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)path {
    return [self tableView:tableView canEditRowAtIndexPath:path];
}
- (NSIndexPath *)tableView:(UITableView *)tableView targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)source
      toProposedIndexPath:(NSIndexPath *)destination {
    if (destination.section != 1) return source;
    return [NSIndexPath indexPathForRow:MIN(destination.row, (NSInteger)self.textRecords.count - 1) inSection:1];
}
- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)source toIndexPath:(NSIndexPath *)destination {
    NSString *record = self.textRecords[source.row];
    [self.textRecords removeObjectAtIndex:source.row];
    [self.textRecords insertObject:record atIndex:destination.row];
    [tableView reloadData];
}
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)path {
    if (style != UITableViewCellEditingStyleDelete || ![self tableView:tableView canEditRowAtIndexPath:path]) return;
    [self.textRecords removeObjectAtIndex:path.row];
    if (!self.textRecords.count) [self.textRecords addObject:@""];
    [tableView reloadData];
}

#pragma mark - Text view

- (void)textViewDidChange:(UITextView *)textView {
    self.payloadBoxCell.placeholderLabel.hidden =
        self.payloadBoxCell.placeholderLabel.text.length == 0 || textView.text.length > 0;
}

#pragma mark - Text fields

// Program-filled fields would otherwise start with the caret at the very
// beginning of the text.
- (void)textFieldDidBeginEditing:(UITextField *)textField {
    DXPlaceCaretAtEnd(textField);
}

- (void)textViewDidBeginEditing:(UITextView *)textView {
    if (!self.isJavaScriptEntry) DXPlaceCaretAtEnd(textView);
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if (textField == self.nameField) [self.iconField becomeFirstResponder];
    else if (textField == self.iconField) {
        // The box takes the return-key handoff for box types; the small
        // payload field elsewhere.
        if ([self usesLargePayloadBox]) [self.payloadBoxCell.textView becomeFirstResponder];
        else {
            UITextField *payload = self.isLegacyEntry ? self.linkField : [self fieldForRow:DXActionRowPayload];
            if (payload) [payload becomeFirstResponder];
            else [textField resignFirstResponder];
        }
    }
    else [textField resignFirstResponder];
    return YES;
}

- (NSString *)trimmedValue:(NSString *)value {
    if (![value isKindOfClass:[NSString class]]) return @"";
    return [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

#pragma mark - Save

- (void)saveTapped {
    [self.view endEditing:YES];

    NSString *name = [self trimmedValue:self.nameField.text];
    NSString *icon = [self trimmedValue:self.iconField.text];
    NSString *link = [self payloadCurrentValue];
    if (self.isSystemEntry && !DXSystemActionDefinition(self.entry[kCustomActionSystemIdentifierKey])) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:LOCALIZED(@"SELECT_SYSTEM_ACTION")
            message:LOCALIZED(@"SELECT_SYSTEM_ACTION_REQUIRED") preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:LOCALIZED(@"ANSWER_OK") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    if (self.isTextEntry) {
        for (NSString *record in self.textRecords) {
            if (record.length) continue;
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:LOCALIZED(@"TEXT_RECORDS")
                message:LOCALIZED(@"TEXT_RECORD_REQUIRED") preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:LOCALIZED(@"ANSWER_OK") style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
            return;
        }
    }
    if (self.isJavaScriptEntry && (link.length == 0 || link.length > 131072)) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:LOCALIZED(@"ACTION_TYPE_JAVASCRIPT") message:LOCALIZED(@"JS_SOURCE_INVALID") preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:LOCALIZED(@"ANSWER_OK") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil]; return;
    }
    if (self.isShortcutEntry && (!DXIsValidBundleIdentifier(link) || link.length > 256 ||
        !DXIsValidAppShortcutType(self.entry[kCustomActionShortcutTypeKey]))) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:LOCALIZED(@"SELECT_SHORTCUT")
            message:LOCALIZED(@"SELECT_SHORTCUT_REQUIRED") preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:LOCALIZED(@"ANSWER_OK") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    if (self.isOpenAppEntry && !DXIsValidBundleIdentifier(link)) {
        [self showSelectAppRequiredAlert];
        return;
    }
    if (name.length == 0) name = LOCALIZED(@"DEFAULT_BUTTON_NAME");
    // SF Symbol names and app bundle identifiers are both accepted; anything
    // else resets to the "link" default. A bundle-ID icon is loaded once
    // here so its PNG lands in the shared snapshot for sandboxed toolbar hosts.
    NSString *defaultIcon = [DXPLinkActionEditorController defaultIconForType:_displayedType];
    if (icon.length > 0) {
        NSString *bundleID = [DXHelper appIconBundleIDForShortcutItem:@{@"icon": icon}];
        if (bundleID) {
            [DXHelper appIconImageForBundleID:bundleID];
        } else if (![DXHelper customIconForShortcutItem:@{@"icon": icon}]) {
            icon = defaultIcon;
        }
    } else {
        icon = defaultIcon;
    }

    NSMutableDictionary *updated = [self.entry mutableCopy] ?: [NSMutableDictionary dictionary];
    NSDictionary *live = [DXPrefsManager.sharedInstance readPrefs];
    NSString *group = DXActionValidatedDraftGroup(live, updated[kCustomActionGroupKey], self.pendingGroupNames);
    if (group.length) updated[kCustomActionGroupKey] = group;
    else [updated removeObjectForKey:kCustomActionGroupKey];
    updated[@"name"] = name;
    updated[@"icon"] = icon;
    updated[@"link"] = link;
    if (self.isSystemEntry) [updated removeObjectForKey:@"link"];
    else [updated removeObjectForKey:kCustomActionSystemIdentifierKey];
    if (self.isTextEntry) {
        updated[kCustomActionTextRecordsKey] = [self.textRecords copy];
        [updated removeObjectForKey:@"link"];
    }
    if (self.isJavaScriptEntry) {
        updated[@"link"] = @"";
        updated[@"script"] = link;
        updated[@"jsInput"] = @[@"auto", @"all", @"clipboard"][MAX(0, self.jsInputControl.selectedSegmentIndex)];
        updated[@"jsOutput"] = @[@"replace", @"insert", @"copy"][MAX(0, self.jsOutputControl.selectedSegmentIndex)];
    }
    if (!self.isShortcutEntry) {
        [updated removeObjectForKey:kCustomActionShortcutTypeKey];
        [updated removeObjectForKey:kCustomActionShortcutTitleKey];
    }
    if (self.isLegacyEntry) {
        [updated removeObjectForKey:kCustomActionTypeKey];
        [updated removeObjectForKey:kCustomActionInAppKey];
        [updated removeObjectForKey:kCustomActionUsePullOverKey];
        [updated removeObjectForKey:kCustomActionFloatingKey];
        // Legacy payloads support @@@, so the 剪切替换 choice applies to them.
        updated[kCustomActionCutReplaceKey] = @(self.cutReplaceSwitch.on);
    } else {
        updated[kCustomActionTypeKey] = _displayedType;
        if ([_displayedType isEqualToString:kCustomActionTypeURL]) {
            updated[kCustomActionInAppKey] = @(self.inAppSwitch.on);
        } else {
            [updated removeObjectForKey:kCustomActionInAppKey];
        }
        [updated removeObjectForKey:kCustomActionUsePullOverKey];
        if (self.isOpenAppEntry || [_displayedType isEqualToString:kCustomActionTypeURLScheme])
            updated[kCustomActionFloatingKey] = @(self.floatingSwitch.on);
        else [updated removeObjectForKey:kCustomActionFloatingKey];
        if (self.hasCutReplaceSwitch) {
            updated[kCustomActionCutReplaceKey] = @(self.cutReplaceSwitch.on);
        } else {
            // text / openapp never read the field through @@@, so the flag
            // must not linger from an earlier edit.
            [updated removeObjectForKey:kCustomActionCutReplaceKey];
        }
    }
    if (self.completion) self.completion(updated);
    [self.navigationController popViewControllerAnimated:YES];
}

- (UITextField *)newFieldWithText:(NSString *)text placeholder:(NSString *)placeholder {
    UITextField *field = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 210, 36)];
    field.text = text;
    field.placeholder = placeholder;
    field.textAlignment = NSTextAlignmentRight;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.delegate = self;
    return field;
}

#pragma mark - Icon preview

// The 图标 row's accessory is the shared DXPIconInputView: the thumbnail
// mirrors what the entry will actually render (SF Symbol name or app bundle
// identifier), refreshes on every keystroke, and the grid button opens the
// SF Symbols library picker.
- (UIView *)iconAccessoryView {
    if (!self.iconInputView) [self buildIconAccessory];
    return self.iconInputView;
}

- (void)buildIconAccessory {
    self.iconInputView = [[DXPIconInputView alloc] initWithFrame:CGRectMake(0.0, 0.0, 267.0, 36.0)];
    self.iconField = self.iconInputView.textField;
    self.iconField.placeholder = @"link";
    self.iconField.text = [self.entry[@"icon"] isKindOfClass:[NSString class]] ? self.entry[@"icon"] : @"";
    self.iconField.delegate = self;
    __weak typeof(self) weakSelf = self;
    self.iconInputView.textChanged = ^(__unused NSString *text) { [weakSelf refreshIconPreview]; };
    self.iconInputView.browseTapped = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.view endEditing:YES];
        DXPSFSymbolPickerController *picker = [[DXPSFSymbolPickerController alloc] init];
        picker.selectedSymbolName = [strongSelf trimmedValue:strongSelf.iconField.text];
        __weak typeof(strongSelf) weakOwner = strongSelf;
        picker.completion = ^(NSString *symbolName) {
            typeof(weakOwner) owner = weakOwner;
            if (!owner || !symbolName.length) return;
            owner.iconField.text = symbolName;
            [owner refreshIconPreview];
        };
        [picker setRootController:[strongSelf rootController]];
        [picker setParentController:[strongSelf parentController]];
        [strongSelf pushController:picker];
    };
}

// Refresh only the one preview view; sweeping visibleCells with the property
// setter would hit plain field cells and crash on an unrecognized selector.
- (void)refreshIconPreview {
    [self.iconInputView refreshPreview];
}

- (void)viewDidLoad {
    tweakBundle = [NSBundle bundleWithPath:bundlePath];
    [tweakBundle load];
    [super viewDidLoad];

    self.title = LOCALIZED(@"CUSTOM_ACTION_SETTINGS");
    self.entry = [self.entry mutableCopy] ?: [NSMutableDictionary dictionary];
    NSString *storedType = self.entry[kCustomActionTypeKey];
    // Entries typed before removed types (or carrying garbage) keep editing
    // as legacy (auto-detecting) actions; only known types stay typed.
    _displayedType = ([storedType isKindOfClass:[NSString class]] &&
                      ([storedType isEqualToString:kCustomActionTypeURLScheme] ||
                       [storedType isEqualToString:kCustomActionTypeText] ||
                       [storedType isEqualToString:kCustomActionTypeURL] ||
                       [storedType isEqualToString:kCustomActionTypeOpenApp] ||
                       [storedType isEqualToString:kCustomActionTypeShortcut] ||
                       [storedType isEqualToString:kCustomActionTypeSystem] ||
                       [storedType isEqualToString:kCustomActionTypeJavaScript])) ? storedType : @"";

    if (self.isTextEntry) {
        self.textRecords = [NSMutableArray array];
        id stored = self.entry[kCustomActionTextRecordsKey];
        if ([stored isKindOfClass:NSArray.class]) {
            for (id record in stored) {
                if ([record isKindOfClass:NSString.class]) [self.textRecords addObject:record];
            }
        }
        if (!self.textRecords.count) [self.textRecords addObject:@""];
    }
    if (self.isJavaScriptEntry) {
        self.jsInputControl = [[UISegmentedControl alloc] initWithItems:@[LOCALIZED(@"JS_AUTO"), LOCALIZED(@"JS_ALL"), LOCALIZED(@"JS_CLIPBOARD")]];
        self.jsOutputControl = [[UISegmentedControl alloc] initWithItems:@[LOCALIZED(@"JS_REPLACE"), LOCALIZED(@"JS_INSERT"), LOCALIZED(@"JS_COPY")]];
        [self.jsInputControl sizeToFit];
        [self.jsOutputControl sizeToFit];
        NSUInteger input = [@[@"auto", @"all", @"clipboard"] indexOfObject:self.entry[@"jsInput"] ?: @"auto"];
        NSUInteger output = [@[@"replace", @"insert", @"copy"] indexOfObject:self.entry[@"jsOutput"] ?: @"replace"];
        self.jsInputControl.selectedSegmentIndex = input == NSNotFound ? 0 : (NSInteger)input;
        self.jsOutputControl.selectedSegmentIndex = output == NSNotFound ? 0 : (NSInteger)output;
    }

    NSString *defaultName = ([self trimmedValue:self.entry[@"name"]].length && [self.entry[@"name"] isKindOfClass:[NSString class]])
        ? self.entry[@"name"] : LOCALIZED(@"DEFAULT_BUTTON_NAME");
    self.nameField = [self newFieldWithText:defaultName placeholder:LOCALIZED(@"DEFAULT_BUTTON_NAME")];
    [self buildIconAccessory];
    self.linkField = [self newFieldWithText:self.entry[@"link"] placeholder:@""];
    [self applyTypeToPayloadField];
    self.linkField.returnKeyType = UIReturnKeyDone;

    self.inAppSwitch = [[UISwitch alloc] init];
    id storedInApp = self.entry[kCustomActionInAppKey];
    // APP内打开 is the default: an absent flag still means in-app.
    self.inAppSwitch.on = (storedInApp == nil) || [storedInApp boolValue];
    [self.inAppSwitch addTarget:self action:@selector(inAppSwitchChanged:) forControlEvents:UIControlEventValueChanged];

    self.floatingSwitch = [[UISwitch alloc] init];
    self.floatingSwitch.on = DXActionUsesFloatingApp(self.entry, self.isOpenAppEntry);
    [self.floatingSwitch addTarget:self action:@selector(inAppSwitchChanged:) forControlEvents:UIControlEventValueChanged];

    // 剪切替换 defaults to off: the field keeps its content (copy semantics,
    // the historical behavior); on, the field is cleared after @@@ passes its
    // text into the payload (cut semantics).
    self.cutReplaceSwitch = [[UISwitch alloc] init];
    self.cutReplaceSwitch.on = [self.entry[kCustomActionCutReplaceKey] boolValue];
    [self.cutReplaceSwitch addTarget:self action:@selector(inAppSwitchChanged:) forControlEvents:UIControlEventValueChanged];

    if (self.isOpenAppEntry || self.isShortcutEntry) {
        NSString *selectedBundleIdentifier = [self trimmedValue:self.linkField.text];
        // Direct LaunchServices resolution (no enumeration), so a configured
        // app that the AltList pickers filter out still shows its real name.
        NSString *displayName = [DXPAppInfo displayNameForBundleID:selectedBundleIdentifier];
        self.selectedAppName = displayName.length > 0 ? displayName : selectedBundleIdentifier;
    }

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"DXPLinkActionFieldCell"];
    [self.tableView registerClass:[DXPLinkActionValueCell class] forCellReuseIdentifier:@"DXPLinkActionValueCell"];
    [self.tableView registerClass:[DXPLinkActionTextCell class] forCellReuseIdentifier:@"DXPLinkActionTextCell"];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.view = self.tableView;
    self.keyboardAvoider = [[DXPKeyboardAvoider alloc] initWithTableView:self.tableView];
    [self.keyboardAvoider start];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:LOCALIZED(@"SAVE")
                                                                              style:UIBarButtonItemStyleDone
                                                                             target:self
                                                                             action:@selector(saveTapped)];
    if (self.isTextEntry) {
        // 编辑入口移到文本记录区头部右上角（viewForHeaderInSection），导航栏只留保存。
        self.tableView.allowsSelectionDuringEditing = YES;
    }
}

@end
