#import "DXPRootListController.h"
#import <spawn.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "../common.h"
#import "../DXHelper.h"
#import "../DXSettingsSearch.h"

static NSBundle *tweakBundle;

@interface DXPRootListController () <UIDocumentPickerDelegate, UISearchResultsUpdating>
@property(nonatomic, strong) UISearchController *settingsSearch;
@property(nonatomic, copy) NSArray<PSSpecifier *> *allSettingsSpecifiers;
@property(nonatomic, retain) NSURL *pendingExportURL;
@end


@implementation DXPRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [[self loadSpecifiersFromPlistName:@"Root" target:self] mutableCopy];
        
        self.allSettingsSpecifiers = [_specifiers copy];
        self.dynamicSpecifiers = (!self.dynamicSpecifiers) ? [[NSMutableDictionary alloc] init] : self.dynamicSpecifiers;
    }
    
    
    return _specifiers;
}

#pragma mark - 生效应用（AltList 多选页 get/set）

// 历史版本把 pasteimagechipapps 存成 bundleID→@YES 字典，AltList 多选页存
// 已开启 bundleID 数组。读取侧统一规整成数组（只在内存转换，不回写，首次
// 拨动开关时自然落盘为新格式）；tweak 侧（DXPasteChip）两种格式都认。
- (id)dxp_pasteChipAppsRead:(PSSpecifier *)specifier {
    id value = [self readPreferenceValue:specifier];
    if ([value isKindOfClass:[NSArray class]]) return value;
    if (![value isKindOfClass:[NSDictionary class]]) return @[];

    NSMutableArray<NSString *> *enabled = [NSMutableArray array];
    for (NSString *bundleID in value) {
        NSNumber *flag = value[bundleID];
        if ([bundleID isKindOfClass:[NSString class]] &&
            [flag isKindOfClass:[NSNumber class]] && flag.boolValue) {
            [enabled addObject:bundleID];
        }
    }
    return enabled;
}

// setPreferenceValue:specifier: 负责域写入；这里显式补发 prefschanged，
// 保证键盘进程立刻感知（与各开关的 PostNotification 等效，双发无害）。
- (void)dxp_pasteChipAppsWrite:(id)value specifier:(PSSpecifier *)specifier {
    [self setPreferenceValue:value specifier:specifier];

    CFStringRef notificationName = (__bridge CFStringRef)kPrefsChangedIdentifier;
    if (notificationName) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), notificationName, NULL, NULL, YES);
    }
}

#pragma mark - 剪贴板忽略应用（AltList 多选页 get/set）

// 剪贴板黑名单存 bundleID 数组（与 pasteimagechipapps 同款新格式），
// 直接透传，tweak 侧（DXClipboardService）按数组判黑。
- (id)dxp_clipboardAppsRead:(PSSpecifier *)specifier {
    id value = [self readPreferenceValue:specifier];
    if ([value isKindOfClass:[NSArray class]]) return value;
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSMutableArray<NSString *> *enabled = [NSMutableArray array];
        for (NSString *bundleID in value) {
            NSNumber *flag = value[bundleID];
            if ([bundleID isKindOfClass:[NSString class]] &&
                [flag isKindOfClass:[NSNumber class]] && flag.boolValue) {
                [enabled addObject:bundleID];
            }
        }
        return enabled;
    }
    return @[];
}

- (void)dxp_clipboardAppsWrite:(id)value specifier:(PSSpecifier *)specifier {
    [self setPreferenceValue:value specifier:specifier];

    CFStringRef notificationName = (__bridge CFStringRef)kPrefsChangedIdentifier;
    if (notificationName) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), notificationName, NULL, NULL, YES);
    }
}

