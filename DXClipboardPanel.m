#import "DXClipboardPanel.h"
#import "DXClipboardStore.h"
#import "common.h"
#import "DXShared.h"
#import "DXHelper.h"
#import "TypeX.h"
#import <notify.h>
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>

// ---------------------------------------------------------------------------
// 剪贴板面板（TypeX 内置，取代 Kayoko 剪贴板 UI）
// 承载：独立 UIWindow（windowLevel = 1000000.0，锚定键盘上方弹出，
// 不抢焦点、不收宿主键盘，输入光标保留；搜索框聚焦时面板跟随键盘上移，
// 键盘保持自然显示）
// 数据：SpringBoard 发布的 cfprefsd 快照 kClipboardSnapshotKey
// 命令：写 kClipboardCommandKey + 广播 kClipboardCommandIdentifier（SB 执行）
// ---------------------------------------------------------------------------

@interface DXClipboardHostWindow : UIWindow
@end

@implementation DXClipboardHostWindow
// 只响应卡片区域（tag=100），卡片以外的触摸穿透回下层窗口（宿主内容）。
// 面板锚定在键盘上方，不与键盘重叠；搜索框聚焦升起的键盘自然露出。
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
- (void)sendCommand:(NSDictionary *)command;
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
    // 与 DXAIPanel 同款：卡片锚定"键盘上方"，绝不试图盖住键盘。
    // iOS 17+ 键盘是系统远程托管窗口，宿主进程内任何 windowLevel 都压不过它，
    // 且键盘 frame 必须经视图链换算（UIKeyboardImpl 本身是全屏容器）。
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

    CGFloat maxHeight = keyboardVisible ? (keyboardTop - topInset - 12.0)
                                        : (screenHeight - topInset - bottomInset);
    maxHeight = MAX(maxHeight, 240);
    CGFloat height = MIN(maxHeight, MAX(280.0, screenHeight * 0.52));
    CGFloat y = keyboardVisible ? (keyboardTop - 10.0 - height)
                                : (screenHeight - bottomInset - height);
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
    // 沙盒 App 进程读不到 cfprefsd 隔离域（设置 App 等未沙盒进程可以），
    // 普通 App 面板一律优先读 jbroot 共享快照文件（SpringBoard 双写）。
    NSDictionary *snapshot = DXReadSharedPlistFile(TypeXClipboardSnapshotPath);
    if (![snapshot isKindOfClass:[NSDictionary class]]) {
        snapshot = DXQuickActionSharedValue(kClipboardSnapshotKey);
    }
    if (![snapshot isKindOfClass:[NSDictionary class]]) {
        snapshot = @{};
    }
    NSArray *history = snapshot[@"history"];
    NSArray *favorites = snapshot[@"favorites"];
    self.historyItems = [history isKindOfClass:[NSArray class]] ? history : @[];
    self.favoriteItems = [favorites isKindOfClass:[NSArray class]] ? favorites : @[];
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
    // 搜索结束：键盘收起，面板随 keyboardHidden 联动关闭；无特殊处理。
    (void)searchBar;
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
        [self sendCommand:@{
            @"action": @"clear",
            @"historyKey": self.isFavoritesTab ? @"favorites" : @"history",
        }];
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
            [self sendCommand:@{ @"action": @"delete", @"id": itemID }];
        }
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:[self localized:@"取消"] ?: @"取消"
                                             style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:menu animated:YES completion:nil];
}

- (void)sendFavoriteCommand:(BOOL)favorite historyKey:(NSString *)historyKey content:(NSString *)content {
    [self sendCommand:@{
        @"action": @"favorite",
        @"favorite": @(favorite),
        @"historyKey": historyKey ?: @"history",
        @"content": content ?: @"",
    }];
}

