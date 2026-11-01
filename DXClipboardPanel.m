#import "DXClipboardPanel.h"
#import "DXClipboardStore.h"
#import "common.h"
#import "DXShared.h"
#import "DXHelper.h"
#import "MUBX.h"
#import <notify.h>
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>

// 打开面板时被收起的宿主输入 responder（弱引用），点击条目粘贴前恢复焦点。
// 声明置于文件前部，供 DXClipboardPanelController 的 pasteItem: 与
// DXClipboardPanel 的 captureAndDismissHostKeyboard 共享。
static __weak UIResponder *g_clipboardRestoreResponder;
// 打开面板前的宿主 keyWindow（输入框所属窗口）。面板常驻且 windowLevel 最高，
// 显示后自己就成了 key window；恢复宿主输入前必须把 key 归还给它，否则
// becomeFirstResponder 因宿主窗口非 key 直接失败（点击条目不填入的根因）。
static __weak UIWindow *g_clipboardHostKeyWindow;

// ---------------------------------------------------------------------------
// 剪贴板面板（MUBX 内置，取代 Kayoko 剪贴板 UI）
// 呈现模型（参考 Kayoko）：打开时先主动收起宿主键盘（记录输入 responder，
// 粘贴时恢复原输入会话写回），面板从屏幕底部贴底弹出，不被键盘遮挡、不
// 依赖键盘 frame 探测；搜索聚焦时键盘重新弹出，面板自动上移避让。窗口与
// 控制器进程内常驻（首次创建一次，之后 hidden 切换，绝不销毁重建），保证
// 反复呼出始终有效（Kayoko installPanelInStatusBarWindow 同款生命周期）。
// 数据：宿主 App 进程直接读写 jbroot 共享 SQLite（DXClipboardStore），
// 删除/收藏/清空本地完成，不经 SpringBoard（Kayoko 同款架构）；快照
// 文件保留为兜底。
// 同步：每次本地改动广播 kClipboardChangedIdentifier，其他进程面板与
// SpringBoard 收到后各自刷新/重发快照。
// ---------------------------------------------------------------------------

@interface DXClipboardHostWindow : UIWindow
@end

@implementation DXClipboardHostWindow
// 只响应卡片区域（tag=100），卡片以外的触摸穿透回下层窗口（宿主内容）。
// 面板打开时键盘已收起、贴底弹出，不与键盘重叠；搜索聚焦升起的键盘在
// 卡片下方，仍可正常点击。
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIViewController *root = self.rootViewController;
    if (!root || self.hidden) return nil;
    if (root.presentedViewController != nil) {
        // 模态弹窗（清空/长按菜单/图片预览）挂在窗口层，走默认命中。
        return [super hitTest:point withEvent:event];
    }
    CGPoint local = [root.view convertPoint:point fromView:self];
    UIView *card = [root.view viewWithTag:100];
    if (card && !CGRectContainsPoint(card.frame, local)) return nil;
    return [root.view hitTest:local withEvent:event];
}
@end

#pragma mark - Cell

@interface DXClipboardCell : UITableViewCell
@property(nonatomic, strong) UIImageView *thumbView;
@property(nonatomic, strong) UILabel *textLabel2; // textLabel 被复用为标题
@property(nonatomic, strong) UILabel *metaLabel;
@property(nonatomic, strong) UIImageView *starView;
@property(nonatomic, strong) UIImageView *imageBadgeView;
@property(nonatomic, assign) BOOL showsThumbnail;
@end

@implementation DXClipboardCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.backgroundColor = UIColor.clearColor;

        _thumbView = [[UIImageView alloc] init];
        _thumbView.contentMode = UIViewContentModeScaleAspectFill;
        _thumbView.clipsToBounds = YES;
        _thumbView.layer.cornerRadius = 8.0;
        _thumbView.hidden = YES;
        [self.contentView addSubview:_thumbView];

        _textLabel2 = [[UILabel alloc] init];
        _textLabel2.font = [UIFont systemFontOfSize:15.0];
        _textLabel2.textColor = [UIColor labelColor];
        _textLabel2.numberOfLines = 2;
        _textLabel2.lineBreakMode = NSLineBreakByTruncatingTail;
        [self.contentView addSubview:_textLabel2];

        _metaLabel = [[UILabel alloc] init];
        _metaLabel.font = [UIFont systemFontOfSize:11.0];
        _metaLabel.textColor = [UIColor secondaryLabelColor];
        _metaLabel.numberOfLines = 1;
        [self.contentView addSubview:_metaLabel];

        _starView = [[UIImageView alloc] init];
        _starView.image = [UIImage systemImageNamed:@"star.fill"];
        _starView.tintColor = [UIColor systemYellowColor];
        _starView.hidden = YES;
        [self.contentView addSubview:_starView];

        _imageBadgeView = [[UIImageView alloc] init];
        _imageBadgeView.image = [UIImage systemImageNamed:@"photo"];
        _imageBadgeView.tintColor = [UIColor secondaryLabelColor];
        _imageBadgeView.hidden = YES;
        [self.contentView addSubview:_imageBadgeView];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.contentView.bounds);
    CGFloat height = CGRectGetHeight(self.contentView.bounds);
    CGFloat left = 16.0;
    if (self.showsThumbnail) {
        self.thumbView.frame = CGRectMake(left, 8, 56, height - 16);
        left += 56 + 12;
    }
    self.textLabel2.frame = CGRectMake(left, 8, width - left - 44, height - 26);
    self.metaLabel.frame = CGRectMake(left, height - 20, width - left - 44, 14);
    self.starView.frame = CGRectMake(width - 32, 12, 18, 18);
    self.imageBadgeView.frame = CGRectMake(width - 32, height - 30, 18, 18);
}

