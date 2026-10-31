#import "DXPAIChatController.h"
#import "DXPKeyboardAvoider.h"
#import "../common.h"
#import "../DXHelper.h"
#import "../DXAIEngine.h"

static NSBundle *tweakBundle;

#pragma mark - 偏好读写

static id DXAIPrefValue(NSString *key) {
    return [[DXPrefsManager sharedInstance] getValueForKey:key];
}

static void DXAIPrefSetValue(id value, NSString *key) {
    [[DXPrefsManager sharedInstance] setValue:value forKey:key];
}

static NSString *DXAIKeyPath(NSString *prefix, NSString *engineID) {
    return [prefix stringByAppendingString:engineID ?: @""];
}

static NSString *DXAITrim(NSString *text) {
    return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

#pragma mark - 文本输入行（label + 右侧输入框）

@interface DXPAITextFieldCell : UITableViewCell <UITextFieldDelegate>
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) UITextField *textField;
@property (nonatomic, copy) void (^onCommit)(NSString *text);
@end

@implementation DXPAITextFieldCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        self.label = [[UILabel alloc] init];
        self.label.font = [UIFont systemFontOfSize:17.0];
        self.label.textColor = [UIColor labelColor];
        [self.contentView addSubview:self.label];

        self.textField = [[UITextField alloc] init];
        self.textField.font = [UIFont systemFontOfSize:17.0];
        self.textField.textAlignment = NSTextAlignmentRight;
        self.textField.textColor = [UIColor secondaryLabelColor];
        self.textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        self.textField.autocorrectionType = UITextAutocorrectionTypeNo;
        self.textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        self.textField.keyboardType = UIKeyboardTypeURL;
        self.textField.delegate = self;
        [self.contentView addSubview:self.textField];

        self.label.translatesAutoresizingMaskIntoConstraints = NO;
        self.textField.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [self.label.leadingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.leadingAnchor],
            [self.label.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [self.label.trailingAnchor constraintLessThanOrEqualToAnchor:self.textField.leadingAnchor constant:-8.0],
            [self.textField.trailingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.trailingAnchor],
            [self.textField.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [self.textField.widthAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.widthAnchor multiplier:0.42 constant:0.0],
        ]];
    }
    return self;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    if (self.onCommit) self.onCommit(textField.text ?: @"");
}

@end

#pragma mark - 标题 + 输入框行（标题在上，输入框占满整行）

@interface DXPAIHeaderFieldCell : UITableViewCell <UITextFieldDelegate>
@property (nonatomic, strong) UILabel *headerLabel;
@property (nonatomic, strong) UITextField *textField;
@property (nonatomic, copy) void (^onCommit)(NSString *text);
@end

@implementation DXPAIHeaderFieldCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        self.headerLabel = [[UILabel alloc] init];
        self.headerLabel.font = [UIFont systemFontOfSize:13.0];
        self.headerLabel.textColor = [UIColor secondaryLabelColor];
        [self.contentView addSubview:self.headerLabel];

        self.textField = [[UITextField alloc] init];
        self.textField.font = [UIFont systemFontOfSize:17.0];
        self.textField.textColor = [UIColor labelColor];
        self.textField.autocorrectionType = UITextAutocorrectionTypeNo;
        self.textField.delegate = self;
        [self.contentView addSubview:self.textField];

        self.headerLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.textField.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [self.headerLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:10.0],
            [self.headerLabel.leadingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.leadingAnchor],
            [self.headerLabel.trailingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.trailingAnchor],
            [self.textField.topAnchor constraintEqualToAnchor:self.headerLabel.bottomAnchor constant:6.0],
            [self.textField.leadingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.leadingAnchor],
            [self.textField.trailingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.trailingAnchor],
            [self.textField.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-10.0],
        ]];
    }
    return self;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    if (self.onCommit) self.onCommit(textField.text ?: @"");
}

@end

#pragma mark - 标题 + 多行文本区行

@interface DXPAIModelsCell : UITableViewCell <UITextViewDelegate>
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) UIView *fieldContainer;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, copy) void (^onCommit)(NSString *text);
@end