// 命令通道：沙盒 App 进程写 jbroot 共享命令文件（SpringBoard 读后即删），
// 同时广播 Darwin 通知唤醒 SpringBoard；未沙盒进程直接走 cfprefsd 域。
- (void)sendCommand:(NSDictionary *)command {
    if (![command isKindOfClass:[NSDictionary class]]) return;
    DXWriteSharedPlistFile(command, TypeXClipboardCommandPath);
    DXSetQuickActionSharedValue(command, kClipboardCommandKey);
    notify_post([kClipboardCommandIdentifier UTF8String]);
}

- (void)copyItem:(NSDictionary *)item {
    NSString *content = item[@"content"] ?: @"";
    NSString *imageName = item[@"image_name"] ?: @"";
    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
    if (imageName.length > 0) {
        NSString *mirrorPath = DX_ROOT_PATH_NS(@"/Library/TypeX/clipboard-images");
        NSString *imagePath = [mirrorPath stringByAppendingPathComponent:imageName];
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
        NSString *mirrorPath = DX_ROOT_PATH_NS(@"/Library/TypeX/clipboard-images");
        NSString *imagePath = [mirrorPath stringByAppendingPathComponent:imageName];
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
    cell.metaLabel.text = [NSString stringWithFormat:@"%@  %@", bundle, time];
    cell.starView.hidden = !self.isFavoritesTab;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *item = [self itemAtIndexPath:indexPath];
    if (!item) return;

    // 1) 写入剪贴板（粘贴语义：内容即所见）。
    [self copyItem:item];
    // 2) 触发粘贴到当前输入框。
    [self pasteToCurrentInput];
    // 3) 填入后自动关闭面板。
    [DXClipboardPanel dismiss];
}

- (void)pasteToCurrentInput {
    UIKeyboardImpl *keyboard = [objc_getClass("UIKeyboardImpl") activeInstance];
    if (!keyboard) return;
    UIResponder *input = DXKeyboardInputDelegate(keyboard);
    if (!input) return;

    if ([input respondsToSelector:@selector(paste:)]) {
        [input paste:nil];
    } else if ([input respondsToSelector:@selector(insertText:)]) {
        NSString *text = [UIPasteboard generalPasteboard].string;
        if (text.length > 0) [(id)input insertText:text];
    }
}

@end

#pragma mark - Panel Host

static DXClipboardHostWindow *g_clipboardPanelWindow;
static DXClipboardPanelController *g_clipboardPanelController;

@implementation DXClipboardPanel

+ (BOOL)isVisible {
    return g_clipboardPanelWindow != nil && !g_clipboardPanelWindow.hidden;
}

static BOOL DXClipboardProbeKeyboardFrame(CGRect *outFrame) {
    // 经视图链换算真实键盘本体 frame：UIKeyboardImpl 是全屏容器（部分 iOS
    // 版本 frame 覆盖整个输入窗口且 hidden 不可信），直接取 .window.frame
    // 会得到整屏，导致面板锚错位置。
    UIKeyboardImpl *keyboard = [objc_getClass("UIKeyboardImpl") activeInstance];
    if (!keyboard || !keyboard.window || keyboard.window.hidden) return NO;
    CGRect inWindow = [keyboard convertRect:keyboard.bounds toView:keyboard.window];
    CGRect inScreen = [keyboard.window convertRect:inWindow toWindow:nil];
    CGFloat screenHeight = CGRectGetHeight(keyboard.window.bounds);
    if (CGRectIsNull(inScreen) || CGRectGetHeight(inScreen) <= 10.0) return NO;
    if (CGRectGetMinY(inScreen) <= 0.0) return NO;              // 全屏容器，非键盘本体
    if (CGRectGetMinY(inScreen) >= screenHeight - 10.0) return NO; // 已滑出屏幕
    *outFrame = inScreen;
    return YES;
}

// 面板锚定键盘上方，不需要盖过键盘——windowLevel 只需高于宿主内容即可。
// 与 DXAIPanel 同值（1000000.0）。
static const CGFloat kClipboardPanelWindowLevel = 1000000.0;

+ (void)present {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self present]; });
        return;
    }
    if ([self isVisible]) {
        [self refresh];
        return;
    }

    DXClipboardPanelController *controller = [DXClipboardPanelController new];
    g_clipboardPanelController = controller;

    // 窗口必须挂到前台 scene 才能可靠显示；iOS 17+ 用无 scene 的
    // initWithFrame: 建窗会产生"挂在黑场里的空白窗口"（面板空白弹出）。
    // 键盘工具栏按钮总在宿主 app 进程触发，keyboard window 一定在屏。
    UIWindowScene *scene = nil;
    UIKeyboardImpl *keyboard = [objc_getClass("UIKeyboardImpl") activeInstance];
    scene = keyboard.window.windowScene;
    if (!scene) scene = DXKeyWindow().windowScene;
    for (UIScene *connected in [UIApplication sharedApplication].connectedScenes) {
        if (!scene && [connected isKindOfClass:[UIWindowScene class]] &&
            connected.activationState == UISceneActivationStateForegroundActive) {
            scene = (UIWindowScene *)connected;
            break;
        }
    }
    if (!scene) return; // 无前台 scene：直接放弃弹出，避免空白窗口

    DXClipboardHostWindow *window = [[DXClipboardHostWindow alloc] initWithWindowScene:scene];
    window.frame = scene.coordinateSpace.bounds;
    window.windowLevel = kClipboardPanelWindowLevel;
    window.backgroundColor = UIColor.clearColor;
    window.hidden = YES;
    window.rootViewController = controller;
    g_clipboardPanelWindow = window;

    // 键盘 frame 初值：活跃键盘实例（视图链换算）→ 屏幕底部占位。
    CGRect keyboardFrame = CGRectZero;
    if (!DXClipboardProbeKeyboardFrame(&keyboardFrame)) {
        CGRect bounds = [UIScreen mainScreen].bounds;
        keyboardFrame = CGRectMake(0, CGRectGetHeight(bounds) - 260, CGRectGetWidth(bounds), 260);
    }
    controller.keyboardFrame = keyboardFrame;
    [controller reloadSnapshot];

    window.hidden = NO;

    // 键盘会话保留：面板不抢焦点、不收宿主键盘（输入光标不消失），
    // 面板锚定键盘上方，键盘保持自然显示。
    // 键盘位置跟踪：键盘移动（搜索聚焦/收起等）时面板跟随重定位。
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(keyboardFrameChanged:)
                                               name:UIKeyboardWillChangeFrameNotification
                                             object:nil];
    // 宿主/搜索键盘被收起（用户主动）时联动关面板。
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(keyboardHidden:)
                                               name:UIKeyboardWillHideNotification
                                             object:nil];
    // 快照刷新。
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    (__bridge const void *)self,
                                    &DXClipboardSnapshotCallback,
                                    (CFStringRef)kClipboardChangedIdentifier,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}