@end

#pragma mark - Panel Controller

@interface DXClipboardPanelController : UIViewController <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate, UIGestureRecognizerDelegate>
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, strong) UISearchBar *searchBar;
@property(nonatomic, strong) UISegmentedControl *segment;
@property(nonatomic, strong) UIButton *closeButton;
@property(nonatomic, strong) UIButton *clearButton;
@property(nonatomic, strong) UILabel *emptyLabel;
@property(nonatomic, strong) NSArray *historyItems;
@property(nonatomic, strong) NSArray *favoriteItems;
@property(nonatomic, strong) NSArray *displayedItems;
@property(nonatomic, assign) CGRect keyboardFrame;
@property(nonatomic, assign) BOOL isFavoritesTab;
@end

@interface DXClipboardPanelController ()
- (void)sendFavoriteCommand:(BOOL)favorite historyKey:(NSString *)historyKey content:(NSString *)content;
@end

@implementation DXClipboardPanelController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    // 面板卡片
    UIView *card = [[UIView alloc] initWithFrame:CGRectZero];
    card.backgroundColor = [UIColor secondarySystemBackgroundColor];
    card.layer.cornerRadius = 20.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.clipsToBounds = YES;
    card.tag = 100;
    [self.view addSubview:card];

    // 头部：关闭 | 标题 | 清空
    CGFloat headerHeight = 44.0;
    UILabel *title = [[UILabel alloc] init];
    title.text = [DXHelper localizedStringForActionNamed:@"clipboardAction:" shortName:NO bundle:[NSBundle bundleWithPath:bundlePath]] ?: @"剪贴板";
    title.font = [UIFont boldSystemFontOfSize:16.0];
    title.textColor = [UIColor labelColor];
    title.textAlignment = NSTextAlignmentCenter;
    title.frame = CGRectMake(56, 0, 0, headerHeight);
    title.tag = 101;
    [card addSubview:title];

    self.closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.closeButton setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
    self.closeButton.tintColor = [UIColor labelColor];
    [self.closeButton addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    self.closeButton.frame = CGRectMake(8, 2, 40, 40);
    self.closeButton.tag = 102;
    [card addSubview:self.closeButton];

    self.clearButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.clearButton setImage:[UIImage systemImageNamed:@"trash"] forState:UIControlStateNormal];
    self.clearButton.tintColor = [UIColor systemRedColor];
    [self.clearButton addTarget:self action:@selector(clearTapped) forControlEvents:UIControlEventTouchUpInside];
    self.clearButton.frame = CGRectZero;
    self.clearButton.tag = 103;
    [card addSubview:self.clearButton];

    // 分段：历史 / 收藏
    self.segment = [[UISegmentedControl alloc] initWithItems:@[
        [self localized:@"剪贴板历史"] ?: @"历史",
        [self localized:@"收藏"] ?: @"收藏",
    ]];
    self.segment.selectedSegmentIndex = 0;
    [self.segment addTarget:self action:@selector(segmentChanged) forControlEvents:UIControlEventValueChanged];
    self.segment.tag = 104;
    [card addSubview:self.segment];

    // 搜索
    self.searchBar = [[UISearchBar alloc] init];
    self.searchBar.delegate = self;
    self.searchBar.placeholder = [self localized:@"搜索剪贴板"] ?: @"搜索";
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.tag = 105;
    [card addSubview:self.searchBar];

    // 列表
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.backgroundColor = UIColor.clearColor;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = 64.0;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.tableView registerClass:[DXClipboardCell class] forCellReuseIdentifier:@"DXClipboardCell"];
    self.tableView.tag = 106;
    [card addSubview:self.tableView];

    // 空状态
    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.text = [self localized:@"暂无剪贴板记录"] ?: @"暂无内容";
    self.emptyLabel.textColor = [UIColor tertiaryLabelColor];
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.font = [UIFont systemFontOfSize:15.0];
    self.emptyLabel.hidden = YES;
    self.emptyLabel.tag = 107;
    [card addSubview:self.emptyLabel];

    // 长按菜单
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPress:)];
    longPress.minimumPressDuration = 0.5;
    longPress.delegate = self;
    [self.tableView addGestureRecognizer:longPress];

    [self reloadSnapshot];
}