@implementation DXPAIModelsCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        self.label = [[UILabel alloc] init];
        self.label.font = [UIFont systemFontOfSize:17.0];
        self.label.textColor = [UIColor labelColor];
        [self.contentView addSubview:self.label];

        self.fieldContainer = [[UIView alloc] init];
        self.fieldContainer.backgroundColor = [UIColor tertiarySystemFillColor];
        self.fieldContainer.layer.cornerRadius = 12.0;
        [self.contentView addSubview:self.fieldContainer];

        self.textView = [[UITextView alloc] init];
        self.textView.font = [UIFont systemFontOfSize:16.0];
        self.textView.textColor = [UIColor labelColor];
        self.textView.backgroundColor = UIColor.clearColor;
        self.textView.autocorrectionType = UITextAutocorrectionTypeNo;
        self.textView.autocapitalizationType = UITextAutocapitalizationTypeNone;
        // 默认键盘：模型列表每行一个，需要 return 键插入换行（URL 键盘不便换行）。
        self.textView.keyboardType = UIKeyboardTypeDefault;
        self.textView.delegate = self;
        [self.fieldContainer addSubview:self.textView];

        self.label.translatesAutoresizingMaskIntoConstraints = NO;
        self.fieldContainer.translatesAutoresizingMaskIntoConstraints = NO;
        self.textView.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [self.label.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12.0],
            [self.label.leadingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.leadingAnchor],
            [self.fieldContainer.topAnchor constraintEqualToAnchor:self.label.bottomAnchor constant:10.0],
            [self.fieldContainer.leadingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.leadingAnchor],
            [self.fieldContainer.trailingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.trailingAnchor],
            [self.fieldContainer.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-12.0],
            [self.textView.topAnchor constraintEqualToAnchor:self.fieldContainer.topAnchor constant:10.0],
            [self.textView.leadingAnchor constraintEqualToAnchor:self.fieldContainer.leadingAnchor constant:12.0],
            [self.textView.trailingAnchor constraintEqualToAnchor:self.fieldContainer.trailingAnchor constant:-12.0],
            [self.textView.bottomAnchor constraintEqualToAnchor:self.fieldContainer.bottomAnchor constant:-10.0],
        ]];
    }
    return self;
}

- (void)textViewDidEndEditing:(UITextView *)textView {
    if (self.onCommit) self.onCommit(textView.text ?: @"");
}

@end

#pragma mark - AI 问答主页

@interface DXPAIChatController ()
@property (nonatomic, assign) BOOL fetching;
// API Key / 模型列表等输入行滚动到键盘上方（自建 UITableView 无自动避让）。
@property (nonatomic, strong) DXPKeyboardAvoider *keyboardAvoider;
@end

@implementation DXPAIChatController

- (void)viewDidLoad {
    tweakBundle = [NSBundle bundleWithPath:bundlePath];
    [tweakBundle load];

    [super viewDidLoad];
    self.title = LOCALIZED(@"AI_SETTINGS_TITLE");

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tableView];
    self.keyboardAvoider = [[DXPKeyboardAvoider alloc] initWithTableView:self.tableView];
    [self.keyboardAvoider start];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 引擎/人设子页可能改写了配置，整页随之刷新。
    [self.tableView reloadData];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.view endEditing:YES]; // 触发各输入行的 onCommit 落盘
}

- (DXAIEngineInfo *)currentEngine {
    return [DXAIEngine currentEngine];
}

#pragma mark Sections

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return LOCALIZED(@"AI_ENGINE");
    if (section == 1) return [self currentEngine].displayName;
    return LOCALIZED(@"AI_PERSONA_SECTION");
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 1) {
        if ([self currentEngine].custom) return LOCALIZED(@"AI_HINT_CUSTOM");
        NSString *hintKey = [NSString stringWithFormat:@"AI_HINT_%@", [self currentEngine].identifier.uppercaseString];
        return LOCALIZED(hintKey);
    }
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    if (section == 2) return 2;
    // API Key + 模型 + 抓取（内置引擎多一个"获取 Key 网址"行；接口地址/名称
    // 在 AI 引擎页的自定义编辑器里改）。
    NSInteger rows = 3;
    if (![self currentEngine].custom && [self currentEngine].keysURL.length > 0) rows += 1;
    return rows;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 1) {
        NSString *kind = [self kindForRow:indexPath.row];
        // 模型列表每行一个，框体至少完整露出 5 行（16pt 字体行高 ~19.5pt）。
        if ([kind isEqualToString:@"models"]) return 176.0;
        return 44.0;
    }
    return 44.0;
}

// Section 1 的行语义：api-key → models → fetch（内置引擎末尾多一个 keysurl）。
- (NSString *)kindForRow:(NSInteger)row {
    if (row == 0) return @"text";
    if (row == 1) return @"models";
    if (row == 2) return @"fetch";
    return @"keysurl";
}

// 当前引擎 API Key 的现值（内置读偏好键，自定义读 aiCustomEngines 列表）。
- (NSString *)currentAPIKeyValue {
    DXAIEngineInfo *engine = [self currentEngine];
    return [DXAIEngine apiKeyForEngine:engine] ?: @"";
}