-(void)viewDidLoad  {
    tweakBundle = [NSBundle bundleWithPath:bundlePath];
    [tweakBundle load];
    [super viewDidLoad];
    
    //search bar
    
    self.settingsSearch = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.settingsSearch.searchResultsUpdater = self;
    self.settingsSearch.searchBar.delegate = self;
    self.definesPresentationContext = YES;
    self.settingsSearch.definesPresentationContext = YES;
    self.settingsSearch.hidesNavigationBarDuringPresentation = NO;
    
    self.settingsSearch.searchBar.placeholder = LOCALIZED(@"SEARCHBAR_PLACEHOLDER");
    [self.settingsSearch.searchBar setImage:[DXHelper imageForTypeXWithPlaceholder:YES] forSearchBarIcon:UISearchBarIconSearch state:UIControlStateNormal];

    self.settingsSearch.obscuresBackgroundDuringPresentation = NO;
    
    if (@available(iOS 11.0, *)){
        self.navigationItem.searchController = self.settingsSearch;
        self.navigationItem.hidesSearchBarWhenScrolling = YES;
    }
    //search bar
    
    
    CGFloat headerWidth = self.table.bounds.size.width;
    CGRect frame = CGRectMake(0, 0, headerWidth, 250);

    UIView *headerView = [[UIView alloc] initWithFrame:frame];
    headerView.backgroundColor = UIColor.clearColor;

    UIImage *headerImage = [[UIImage alloc]
                            initWithContentsOfFile:[[NSBundle bundleWithPath:bundlePath] pathForResource:@"TypeX512" ofType:@"png"]];

    // shadow container + rounded inner view so the corners clip without cutting the shadow
    CGFloat iconSize = 120;
    UIView *iconContainer = [[UIView alloc] initWithFrame:CGRectMake((headerWidth - iconSize) / 2.0, 28, iconSize, iconSize)];
    iconContainer.backgroundColor = UIColor.clearColor;
    iconContainer.layer.shadowColor = [UIColor blackColor].CGColor;
    iconContainer.layer.shadowOpacity = 0.35;
    iconContainer.layer.shadowRadius = 12;
    iconContainer.layer.shadowOffset = CGSizeMake(0, 6);
    iconContainer.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;

    UIImageView *imageView = [[UIImageView alloc] initWithFrame:iconContainer.bounds];
    [imageView setImage:headerImage];
    [imageView setContentMode:UIViewContentModeScaleAspectFit];
    imageView.layer.cornerRadius = iconSize * 0.225;
    imageView.layer.masksToBounds = YES;
    [iconContainer addSubview:imageView];
    [headerView addSubview:iconContainer];

    CGRect labelFrame = CGRectMake(0, iconContainer.frame.origin.y + iconSize + 14, headerWidth, 52);
    UIFont *font = nil;
    if (@available(iOS 13.0, *)) {
        UIFontDescriptor *desc = [[UIFontDescriptor preferredFontDescriptorWithTextStyle:UIFontTextStyleLargeTitle]
                                  fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded];
        font = [UIFont fontWithDescriptor:desc size:36];
    }
    if (!font) font = [UIFont systemFontOfSize:36 weight:UIFontWeightBold];

    UILabel *headerLabel = [[UILabel alloc] initWithFrame:labelFrame];
    [headerLabel setText:@"MUBX"];
    [headerLabel setFont:font];
    if (@available(iOS 13.0, *)) {
        [headerLabel setTextColor:[UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traitCollection) {
            return traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithRed:1.0 green:1.0 blue:1.0 alpha:0.92]
                : [UIColor colorWithRed:0.10 green:0.10 blue:0.12 alpha:1.00];
        }]];
    } else {
        [headerLabel setTextColor:[UIColor darkGrayColor]];
    }
    headerLabel.textAlignment = NSTextAlignmentCenter;
    headerLabel.adjustsFontSizeToFitWidth = YES;
    headerLabel.minimumScaleFactor = 0.7;
    [headerLabel setAutoresizingMask:UIViewAutoresizingFlexibleWidth];
    [headerView addSubview:headerLabel];

    UILabel *versionLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, CGRectGetMaxY(labelFrame) + 2, MAX(0, headerWidth - 32), 20)];
    versionLabel.text = [@"v" stringByAppendingString:@TYPEX_PACKAGE_VERSION];
    versionLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    versionLabel.textColor = UIColor.secondaryLabelColor;
    versionLabel.textAlignment = NSTextAlignmentCenter;
    versionLabel.adjustsFontSizeToFitWidth = YES;
    versionLabel.minimumScaleFactor = 0.7;
    versionLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [headerView addSubview:versionLabel];

    self.table.tableHeaderView = headerView;
    
    self.respringBtn = [[UIBarButtonItem alloc] initWithTitle:LOCALIZED(@"RESPRING") style:UIBarButtonItemStylePlain target:self action:@selector(respring)];
    //self.addSnippetBtn.tintColor = [UIColor blackColor];
    self.navigationItem.rightBarButtonItem = self.respringBtn;
    
}