- (NSString *)localized:(NSString *)key {
    NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
    return bundle ? [bundle localizedStringForKey:key value:nil table:nil] : nil;
}

// 复制来源显示名：Kayoko 同款语义 —— Continuity/Spotlight/SpringBoard 三个
// 系统进程特殊名，其余经 LSApplicationProxy.localizedName 转 App 名，取不到
// 则回落 bundle identifier（面板运行在宿主 App 进程，无 SBApplication 可用，
// 动态加载 CoreServices 类，避免引入链接依赖）。
static NSString *DXSourceDisplayNameForBundleIdentifier(NSString *bundleIdentifier) {
    NSString *bundleID = [bundleIdentifier stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!bundleID.length) return @"";
    NSString *normalized = [bundleID lowercaseString];
    if ([normalized isEqualToString:@"com.apple.pasteboard"] ||
        [normalized isEqualToString:@"continuity"] ||
        [normalized isEqualToString:@"handoff"]) {
        return @"Continuity";
    }
    if ([normalized isEqualToString:@"com.apple.spotlight"] ||
        [normalized isEqualToString:@"spotlight"]) {
        return @"Spotlight";
    }
    if ([normalized isEqualToString:@"com.apple.springboard"] ||
        [normalized isEqualToString:@"springboard"]) {
        return @"SpringBoard";
    }
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    if (proxyClass) {
        // 动态派发类方法，避免静态链接 MobileCoreServices 与编译器对未知
        // selector 的报错（no known class method）。
        id (*lookup)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
        id proxy = lookup(proxyClass, NSSelectorFromString(@"applicationProxyForIdentifier:"), bundleID);
        if ([proxy respondsToSelector:@selector(localizedName)]) {
            NSString *name = [proxy localizedName];
            if (name.length) return name;
        } else if ([proxy respondsToSelector:@selector(displayName)]) {
            NSString *name = [proxy displayName];
            if (name.length) return name;
        }
    }
    return bundleID;
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    [self layoutPanel];
}

// 真实键盘 frame（屏幕坐标）。优先用系统通知缓存的 frame；首帧尚未到达时
// 从活跃键盘实例经视图链换算出本体 frame——UIKeyboardImpl 是全屏容器，
// 直接取 .window.frame 会得到整屏，弹在屏幕底部就是那个 bug。
- (CGRect)resolvedKeyboardFrame {
    if (!CGRectIsEmpty(self.keyboardFrame) && CGRectGetMinY(self.keyboardFrame) > 0) {
        return self.keyboardFrame;
    }
    UIKeyboardImpl *keyboard = [objc_getClass("UIKeyboardImpl") activeInstance];
    if (!keyboard || !keyboard.window) return CGRectZero;
    CGRect inWindow = [keyboard convertRect:keyboard.bounds toView:keyboard.window];
    CGRect inScreen = [keyboard.window convertRect:inWindow toWindow:nil];
    CGFloat screenHeight = CGRectGetHeight(keyboard.window.bounds);
    if (CGRectIsNull(inScreen) || CGRectGetHeight(inScreen) <= 10.0) return CGRectZero;
    if (CGRectGetMinY(inScreen) <= 0.0) return CGRectZero;
    if (CGRectGetMinY(inScreen) >= screenHeight - 10.0) return CGRectZero;
    return inScreen;
}