+ (void)refresh {
    [g_clipboardPanelController reloadSnapshot];
    [g_clipboardPanelController viewWillLayoutSubviews];
}

+ (void)keyboardFrameChanged:(NSNotification *)note {
    NSValue *value = note.userInfo[UIKeyboardFrameEndUserInfoKey];
    if (![value isKindOfClass:[NSValue class]]) return;
    g_clipboardPanelController.keyboardFrame = value.CGRectValue;
    [g_clipboardPanelController viewWillLayoutSubviews];
}

+ (void)keyboardHidden:(NSNotification *)note {
    (void)note;
    [self dismiss];
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

    // 面板从不隐藏/改造键盘窗口，无需恢复任何状态。

    [NSNotificationCenter.defaultCenter removeObserver:self
                                                  name:UIKeyboardWillChangeFrameNotification
                                                object:nil];
    [NSNotificationCenter.defaultCenter removeObserver:self
                                                  name:UIKeyboardWillHideNotification
                                                object:nil];
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                       (__bridge const void *)self,
                                       (CFStringRef)kClipboardChangedIdentifier,
                                       NULL);

    g_clipboardPanelWindow.hidden = YES;
    g_clipboardPanelWindow.rootViewController = nil;
    g_clipboardPanelWindow = nil;
    g_clipboardPanelController = nil;
}

@end