#pragma mark Cells

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) return [self engineCell];
    if (indexPath.section == 2) return [self personaCellForRow:indexPath.row];
    return [self configCellForRow:indexPath.row];
}

- (UITableViewCell *)engineCell {
    static NSString *identifier = @"DXPAIEngineRow";
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:identifier];
    cell.textLabel.text = LOCALIZED(@"AI_CURRENT_ENGINE");
    cell.detailTextLabel.text = [self currentEngine].displayName;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (UITableViewCell *)configCellForRow:(NSInteger)row {
    DXAIEngineInfo *engine = [self currentEngine];
    NSString *kind = [self kindForRow:row];

    if ([kind isEqualToString:@"text"]) {
        static NSString *textIdentifier = @"DXPAITextField";
        DXPAITextFieldCell *cell = [self.tableView dequeueReusableCellWithIdentifier:textIdentifier];
        if (!cell) cell = [[DXPAITextFieldCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:textIdentifier];
        cell.onCommit = nil; // 复用重配期间避免旧块误触发
        cell.label.text = LOCALIZED(@"AI_API_KEY");
        cell.textField.text = [self currentAPIKeyValue];
        cell.textField.placeholder = @"sk-…";
        __weak typeof(self) weakSelf = self;
        cell.onCommit = ^(NSString *text) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (engine.custom) [DXAIEngine updateCustomEngineWithID:engine.identifier key:@"key" value:DXAITrim(text) ?: @""];
            else DXAIPrefSetValue(text ?: @"", DXAIKeyPath(DXAIPrefKeyPrefix, engine.identifier));
        };
        return cell;
    }

    if ([kind isEqualToString:@"models"]) {
        static NSString *modelsIdentifier = @"DXPAIModels";
        DXPAIModelsCell *cell = [self.tableView dequeueReusableCellWithIdentifier:modelsIdentifier];
        if (!cell) cell = [[DXPAIModelsCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:modelsIdentifier];
        cell.label.text = LOCALIZED(@"AI_MODELS_LABEL");
        cell.onCommit = nil;
        cell.textView.text = [[DXAIEngine modelsForEngine:engine] componentsJoinedByString:@"\n"];
        __weak typeof(self) weakSelf = self;
        cell.onCommit = ^(NSString *text) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (engine.custom) [DXAIEngine updateCustomEngineWithID:engine.identifier key:@"models" value:DXAITrim(text) ?: @""];
            else DXAIPrefSetValue(text ?: @"", DXAIKeyPath(DXAIPrefModelsPrefix, engine.identifier));
        };
        return cell;
    }

    static NSString *buttonIdentifier = @"DXPAIButton";
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:buttonIdentifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:buttonIdentifier];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.textLabel.textColor = [UIColor systemBlueColor];
    cell.textLabel.font = [UIFont systemFontOfSize:17.0];
    if ([kind isEqualToString:@"fetch"]) {
        cell.textLabel.text = self.fetching ? LOCALIZED(@"AI_FETCHING_MODELS") : LOCALIZED(@"AI_FETCH_MODELS");
        cell.textLabel.textColor = self.fetching ? [UIColor secondaryLabelColor] : [UIColor systemBlueColor];
    } else {
        cell.textLabel.text = LOCALIZED(@"AI_OPEN_KEYS_URL");
    }
    return cell;
}

- (UITableViewCell *)personaCellForRow:(NSInteger)row {
    if (row == 1) { // 流式输出
        static NSString *switchIdentifier = @"DXPAISwitch";
        UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:switchIdentifier];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:switchIdentifier];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = LOCALIZED(@"AI_STREAM_ROW");
        UISwitch *toggle = [[UISwitch alloc] init];
        id stored = DXAIPrefValue(DXAIPrefStream);
        toggle.on = [stored isKindOfClass:[NSNumber class]] ? [stored boolValue] : YES;
        [toggle addTarget:self action:@selector(streamToggleChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        return cell;
    }

    static NSString *linkIdentifier = @"DXPAILink";
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:linkIdentifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:linkIdentifier];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.textLabel.textColor = [UIColor labelColor];
    cell.textLabel.text = LOCALIZED(@"AI_PERSONA_ROW");
    return cell;
}