- (void)layoutPanel {
    // Kayoko 式：面板默认贴屏幕底部弹出（打开时宿主键盘已收起，无须避让）。
    // 搜索框聚焦等场景键盘再次弹出时，面板上移到键盘上方，避免遮挡键盘
    // （也避免键盘盖住卡片底部）。键盘 frame 经视图链换算，从不依赖
    // windowLevel 与键盘竞争。
    UIWindow *window = self.view.window;
    CGRect screen = window ? window.bounds : [UIScreen mainScreen].bounds;
    CGFloat screenHeight = CGRectGetHeight(screen);
    CGFloat width = MIN(CGRectGetWidth(screen) - 24, 420);
    CGFloat x = (CGRectGetWidth(screen) - width) / 2;

    CGFloat topInset = (window ? window.safeAreaInsets.top : 0) + 8.0;
    CGFloat bottomInset = (window ? window.safeAreaInsets.bottom : 0) + 8.0;

    CGRect keyFrame = [self resolvedKeyboardFrame];
    BOOL keyboardVisible = CGRectGetMinY(keyFrame) > 0 &&
                           CGRectGetMinY(keyFrame) < screenHeight - 10.0;
    CGFloat keyboardTop = keyboardVisible ? CGRectGetMinY(keyFrame) : screenHeight;
    BOOL searchFocused = self.searchBar.isFirstResponder;

    CGFloat maxHeight = keyboardVisible ? (keyboardTop - topInset - 12.0)
                                        : (screenHeight - topInset - bottomInset);
    maxHeight = MAX(maxHeight, 240);
    CGFloat height = MIN(maxHeight, MAX(280.0, screenHeight * 0.52));
    CGFloat y;
    if (keyboardVisible && searchFocused) {
        y = keyboardTop - 10.0 - height;
    } else {
        y = screenHeight - bottomInset - height; // 贴底
    }
    if (y < topInset) y = topInset;

    UIView *card = [self.view viewWithTag:100];
    card.frame = CGRectMake(x, y, width, height);

    CGFloat headerHeight = 44.0;
    UILabel *title = [card viewWithTag:101];
    title.frame = CGRectMake(56, 0, width - 112, headerHeight);

    [card viewWithTag:102].frame = CGRectMake(8, 2, 40, 40); // close
    UIButton *clear = [card viewWithTag:103];
    clear.frame = CGRectMake(width - 48, 2, 40, 40);
    clear.hidden = NO;

    self.segment.frame = CGRectMake(16, headerHeight, width - 32, 30);
    self.searchBar.frame = CGRectMake(8, headerHeight + 36, width - 16, 40);
    CGFloat listTop = headerHeight + 80;
    self.tableView.frame = CGRectMake(0, listTop, width, height - listTop);
    self.emptyLabel.frame = CGRectMake(16, listTop + 60, width - 32, 40);
}

#pragma mark - Data

- (void)reloadSnapshot {
    // Kayoko 同款：面板在宿主 App 进程内直接查询 jbroot 共享数据库，
    // 因此删除/收藏/清空后无需等待 SpringBoard 命令回传。快照保留为
    // 数据库暂时不可用时的兼容兜底。
    DXClipboardStore *store = [DXClipboardStore sharedStore];
    if ([store prepareDatabase]) {
        self.historyItems = [store itemsForHistoryKey:@"history"
                                            searchText:nil
                                                 limit:kClipboardMaxCountDefault];
        self.favoriteItems = [store itemsForHistoryKey:@"favorites"
                                              searchText:nil
                                                   limit:kClipboardMaxCountDefault];
        NSLog(@"[MUBX][Clipboard][diag] reloadSnapshot via SQLite (%lu history, %lu favorites)",
              (unsigned long)self.historyItems.count, (unsigned long)self.favoriteItems.count);
    } else {
        NSDictionary *snapshot = DXReadSharedPlistFile(MUBXClipboardSnapshotPath);
        if (![snapshot isKindOfClass:[NSDictionary class]]) {
            snapshot = DXQuickActionSharedValue(kClipboardSnapshotKey);
        }
        NSArray *history = snapshot[@"history"];
        NSArray *favorites = snapshot[@"favorites"];
        self.historyItems = [history isKindOfClass:[NSArray class]] ? history : @[];
        self.favoriteItems = [favorites isKindOfClass:[NSArray class]] ? favorites : @[];
        NSLog(@"[MUBX][Clipboard][diag] reloadSnapshot via snapshot FALLBACK (%lu history, %lu favorites)",
              (unsigned long)self.historyItems.count, (unsigned long)self.favoriteItems.count);
    }
    [self refreshDisplayedItems];
}

- (void)refreshDisplayedItems {
    NSArray *source = self.isFavoritesTab ? self.favoriteItems : self.historyItems;
    NSString *keyword = self.searchBar.text;
    if (keyword.length > 0) {
        NSMutableArray *filtered = [NSMutableArray array];
        for (NSDictionary *item in source) {
            NSString *content = item[@"content"];
            if ([content isKindOfClass:[NSString class]] &&
                [content rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [filtered addObject:item];
            }
        }
        self.displayedItems = filtered;
    } else {
        self.displayedItems = source;
    }
    [self.tableView reloadData];
    self.emptyLabel.hidden = self.displayedItems.count > 0;
}

- (NSDictionary *)itemAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row < self.displayedItems.count) return self.displayedItems[indexPath.row];
    return nil;
}

#pragma mark - Actions

- (void)closeTapped { [DXClipboardPanel dismiss]; }
- (void)segmentChanged {
    self.isFavoritesTab = self.segment.selectedSegmentIndex == 1;
    [self refreshDisplayedItems];
}
- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    (void)searchBar; (void)searchText;
    [self refreshDisplayedItems];
}
- (BOOL)searchBarShouldBeginEditing:(UISearchBar *)searchBar {
    // 搜索聚焦：键盘自然弹出（面板不隐藏、不降级它），面板锚定键盘上方，
    // 键盘 frame 通知驱动 viewWillLayoutSubviews 跟随重定位。
    (void)searchBar;
    return YES;
}
- (void)searchBarTextDidEndEditing:(UISearchBar *)searchBar {
    // 搜索结束：键盘收起（原先联动关闭已去掉，面板保留）。清掉缓存的键盘
    // frame 并强排，让卡片回到屏幕底部弹出位。
    (void)searchBar;
    self.keyboardFrame = CGRectZero;
    [self viewWillLayoutSubviews];
}
- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