-(id)readPreferenceValue:(PSSpecifier*)specifier{
    NSString *key = [specifier propertyForKey:@"key"];
    id value = [super readPreferenceValue:specifier];
    if (key.length > 0) {
        id storedValue = [[DXPrefsManager sharedInstance] getValueForKey:key];
        if (storedValue != nil) value = storedValue;
    }
    return value;
}


- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier{
    NSString *key = [specifier propertyForKey:@"key"];
    if (key.length > 0) {
        // Keep PreferenceLoader UI writes on the same CFPreferences/plist path
        // used by SpringBoard and the keyboard process.
        [[DXPrefsManager sharedInstance] setValue:value forKey:key];
    } else {
        [super setPreferenceValue:value specifier:specifier];
    }
}

- (void)respring {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"MUBX" message:LOCALIZED(@"RESPRING_MESSAGE") preferredStyle:UIAlertControllerStyleAlert];
    
    UIAlertAction *respringAction = [UIAlertAction actionWithTitle:LOCALIZED(@"ANSWER_YES") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        
        NSURL *relaunchURL = [NSURL URLWithString:@"prefs:root=TypeX"];
        SBSRelaunchAction *restartAction = [NSClassFromString(@"SBSRelaunchAction") actionWithReason:@"RestartRenderServer" options:4 targetURL:relaunchURL];
        [[NSClassFromString(@"FBSSystemService") sharedService] sendActions:[NSSet setWithObject:restartAction] withResult:nil];
        
        /*
         pid_t pid;
         int status;
         const char *args[] = {"killall", "-9", "SpringBoard", NULL};
         posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, (char * const *)args, NULL);
         waitpid(pid, &status, WEXITED);
         */
    }];
    
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:LOCALIZED(@"ANSWER_NO") style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        [self dismissViewControllerAnimated:YES completion:nil];
    }];
    
    [alert addAction:respringAction];
    [alert addAction:cancelAction];
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)controller {
    NSArray *all = self.allSettingsSpecifiers ?: [self.specifiers copy];
    NSMutableArray *rows = [NSMutableArray array];
    for (PSSpecifier *specifier in all) {
        NSString *text = [NSString stringWithFormat:@"%@ %@", specifier.name ?: @"", [specifier propertyForKey:@"footerText"] ?: @""];
        [rows addObject:@{@"group": @(specifier.cellType == PSGroupCell), @"text": text}];
    }
    NSIndexSet *matches = DXSettingsSearchIndices(rows, controller.searchBar.text ?: @"");
    self.specifiers = [[all objectsAtIndexes:matches] mutableCopy];
    [self.table reloadData];
}
- (void)viewWillDisappear:(BOOL)animated {
    self.settingsSearch.active = NO;
    self.settingsSearch.searchBar.text = @"";
    [self updateSearchResultsForSearchController:self.settingsSearch];
    [self.view endEditing:YES];
    [super viewWillDisappear:animated];
}
-(BOOL)searchBarShouldBeginEditing:(UISearchBar *)searchBar{
    DXPrefsManager *prefsManager = [DXPrefsManager sharedInstance];
    NSUInteger tappedCount = [[prefsManager getValueForKey:@"searchedc"] longValue];
    [prefsManager setValue:@(tappedCount + 1) forKey:@"searchedc"];
    if (tappedCount + 1 == searchedCountEaster){
        [DXHelper showSearchCountEasterAlertFor:self searchController:self.settingsSearch count:tappedCount+1 delay:0.5];
    }
    return YES;
}

#pragma mark - 配置备份与恢复

// 备份信封：preferences 才是配置本体，其余是元信息。无信封的裸字典也接受，
// 兼容直接从 /var/mobile/Library/Preferences/com.lindo.typex.plist 拷出的旧备份。
static NSString *const DXPBackupFormatKey = @"_typexBackupFormat";
static NSString *const DXPBackupDateKey = @"_typexBackupDate";
static NSString *const DXPBackupPayloadKey = @"preferences";
static const NSInteger DXPBackupFormatVersion = 1;