#pragma mark 交互

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 0) {
        [self.navigationController pushViewController:[[DXPAIEnginePickerController alloc] init] animated:YES];
        return;
    }
    if (indexPath.section == 2) {
        if (indexPath.row == 0) [self.navigationController pushViewController:[[DXPAIPersonaController alloc] init] animated:YES];
        return;
    }

    NSString *kind = [self kindForRow:indexPath.row];
    if ([kind isEqualToString:@"fetch"]) {
        [self fetchModelsTapped];
    } else if ([kind isEqualToString:@"keysurl"]) {
        NSURL *url = [NSURL URLWithString:[self currentEngine].keysURL];
        if (url) [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

- (void)streamToggleChanged:(UISwitch *)toggle {
    DXAIPrefSetValue(@(toggle.on), DXAIPrefStream);
}

- (void)fetchModelsTapped {
    if (self.fetching) return;
    DXAIEngineInfo *engine = [self currentEngine];
    self.fetching = YES;
    [self.tableView reloadData];
    __weak typeof(self) weakSelf = self;
    [DXAIEngine fetchModelsForEngine:engine completion:^(NSArray<NSString *> *models, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.fetching = NO;
        if (error) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                          message:error.localizedDescription
                                                                   preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:LOCALIZED(@"ANSWER_OK") style:UIAlertActionStyleDefault handler:nil]];
            [strongSelf presentViewController:alert animated:YES completion:nil];
            [strongSelf.tableView reloadData];
            return;
        }
        if (engine.custom) [DXAIEngine updateCustomEngineWithID:engine.identifier key:@"models" value:[models componentsJoinedByString:@"\n"]];
        else DXAIPrefSetValue([models componentsJoinedByString:@"\n"], DXAIKeyPath(DXAIPrefModelsPrefix, engine.identifier));
        [strongSelf.tableView reloadData];
    }];
}

@end

#pragma mark - AI 引擎页（内置 + 自定义）

@interface DXPAIEnginePickerController ()
@end

@implementation DXPAIEnginePickerController

- (void)viewDidLoad {
    tweakBundle = [NSBundle bundleWithPath:bundlePath];
    [tweakBundle load];

    [super viewDidLoad];
    self.title = LOCALIZED(@"AI_ENGINE");
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:LOCALIZED(@"AI_ENGINE_ADD")
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(addCustomEngineTapped)];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tableView];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData]; // 编辑器可能新增/删除了自定义引擎
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return LOCALIZED(section == 0 ? @"AI_ENGINE_BUILTIN_SECTION" : @"AI_ENGINE_CUSTOM_SECTION");
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return LOCALIZED(section == 0 ? @"AI_ENGINE_PICKER_FOOTER" : @"AI_ENGINE_SWIPE_DELETE");
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? [DXAIEngine allEngines].count : [DXAIEngine customEngines].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"DXPAIEnginePick";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
    DXAIEngineInfo *engine = [self engineAtIndexPath:indexPath];
    cell.textLabel.text = engine.displayName;
    cell.textLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightMedium];
    cell.accessoryType = [engine.identifier isEqualToString:[DXAIEngine currentEngine].identifier]
        ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (DXAIEngineInfo *)engineAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 0
        ? [DXAIEngine allEngines][indexPath.row]
        : [DXAIEngine customEngines][indexPath.row];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 0) {
        // 内置引擎：勾选即切换当前引擎（配置在主页"当前引擎"组里填写）。
        DXAIEngineInfo *engine = [DXAIEngine allEngines][indexPath.row];
        DXAIPrefSetValue(engine.identifier, DXAIPrefEngine);
        [tableView reloadData];
        return;
    }
    DXAIEngineInfo *engine = [DXAIEngine customEngines][indexPath.row];
    [self.navigationController pushViewController:[[DXPAICustomEngineEditorController alloc] initWithEngineID:engine.identifier] animated:YES];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 1;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 1 ? UITableViewCellEditingStyleDelete : UITableViewCellEditingStyleNone;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    DXAIEngineInfo *engine = [DXAIEngine customEngines][indexPath.row];
    [DXAIEngine removeCustomEngineWithID:engine.identifier];
    [tableView reloadData];
}