- (void)clearTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[self localized:@"清空剪贴板历史"]
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[self localized:@"取消"] ?: @"取消"
                                             style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:[self localized:@"清空"] ?: @"清空"
                                             style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        BOOL cleared = [[DXClipboardStore sharedStore] clearHistoryKey:self.isFavoritesTab ? @"favorites" : @"history"];
        NSLog(@"[MUBX][Clipboard][diag] clear %@ -> %d", self.isFavoritesTab ? @"favorites" : @"history", cleared);
        [self reloadSnapshot];
        notify_post([kClipboardChangedIdentifier UTF8String]);
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)longPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    CGPoint point = [gesture locationInView:self.tableView];
    NSIndexPath *indexPath = [self.tableView indexPathForRowAtPoint:point];
    if (!indexPath) return;
    NSDictionary *item = [self itemAtIndexPath:indexPath];
    if (!item) return;

    NSString *content = item[@"content"] ?: @"";
    NSString *historyKey = self.isFavoritesTab ? @"favorites" : @"history";
    BOOL isFavorite = self.isFavoritesTab;

    UIAlertController *menu = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    menu.popoverPresentationController.sourceView = self.tableView;
    menu.popoverPresentationController.sourceRect = [self.tableView rectForRowAtIndexPath:indexPath];

    [menu addAction:[UIAlertAction actionWithTitle:[self localized:@"复制"] ?: @"复制"
                                             style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        [self copyItem:item];
    }]];
    if (isFavorite) {
        [menu addAction:[UIAlertAction actionWithTitle:[self localized:@"取消收藏"] ?: @"取消收藏"
                                                 style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            (void)action;
            [self sendFavoriteCommand:NO historyKey:historyKey content:content];
        }]];
    } else {
        [menu addAction:[UIAlertAction actionWithTitle:[self localized:@"收藏"] ?: @"收藏"
                                                 style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            (void)action;
            [self sendFavoriteCommand:YES historyKey:historyKey content:content];
        }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:[self localized:@"删除"] ?: @"删除"
                                             style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        NSNumber *itemID = item[@"id"];
        if ([itemID isKindOfClass:[NSNumber class]]) {
            BOOL deleted = [[DXClipboardStore sharedStore] deleteItemWithID:[itemID integerValue]];
            NSLog(@"[MUBX][Clipboard][diag] delete itemID=%lld -> %d", (long long)[itemID longLongValue], deleted);
            [self reloadSnapshot];
            notify_post([kClipboardChangedIdentifier UTF8String]);
        }
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:[self localized:@"取消"] ?: @"取消"
                                             style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:menu animated:YES completion:nil];
}

- (void)sendFavoriteCommand:(BOOL)favorite historyKey:(NSString *)historyKey content:(NSString *)content {
    // Kayoko 同款：面板在宿主 App 进程内直接改共享存储，无需跨进程命令。
    BOOL set = [[DXClipboardStore sharedStore] setFavorite:favorite
                                                historyKey:historyKey ?: @"history"
                                                   content:content ?: @""];
    NSLog(@"[MUBX][Clipboard][diag] setFavorite=%d historyKey=%@ contentLen=%lu -> %d",
          favorite, historyKey ?: @"history", (unsigned long)(content ?: @"").length, set);
    [self reloadSnapshot];
    notify_post([kClipboardChangedIdentifier UTF8String]);
}

// 面板操作（Kayoko 同款架构）：面板在宿主 App 进程内直接读写 jbroot
// 共享 SQLite（kClipboardDatabasePath 位于 /var/jb/var/mobile/Library/...，
// App 沙盒可读写区），删除/收藏/清空不走跨进程命令。操作完成后本地
// 刷新并广播 kClipboardChangedIdentifier：SpringBoard 收到后重新发布
// 快照信息，其他 App 面板收到后调用 reloadSnapshot 同步。