- (void)showSimpleAlert:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"MUBX"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:LOCALIZED(@"ANSWER_YES") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)backupConfig:(PSSpecifier *)specifier {
    // Settings 进程是非沙盒身份，readPrefs 读的是权威偏好域（cfprefsd +
    // plist fallback 的合并结果），涵盖工具栏、手势、快捷方式、自定义动作、
    // AI 引擎/人设等全部配置。
    NSDictionary *prefs = [[DXPrefsManager sharedInstance] readPrefs];
    if (![prefs isKindOfClass:[NSDictionary class]] || prefs.count == 0) {
        [self showSimpleAlert:LOCALIZED(@"BACKUP_EMPTY")];
        return;
    }

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *timestamp = [formatter stringFromDate:[NSDate date]];

    NSDictionary *envelope = @{
        DXPBackupFormatKey: @(DXPBackupFormatVersion),
        DXPBackupDateKey: timestamp,
        DXPBackupPayloadKey: prefs,
    };
    NSURL *fileURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"MUBX-Config-%@.plist", timestamp]]];
    if (![envelope writeToFile:fileURL.path atomically:YES]) {
        [self showSimpleAlert:LOCALIZED(@"BACKUP_FAILED")];
        return;
    }
    self.pendingExportURL = fileURL;

    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForExportingURLs:@[fileURL] asCopy:YES];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)restoreConfig:(PSSpecifier *)specifier {
    // data 兜底保证改名丢扩展名的备份文件也能选中。
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypePropertyList, UTTypeData]];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    // pendingExportURL 非空说明这是导出选择器：临时文件已被系统复制到目标
    // 位置，清理后直接返回。恢复流程里该属性恒为 nil。
    NSURL *pendingExport = self.pendingExportURL;
    self.pendingExportURL = nil;
    if (pendingExport) {
        [[NSFileManager defaultManager] removeItemAtURL:pendingExport error:nil];
        return;
    }

    NSURL *url = urls.firstObject;
    if (url) [self importBackupFromURL:url];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    NSURL *pendingExport = self.pendingExportURL;
    self.pendingExportURL = nil;
    if (pendingExport) [[NSFileManager defaultManager] removeItemAtURL:pendingExport error:nil];
}

- (void)importBackupFromURL:(NSURL *)url {
    BOOL accessing = [url startAccessingSecurityScopedResource];
    NSDictionary *file = [NSDictionary dictionaryWithContentsOfFile:url.path];
    if (accessing) [url stopAccessingSecurityScopedResource];

    NSDictionary *restored = nil;
    if ([file isKindOfClass:[NSDictionary class]]) {
        NSNumber *format = file[DXPBackupFormatKey];
        id payload = file[DXPBackupPayloadKey];
        if ([format isKindOfClass:[NSNumber class]] && format.integerValue == DXPBackupFormatVersion &&
            [payload isKindOfClass:[NSDictionary class]]) {
            restored = payload;
        } else if (file.count > 0) {
            restored = file;
        }
    }
    if (restored.count == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:LOCALIZED(@"RESTORE_FAILED_TITLE")
                                                                       message:LOCALIZED(@"RESTORE_FAILED_MESSAGE")
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:LOCALIZED(@"ANSWER_YES") style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    NSString *message = [NSString stringWithFormat:LOCALIZED(@"RESTORE_CONFIRM_MESSAGE"), (unsigned long)restored.count];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:LOCALIZED(@"RESTORE_CONFIRM_TITLE")
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:LOCALIZED(@"ANSWER_NO") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:LOCALIZED(@"ANSWER_YES") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        // Settings 进程（非沙盒）里 writePrefs 替换整个权威偏好域并镜像
        // 快照，末尾广播 prefschanged：SpringBoard 与键盘进程自动重载。
        [[DXPrefsManager sharedInstance] writePrefs:restored];
        [self reloadSpecifiers];

        UIAlertController *done = [UIAlertController alertControllerWithTitle:@"MUBX"
                                                                      message:LOCALIZED(@"RESTORE_DONE")
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [done addAction:[UIAlertAction actionWithTitle:LOCALIZED(@"ANSWER_YES") style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:done animated:YES completion:nil];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