// 快速添加自定义引擎（ShellX 同款弹窗）：名称/Base URL/API Key/模型 ID 一屏
// 填完即建即选。Base URL 填 https://xxx/v1 或完整 …/chat/completions 均可
// （endpointForEngine 统一归一化）；要改模型列表/抓取仍走点行进编辑器。
- (void)addCustomEngineTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:LOCALIZED(@"AI_CUSTOM_ADD_TITLE")
                                                                  message:LOCALIZED(@"AI_CUSTOM_ADD_MESSAGE")
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = LOCALIZED(@"AI_CUSTOM_NAME");
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = LOCALIZED(@"AI_CUSTOM_BASEURL_HINT");
        textField.keyboardType = UIKeyboardTypeURL;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = LOCALIZED(@"AI_API_KEY");
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = LOCALIZED(@"AI_CUSTOM_MODEL_HINT");
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:LOCALIZED(@"ANSWER_CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    // 直接捕获输入框（弱化对 alert 的引用）：alert→action→handler→alert 会成环。
    NSArray<UITextField *> *fields = alert.textFields;
    [alert addAction:[UIAlertAction actionWithTitle:LOCALIZED(@"SAVE") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = self;
        if (!strongSelf) return;
        NSString *name = fields[0].text ?: @"";
        NSString *models = fields[3].text ?: @"";

        // 与编辑器保存同一套校验：归一化后必须带 http/https scheme。
        DXAIEngineInfo *temp = [[DXAIEngineInfo alloc] init];
        temp.baseURL = fields[1].text ?: @"";
        NSString *endpoint = [DXAIEngine endpointForEngine:temp];
        NSURL *url = [NSURL URLWithString:[endpoint stringByAppendingString:@"/chat/completions"]];
        BOOL schemeOK = url && ([url.scheme.lowercaseString isEqualToString:@"https"] ||
                                [url.scheme.lowercaseString isEqualToString:@"http"]);
        if (endpoint.length == 0 || !schemeOK) {
            UIAlertController *invalid = [UIAlertController alertControllerWithTitle:nil
                                                                            message:LOCALIZED(@"AI_INVALID_ENDPOINT")
                                                                     preferredStyle:UIAlertControllerStyleAlert];
            [invalid addAction:[UIAlertAction actionWithTitle:LOCALIZED(@"ANSWER_OK") style:UIAlertActionStyleDefault handler:nil]];
            [strongSelf presentViewController:invalid animated:YES completion:nil];
            return;
        }

        NSString *newID = [DXAIEngine addCustomEngineWithName:name
                                                     endpoint:endpoint
                                                       apiKey:fields[2].text ?: @""
                                                       models:models];
        DXAIPrefSetValue(newID, DXAIPrefEngine); // 建完即选中
        [strongSelf.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - 自定义引擎编辑器

@interface DXPAICustomEngineEditorController ()
@property (nonatomic, copy) NSString *engineID; // nil = 新增
@property (nonatomic, copy) NSString *endpointValue;
@property (nonatomic, copy) NSString *nameValue;
@property (nonatomic, copy) NSString *keyValue;
@property (nonatomic, copy) NSString *modelsValue;
@property (nonatomic, assign) BOOL fetching;
// 接口地址 / API Key / 模型列表等输入行滚动到键盘上方。
@property (nonatomic, strong) DXPKeyboardAvoider *keyboardAvoider;
@end

@implementation DXPAICustomEngineEditorController

- (instancetype)initWithEngineID:(NSString *)engineID {
    if ((self = [super init])) {
        self.engineID = [engineID isKindOfClass:[NSString class]] ? engineID : nil;
        self.endpointValue = @"";
        self.nameValue = @"";
        self.keyValue = @"";
        self.modelsValue = @"";
        if (self.engineID.length > 0) {
            for (DXAIEngineInfo *engine in [DXAIEngine customEngines]) {
                if (![engine.identifier isEqualToString:self.engineID]) continue;
                self.endpointValue = engine.baseURL ?: @"";
                self.nameValue = engine.displayName ?: @"";
                self.keyValue = [DXAIEngine apiKeyForEngine:engine] ?: @"";
                // 旧数据可能逗号分隔，展示统一归一成每行一个。
                self.modelsValue = [[DXAIEngine modelsForEngine:engine] componentsJoinedByString:@"\n"];
            }
        }
    }
    return self;
}

- (void)viewDidLoad {
    tweakBundle = [NSBundle bundleWithPath:bundlePath];
    [tweakBundle load];

    [super viewDidLoad];
    self.title = LOCALIZED(@"AI_CUSTOM_ENGINE_TITLE");
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:LOCALIZED(@"AI_SAVE")
                                                                              style:UIBarButtonItemStyleDone
                                                                             target:self
                                                                             action:@selector(saveTapped)];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tableView];
    self.keyboardAvoider = [[DXPKeyboardAvoider alloc] initWithTableView:self.tableView];
    [self.keyboardAvoider start];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 5;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row == 3) return 176.0; // 模型列表框：至少完整露出 5 行
    return 44.0;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return LOCALIZED(@"AI_HINT_CUSTOM");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.row) {
        case 0: {
            DXPAITextFieldCell *cell = [[DXPAITextFieldCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            cell.label.text = LOCALIZED(@"AI_ENDPOINT");
            cell.textField.text = self.endpointValue;
            cell.textField.placeholder = @"https://api.example.com/v1";
            __weak typeof(self) weakSelf = self;
            cell.onCommit = ^(NSString *text) {
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (strongSelf) strongSelf.endpointValue = text ?: @"";
            };
            return cell;
        }
        case 1: {
            DXPAITextFieldCell *cell = [[DXPAITextFieldCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            cell.label.text = LOCALIZED(@"AI_CUSTOM_NAME");
            cell.textField.text = self.nameValue;
            __weak typeof(self) weakSelf = self;
            cell.onCommit = ^(NSString *text) {
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (strongSelf) strongSelf.nameValue = text ?: @"";
            };
            return cell;
        }
        case 2: {
            DXPAITextFieldCell *cell = [[DXPAITextFieldCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            cell.label.text = LOCALIZED(@"AI_API_KEY");
            cell.textField.text = self.keyValue;
            cell.textField.placeholder = @"sk-…";
            __weak typeof(self) weakSelf = self;
            cell.onCommit = ^(NSString *text) {
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (strongSelf) strongSelf.keyValue = text ?: @"";
            };
            return cell;
        }
        case 3: {
            DXPAIModelsCell *cell = [[DXPAIModelsCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            cell.label.text = LOCALIZED(@"AI_MODELS_LABEL");
            cell.textView.text = self.modelsValue;
            __weak typeof(self) weakSelf = self;
            cell.onCommit = ^(NSString *text) {
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (strongSelf) strongSelf.modelsValue = text ?: @"";
            };
            return cell;
        }
        default: {
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            cell.textLabel.text = self.fetching ? LOCALIZED(@"AI_FETCHING_MODELS") : LOCALIZED(@"AI_FETCH_MODELS");
            cell.textLabel.textColor = self.fetching ? [UIColor secondaryLabelColor] : [UIColor systemBlueColor];
            cell.textLabel.textAlignment = NSTextAlignmentCenter;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            return cell;
        }
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row == 4) [self fetchModelsTapped];
}

- (void)fetchModelsTapped {
    if (self.fetching) return;
    [self.view endEditing:YES]; // onCommit 先把输入收进属性

    DXAIEngineInfo *temp = [[DXAIEngineInfo alloc] init];
    temp.custom = YES;
    temp.identifier = self.engineID ?: @"temp";
    temp.baseURL = self.endpointValue ?: @"";
    temp.defaultModels = self.modelsValue ?: @"";
    temp.overrideAPIKey = self.keyValue ?: @"";
    if ([DXAIEngine endpointForEngine:temp].length == 0) {
        [self showAlert:LOCALIZED(@"AI_INVALID_ENDPOINT")];
        return;
    }

    self.fetching = YES;
    [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:4 inSection:0]] withRowAnimation:UITableViewRowAnimationNone];
    __weak typeof(self) weakSelf = self;
    [DXAIEngine fetchModelsForEngine:temp completion:^(NSArray<NSString *> *models, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.fetching = NO;
        if (error) {
            [strongSelf showAlert:error.localizedDescription];
            [strongSelf.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:4 inSection:0]] withRowAnimation:UITableViewRowAnimationNone];
            return;
        }
        strongSelf.modelsValue = [models componentsJoinedByString:@"\n"];
        [strongSelf.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:3 inSection:0], [NSIndexPath indexPathForRow:4 inSection:0]] withRowAnimation:UITableViewRowAnimationNone];
    }];
}

- (void)saveTapped {
    [self.view endEditing:YES];

    DXAIEngineInfo *temp = [[DXAIEngineInfo alloc] init];
    temp.baseURL = self.endpointValue ?: @"";
    NSString *endpoint = [DXAIEngine endpointForEngine:temp];
    NSURL *url = [NSURL URLWithString:[endpoint stringByAppendingString:@"/chat/completions"]];
    BOOL schemeOK = url && ([url.scheme.lowercaseString isEqualToString:@"https"] ||
                            [url.scheme.lowercaseString isEqualToString:@"http"]);
    if (endpoint.length == 0 || !schemeOK) {
        [self showAlert:LOCALIZED(@"AI_INVALID_ENDPOINT")];
        return;
    }

    NSString *name = self.nameValue ?: @"";
    if (self.engineID.length > 0) {
        [DXAIEngine updateCustomEngineWithID:self.engineID key:@"name" value:name.length > 0 ? name : @"自定义"];
        [DXAIEngine updateCustomEngineWithID:self.engineID key:@"endpoint" value:endpoint];
        [DXAIEngine updateCustomEngineWithID:self.engineID key:@"key" value:self.keyValue ?: @""];
        [DXAIEngine updateCustomEngineWithID:self.engineID key:@"models" value:self.modelsValue ?: @""];
    } else {
        NSString *newID = [DXAIEngine addCustomEngineWithName:name endpoint:endpoint apiKey:self.keyValue ?: @"" models:self.modelsValue ?: @""];
        DXAIPrefSetValue(newID, DXAIPrefEngine); // 新建即选中
    }
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)showAlert:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                  message:message
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:LOCALIZED(@"ANSWER_OK") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - 人设页

@implementation DXPAIPersonaController

- (void)viewDidLoad {
    tweakBundle = [NSBundle bundleWithPath:bundlePath];
    [tweakBundle load];

    [super viewDidLoad];
    self.title = LOCALIZED(@"AI_PERSONA_ROW");

    UIBarButtonItem *addButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                               target:self
                                                                               action:@selector(addPersonaTapped)];
    self.navigationItem.rightBarButtonItem = addButton;

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.dragDelegate = self;
    self.tableView.dropDelegate = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tableView];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData]; // 编辑页可能改了内容
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [DXAIEngine personas].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return LOCALIZED(@"AI_PERSONA_FOOTER");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"DXPAIPersonaRow";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];

    NSDictionary *persona = [DXAIEngine personas][indexPath.row];
    cell.textLabel.text = [persona[@"name"] isKindOfClass:[NSString class]] ? persona[@"name"] : @"";
    cell.textLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightMedium];
    // 第一项即默认人设（排序决定），不再展示历史 role 字段。
    cell.detailTextLabel.text = indexPath.row == 0 ? LOCALIZED(@"AI_PERSONA_DEFAULT_MARK") : @"";
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    // 行尾固定拖动把手；拖动由表格的长按 drag & drop 承担，点行仍进编辑页。
    UIImageView *handle = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"line.3.horizontal"]];
    handle.contentMode = UIViewContentModeScaleAspectFit;
    handle.tintColor = [UIColor secondaryLabelColor];
    handle.frame = CGRectMake(0, 0, 24, 24);
    cell.accessoryView = handle;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *persona = [DXAIEngine personas][indexPath.row];
    NSString *personaID = [persona[@"id"] isKindOfClass:[NSString class]] ? persona[@"id"] : nil;
    if (personaID.length == 0) return;
    [self.navigationController pushViewController:[[DXPAIPersonaEditorController alloc] initWithPersonaID:personaID] animated:YES];
}