- (void)copyItem:(NSDictionary *)item {
    NSString *content = item[@"content"] ?: @"";
    NSString *imageName = item[@"image_name"] ?: @"";
    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
    if (imageName.length > 0) {
        NSString *imagePath = [kClipboardImagesPath stringByAppendingPathComponent:imageName];
        UIImage *image = [UIImage imageWithContentsOfFile:imagePath];
        if (image) {
            pasteboard.image = image;
            return;
        }
    }
    if (content.length > 0) {
        pasteboard.string = content;
    }
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return self.displayedItems.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    DXClipboardCell *cell = [tableView dequeueReusableCellWithIdentifier:@"DXClipboardCell" forIndexPath:indexPath];
    NSDictionary *item = [self itemAtIndexPath:indexPath];

    NSString *content = item[@"content"] ?: @"";
    NSString *imageName = item[@"image_name"] ?: @"";
    NSString *bundle = item[@"bundle_identifier"] ?: @"";
    double capturedAt = [item[@"created_at"] doubleValue];

    cell.showsThumbnail = imageName.length > 0;
    cell.thumbView.hidden = !cell.showsThumbnail;
    cell.imageBadgeView.hidden = !cell.showsThumbnail;

    if (cell.showsThumbnail) {
        NSString *imagePath = [kClipboardImagesPath stringByAppendingPathComponent:imageName];
        cell.thumbView.image = [UIImage imageWithContentsOfFile:imagePath];
        cell.textLabel2.text = [self localized:@"（图片）"] ?: @"[图片]";
    } else {
        cell.thumbView.image = nil;
        cell.textLabel2.text = content;
    }

    NSString *time = @"";
    if (capturedAt > 0) {
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"MM-dd HH:mm";
        time = [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:capturedAt]];
    }
    NSString *sourceName = DXSourceDisplayNameForBundleIdentifier(bundle);
    cell.metaLabel.text = [NSString stringWithFormat:@"%@  %@", sourceName, time];
    cell.starView.hidden = !self.isFavoritesTab;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *item = [self itemAtIndexPath:indexPath];
    if (!item) return;

    // 1) 写入剪贴板（粘贴语义：内容即所见）。
    [self copyItem:item];
    // 2) 恢复宿主输入会话后触发粘贴（打开面板时键盘已收起；不恢复会话则
    //    无法把文本/图片写回原输入框）。
    [self pasteItem:item];
    // 3) 等恢复会话/插入完成后关闭面板（粘贴经过 0.1s 会话重建，dismiss
    //    也延迟同档，避免键盘刚回来就把窗口摘走）。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [DXClipboardPanel dismiss];
    });
}

// 恢复宿主输入会话并粘贴。与 DXAIPanel deliverReplyToHostInput 同款链路，
// 步骤顺序是关键：
//  1) 先把 key 归还给宿主窗口（面板常驻后自己成了 key window，不还 key 则
//     宿主输入框 becomeFirstResponder 失败——点击条目不填入的根因），
//  2) 再让保存的宿主输入 responder 重新成为第一响应者（键盘随之弹回），
//  3) 等会话重建后经 input delegate 直插文本；图片/失败走 paste: 兜底。
- (void)pasteItem:(NSDictionary *)item {
    UIWindow *hostKeyWindow = g_clipboardHostKeyWindow;
    if (hostKeyWindow && hostKeyWindow != self.view.window) {
        if (self.searchBar.isFirstResponder) [self.searchBar resignFirstResponder];
        [hostKeyWindow makeKeyWindow];
    } else {
        // 宿主窗口不可用（极端场景）：面板让出 key，等系统回落到宿主窗口。
        if (self.searchBar.isFirstResponder) [self.searchBar resignFirstResponder];
        if (DXKeyWindow() && DXKeyWindow() != self.view.window) {
            [DXKeyWindow() makeKeyWindow];
        }
    }

    UIResponder *restorable = g_clipboardRestoreResponder;
    UIKeyboardImpl *keyboard = [objc_getClass("UIKeyboardImpl") activeInstance];

    if (keyboard) {
        if (restorable && [restorable respondsToSelector:@selector(becomeFirstResponder)]) {
            [restorable becomeFirstResponder];
        } else {
            [keyboard becomeFirstResponder];
        }
    } else if (restorable && [restorable respondsToSelector:@selector(becomeFirstResponder)]) {
        [restorable becomeFirstResponder];
    }

    NSString *text = item[@"content"] ?: @"";
    BOOL hasImage = [item[@"image_name"] length] > 0;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIKeyboardImpl *liveKeyboard = [objc_getClass("UIKeyboardImpl") activeInstance] ?: keyboard;
        UIResponder *input = liveKeyboard ? DXKeyboardInputDelegate(liveKeyboard) : nil;
        BOOL delivered = NO;

        if (!hasImage && text.length > 0 && input && [input respondsToSelector:@selector(insertText:)]) {
            @try {
                [(id)input insertText:text];
                delivered = YES;
            } @catch (__unused NSException *exception) {
                // 落到键盘兜底
            }
        }
        if (!delivered && input && [input respondsToSelector:@selector(paste:)]) {
            @try {
                [(id)input paste:nil];
                delivered = YES;
            } @catch (__unused NSException *exception) {
                // 落到键盘兜底
            }
        }

        // Kayoko 同款兜底：经 key window 的第一响应者 responder chain 发
        // paste:（钥匙已归还宿主窗口，第一响应者就是宿主输入框）。内容在
        // 剪贴板里（copyItem: 已写入），不依赖 inputDelegate 解析，文本/
        // 图片都适用。
        if (!delivered) {
            @try {
                delivered = [[UIApplication sharedApplication]
                             sendAction:@selector(paste:) to:nil from:nil forEvent:nil];
            } @catch (__unused NSException *exception) {
                delivered = NO;
            }
        }

        if (!delivered) {
            @try {
                [liveKeyboard clearTransientState];
                [liveKeyboard clearAnimations];
                [liveKeyboard setCaretBlinks:YES];
            } @catch (__unused NSException *exception) {
                // 键盘兜底失败时内容已在 UIPasteboard，用户可手动粘贴
            }
        }
    });
}