// 所有人设一律可左滑删除；删空后请求回退面板内建的兜底提示词，面板人设
// 菜单为空则不弹。
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    NSMutableArray *personas = [[DXAIEngine personas] mutableCopy];
    if (indexPath.row >= personas.count) return;
    [personas removeObjectAtIndex:indexPath.row];
    [DXAIEngine setPersonas:personas];
    [tableView reloadData];
}

- (void)addPersonaTapped {
    NSMutableArray *personas = [[DXAIEngine personas] mutableCopy];
    NSMutableDictionary *persona = [NSMutableDictionary dictionary];
    persona[@"id"] = [NSString stringWithFormat:@"u%.0f", [NSDate date].timeIntervalSince1970 * 1000.0];
    persona[@"name"] = LOCALIZED(@"AI_PERSONA_NEW");
    persona[@"content"] = @"";
    persona[@"role"] = @"";
    persona[@"enabled"] = @(YES); // 新人设按钮在面板框选菜单中默认打开
    [personas addObject:persona];
    [DXAIEngine setPersonas:personas];
    [self.tableView reloadData];
    [self.navigationController pushViewController:[[DXPAIPersonaEditorController alloc] initWithPersonaID:persona[@"id"]] animated:YES];
}

// 长按拖动排序：列表顺序即面板人设菜单顺序，拖到第一位的人设成为默认人设。
// 本地拖动会话由表格跟踪落点间隙，数据源更新与 moveRow 动画在同一
// beginUpdates 里提交。
- (NSArray<UIDragItem *> *)tableView:(UITableView *)tableView itemsForBeginningDragSession:(id<UIDragSession>)session atIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; (void)session;
    NSArray<NSDictionary *> *personas = [DXAIEngine personas];
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)personas.count) return @[];
    NSDictionary *persona = personas[indexPath.row];
    UIDragItem *item = [[UIDragItem alloc] initWithItemProvider:[[NSItemProvider alloc] initWithObject:persona[@"id"] ?: @""]];
    item.localObject = persona;
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
    NSDictionary *persona = dropItem.dragItem.localObject;
    if (![persona isKindOfClass:[NSDictionary class]]) return;
    NSMutableArray *personas = [[DXAIEngine personas] mutableCopy];
    NSUInteger sourceRow = [personas indexOfObjectIdenticalTo:persona];
    if (sourceRow == NSNotFound) return;
    // 落点按当前序的插入位计（末尾追加=行数）；先移除源行，向下移动回缩一位。
    NSInteger targetRow = MIN(MAX(destination.row, 0), (NSInteger)personas.count);
    if (targetRow > (NSInteger)sourceRow) targetRow--;
    if (targetRow == (NSInteger)sourceRow) return;
    [tableView beginUpdates];
    [personas removeObjectAtIndex:sourceRow];
    [personas insertObject:persona atIndex:targetRow];
    [tableView moveRowAtIndexPath:[NSIndexPath indexPathForRow:sourceRow inSection:0]
        toIndexPath:[NSIndexPath indexPathForRow:targetRow inSection:0]];
    [tableView endUpdates];
    [DXAIEngine setPersonas:personas];
    [tableView reloadData]; // 首行「默认」角标随排序移动
}