@end

#pragma mark - Panel Host

// 窗口与控制器在进程内常驻：首次 present 创建，之后只做 hidden 切换
// （Kayoko installPanelInStatusBarWindow 同款生命周期），绝不销毁重建，
// 保证反复呼出始终有效。
static DXClipboardHostWindow *g_clipboardPanelWindow;
static DXClipboardPanelController *g_clipboardPanelController;

@implementation DXClipboardPanel

+ (BOOL)isVisible {
    return g_clipboardPanelWindow != nil && !g_clipboardPanelWindow.hidden;
}

// 面板打开时宿主键盘已收起，windowLevel 只需高于宿主内容即可。
// 与 DXAIPanel 同值（1000000.0）。
static const CGFloat kClipboardPanelWindowLevel = 1000000.0;

// 解析面板窗口应挂载的前台 scene。iOS 17 的系统键盘窗口是远程托管容器，
// keyboard.window.windowScene 未必属于当前前台 scene（键盘收起后随之失效，
// 面板窗口挂上去不可见），只作最后兜底；优先宿主 keyWindow / 已连接场景中
// 第一个 ForegroundActive 的 UIWindowScene。
static UIWindowScene *DXClipboardForegroundScene(void) {
    UIWindowScene *scene = DXKeyWindow().windowScene;
    if (scene && scene.activationState == UISceneActivationStateForegroundActive) {
        return scene;
    }
    for (UIScene *connected in [UIApplication sharedApplication].connectedScenes) {
        if ([connected isKindOfClass:[UIWindowScene class]] &&
            connected.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)connected;
        }
    }
    UIKeyboardImpl *keyboard = [objc_getClass("UIKeyboardImpl") activeInstance];
    return keyboard.window.windowScene;
}

// 观察者只注册一次，dismiss 只切 hidden 不注销——重复呼出不会重复注册、
// 面板也不会因键盘收起被误关（Kayoko 生命周期）。窗口因场景失效重建时
// 不重复注册。
static void DXClipboardRegisterObserversOnce(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [NSNotificationCenter.defaultCenter addObserver:[DXClipboardPanel class]
                                               selector:@selector(keyboardFrameChanged:)
                                                   name:UIKeyboardWillChangeFrameNotification
                                                 object:nil];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        (__bridge const void *)[DXClipboardPanel class],
                                        &DXClipboardSnapshotCallback,
                                        (CFStringRef)kClipboardChangedIdentifier,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    });
}

+ (void)present {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self present]; });
        return;
    }

    if (!g_clipboardPanelController) {
        g_clipboardPanelController = [DXClipboardPanelController new];
    }
    DXClipboardPanelController *controller = g_clipboardPanelController;

    // 每次呼出重新解析当前前台 scene：常驻窗口若挂在已失效的键盘容器
    // scene 上（iOS 17 键盘收起后），立即重建挂到前台 scene。
    UIWindowScene *scene = DXClipboardForegroundScene();
    if (!scene) {
        NSLog(@"[MUBX] DXClipboardPanel present: 无前台 scene，放弃弹出");
        return; // 无前台 scene：直接放弃弹出，避免空白窗口
    }

    if (!g_clipboardPanelWindow || g_clipboardPanelWindow.windowScene != scene) {
        if (!g_clipboardPanelWindow) {
            NSLog(@"[MUBX] DXClipboardPanel present: 首次创建窗口 scene=%@", scene);
        } else {
            NSLog(@"[MUBX] DXClipboardPanel present: 窗口场景失效重建 %@ -> %@",
                  g_clipboardPanelWindow.windowScene, scene);
        }

        DXClipboardHostWindow *window = [[DXClipboardHostWindow alloc] initWithWindowScene:scene];
        window.frame = scene.coordinateSpace.bounds;
        window.windowLevel = kClipboardPanelWindowLevel;
        window.backgroundColor = UIColor.clearColor;
        window.hidden = YES;
        window.rootViewController = controller;
        g_clipboardPanelWindow = window;
        DXClipboardRegisterObserversOnce();
    }

    // 若已可见：只刷新数据与位置，不重复收起键盘。
    if ([self isVisible]) {
        [self refresh];
        return;
    }

    // 打开前记录宿主当前输入 responder，并真正收起宿主键盘——面板贴底弹出
    // 后键盘不在屏上，彻底消除遮挡（Kayoko 打开即收键盘的行为）。
    [self captureAndDismissHostKeyboard];

    [controller reloadSnapshot];
    [controller viewWillLayoutSubviews];
    g_clipboardPanelWindow.hidden = NO;
    NSLog(@"[MUBX] DXClipboardPanel present: 面板已置为可见 frame=%@ level=%.1f",
          NSStringFromCGRect(g_clipboardPanelWindow.frame), g_clipboardPanelWindow.windowLevel);
    [controller viewWillLayoutSubviews];
}

// 记录宿主当前输入 responder（弱引用供粘贴前恢复）与宿主 keyWindow（供
// 粘贴时还 key），并收起宿主键盘让面板贴底弹出时无遮挡。键盘对象在 iOS 17
// 上是全屏容器、远程托管，这里只对 input delegate（真正的输入框）做
// resignFirstResponder，不动键盘窗口本身。
+ (void)captureAndDismissHostKeyboard {
    // 面板此时尚未置为可见，DXKeyWindow 一定是宿主窗口——记住它，粘贴时
    // 恢复宿主输入会话前先把 key 还给它（面板常驻后自己接管了 key）。
    g_clipboardHostKeyWindow = DXKeyWindow();

    UIResponder *input = nil;
    UIKeyboardImpl *keyboard = [objc_getClass("UIKeyboardImpl") activeInstance];
    if (keyboard) {
        input = DXKeyboardInputDelegate(keyboard);
    }
    if (!input) {
        // input delegate 不可用（外部键盘等场景）：经 key 窗口读当前
        // first responder（UIWindow.firstResponder 是私有属性，用消息发送
        // 读取，避免公开 API 编译告警）。
        UIWindow *keyWindow = DXKeyWindow();
        if (keyWindow) {
            SEL firstResponderSelector = NSSelectorFromString(@"firstResponder");
            if ([keyWindow respondsToSelector:firstResponderSelector]) {
                input = ((id (*)(id, SEL))objc_msgSend)(keyWindow, firstResponderSelector);
                if (![input isKindOfClass:[UIResponder class]]) input = nil;
            }
        }
    }
    g_clipboardRestoreResponder = input;

    UIView *inputView = [input isKindOfClass:[UIView class]] ? (UIView *)input : nil;
    if (inputView && inputView.isFirstResponder) {
        [inputView resignFirstResponder];
    } else if ([input respondsToSelector:@selector(resignFirstResponder)]) {
        // input delegate 可能不是 UITextField 本体（内部 responder 链），
        // 无条件尝试收回宿主键盘；responder chain 上失败无副作用。
        [input resignFirstResponder];
    }
    // 兜底：收 key 窗口级联键盘（不碰面板自身搜索框）。
    if (![g_clipboardPanelController.searchBar isFirstResponder]) {
        UIWindow *keyWindow = DXKeyWindow();
        if (keyWindow && keyWindow != g_clipboardPanelWindow) {
            [keyWindow endEditing:YES];
        }
    }
}

+ (void)refresh {
    [g_clipboardPanelController reloadSnapshot];
    [g_clipboardPanelController viewWillLayoutSubviews];
}

+ (void)keyboardFrameChanged:(NSNotification *)note {
    if (!g_clipboardPanelController) return;
    NSValue *value = note.userInfo[UIKeyboardFrameEndUserInfoKey];
    if (![value isKindOfClass:[NSValue class]]) return;
    // 仅搜索聚焦等场景键盘重新弹出时使用：更新缓存的键盘 frame，驱动
    // layoutPanel 让卡片上移避让；其余情况避免无谓重排。
    if (g_clipboardPanelController.searchBar.isFirstResponder) {
        g_clipboardPanelController.keyboardFrame = value.CGRectValue;
        [g_clipboardPanelController viewWillLayoutSubviews];
    }
}

static void DXClipboardSnapshotCallback(CFNotificationCenterRef center, void *observer,
                                        CFStringRef name, const void *object,
                                        CFDictionaryRef userInfo) {
    (void)center; (void)name; (void)object; (void)userInfo;
    DXClipboardPanel *panel = (__bridge DXClipboardPanel *)observer;
    (void)panel;
    dispatch_async(dispatch_get_main_queue(), ^{
        [DXClipboardPanel refresh];
    });
}

+ (void)dismiss {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self dismiss]; });
        return;
    }
    if (!g_clipboardPanelWindow) return;

    // 收起搜索框焦点（若有），隐藏面板。窗口/控制器/观察者全部保留——
    // 常驻模型下再次 present 只重新显示，保证反复呼出始终有效。
    if ([g_clipboardPanelController.searchBar isFirstResponder]) {
        [g_clipboardPanelController.searchBar resignFirstResponder];
    }
    g_clipboardPanelWindow.hidden = YES;
}

@end