@end

#pragma mark - 编辑人设

@interface DXPAIPersonaEditorController ()
@property (nonatomic, copy) NSString *personaID;
@property (nonatomic, copy) NSString *storedName;
@property (nonatomic, copy) NSString *storedContent;
@property (nonatomic, strong) UITextField *nameField;
@property (nonatomic, strong) UITextView *contentTextView;
// 人设内容大文本框滚动到键盘上方。
@property (nonatomic, strong) DXPKeyboardAvoider *keyboardAvoider;
@end

@implementation DXPAIPersonaEditorController

- (instancetype)initWithPersonaID:(NSString *)personaID {
    if ((self = [super init])) {
        self.personaID = personaID;
        NSDictionary *persona = [DXAIEngine personaForID:personaID];
        self.storedName = [persona[@"name"] isKindOfClass:[NSString class]] ? persona[@"name"] : @"";
        self.storedContent = [persona[@"content"] isKindOfClass:[NSString class]] ? persona[@"content"] : @"";
    }
    return self;
}

- (void)viewDidLoad {
    tweakBundle = [NSBundle bundleWithPath:bundlePath];
    [tweakBundle load];

    [super viewDidLoad];
    self.title = LOCALIZED(@"AI_PERSONA_EDIT_TITLE");
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:LOCALIZED(@"AI_SAVE")
                                                                              style:UIBarButtonItemStyleDone
                                                                             target:self
                                                                             action:@selector(saveTapped)];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.alwaysBounceVertical = NO;
    [self.view addSubview:self.tableView];
    self.keyboardAvoider = [[DXPKeyboardAvoider alloc] initWithTableView:self.tableView];
    [self.keyboardAvoider start];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return LOCALIZED(@"AI_PERSONA_NAME_HEADER");
    if (section == 1) return LOCALIZED(@"AI_PERSONA_CONTENT_HEADER");
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 1;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 1) return 280.0;
    return 86.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        DXPAIHeaderFieldCell *cell = [[DXPAIHeaderFieldCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.headerLabel.text = LOCALIZED(@"AI_PERSONA_NAME_HEADER");
        cell.textField.text = self.storedName;
        cell.textField.placeholder = LOCALIZED(@"AI_PERSONA_NEW");
        __weak typeof(self) weakSelf = self;
        cell.onCommit = ^(NSString *text) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf) strongSelf.storedName = DXAITrim(text) ?: @"";
        };
        self.nameField = cell.textField;
        return cell;
    }

    DXPAIModelsCell *cell = [[DXPAIModelsCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.label.text = LOCALIZED(@"AI_PERSONA_CONTENT_HEADER");
    cell.textView.text = self.storedContent;
    __weak typeof(self) weakSelf = self;
    cell.onCommit = ^(NSString *text) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) strongSelf.storedContent = text ?: @"";
    };
    self.contentTextView = cell.textView;
    return cell;
}

- (void)saveTapped {
    [self.view endEditing:YES]; // 触发输入行 onCommit，把最新文本收进属性

    NSMutableArray *personas = [[DXAIEngine personas] mutableCopy];
    NSInteger index = -1;
    for (NSUInteger i = 0; i < personas.count; i++) {
        NSDictionary *persona = personas[i];
        if ([persona[@"id"] isKindOfClass:[NSString class]] && [persona[@"id"] isEqualToString:self.personaID]) {
            index = (NSInteger)i;
            break;
        }
    }
    if (index < 0) {
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }

    NSMutableDictionary *persona = [personas[index] mutableCopy];
    NSString *name = DXAITrim(self.storedName) ?: @"";
    persona[@"name"] = name.length > 0 ? name : (self.storedName.length > 0 ? self.storedName : LOCALIZED(@"AI_PERSONA_NEW"));
    persona[@"content"] = self.storedContent ?: @"";
    personas[index] = persona;
    [DXAIEngine setPersonas:personas];
    [self.navigationController popViewControllerAnimated:YES];
}

@end
