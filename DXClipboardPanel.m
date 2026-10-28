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
// 承载：独立 UIWindow（level 1e6，锚定键盘上方，只显示不抢焦点）
// 数据：SpringBoard 发布的 cfprefsd 快照 kClipboardSnapshotKey
// 命令：写 kClipboardCommandKey + 广播 kClipboardCommandIdentifier（SB 执行）
// ---------------------------------------------------------------------------

@interface DXClipboardHostWindow : UIWindow
@end
@implementation DXClipboardHostWindow
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    // 面板区域之外的事件穿透到宿主（与 DXAIHostWindow 同策略）。
    return [super pointInside:point withEvent:event];
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

- (void)layoutPanel {
    CGRect screen = [UIScreen mainScreen].bounds;
    CGFloat width = MIN(CGRectGetWidth(screen) - 24, 420);
    CGFloat maxHeight = CGRectGetHeight(screen) * 0.62;
    CGFloat keyboardTop = CGRectGetHeight(screen);
    if (!CGRectIsEmpty(self.keyboardFrame) && CGRectGetMinY(self.keyboardFrame) > 0) {
        keyboardTop = CGRectGetMinY(self.keyboardFrame);
    }
    CGFloat height = MIN(maxHeight, MAX(240, keyboardTop - 80));
    CGFloat x = (CGRectGetWidth(screen) - width) / 2;
    CGFloat y = keyboardTop - height - 8;

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
    NSDictionary *snapshot = DXQuickActionSharedValue(kClipboardSnapshotKey);
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
        DXSetQuickActionSharedValue(@{
            @"action": @"clear",
            @"historyKey": self.isFavoritesTab ? @"favorites" : @"history",
        }, kClipboardCommandKey);
        notify_post([kClipboardCommandIdentifier UTF8String]);
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
            DXSetQuickActionSharedValue(@{ @"action": @"delete", @"id": itemID }, kClipboardCommandKey);
            notify_post([kClipboardCommandIdentifier UTF8String]);
        }
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:[self localized:@"取消"] ?: @"取消"
                                             style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:menu animated:YES completion:nil];
}

- (void)sendFavoriteCommand:(BOOL)favorite historyKey:(NSString *)historyKey content:(NSString *)content {
    DXSetQuickActionSharedValue(@{
        @"action": @"favorite",
        @"favorite": @(favorite),
        @"historyKey": historyKey ?: @"history",
        @"content": content ?: @"",
    }, kClipboardCommandKey);
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
        if (text.length > 0) [input insertText:text];
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
    // 优先取活跃键盘实例所在窗口 frame；失败回退屏幕底部默认带。
    UIKeyboardImpl *keyboard = [objc_getClass("UIKeyboardImpl") activeInstance];
    if (keyboard && keyboard.window && !keyboard.window.hidden) {
        CGRect frame = keyboard.window.frame;
        if (CGRectGetHeight(frame) > 0) {
            *outFrame = frame;
            return YES;
        }
    }
    return NO;
}

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

    DXClipboardHostWindow *window = nil;
    UIWindowScene *scene = nil;
    UIKeyboardImpl *keyboard = [objc_getClass("UIKeyboardImpl") activeInstance];
    scene = keyboard.window.windowScene;
    if (!scene) scene = DXKeyWindow().windowScene;
    for (UIScene *connected in [UIApplication sharedApplication].connectedScenes) {
        if (!scene && [connected isKindOfClass:[UIWindowScene class]]) {
            scene = (UIWindowScene *)connected;
            break;
        }
    }

    if (scene) {
        window = [[DXClipboardHostWindow alloc] initWithWindowScene:scene];
        window.frame = scene.coordinateSpace.bounds;
    } else {
        window = [[DXClipboardHostWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    }
    window.windowLevel = 1000000.0;
    window.backgroundColor = UIColor.clearColor;
    window.hidden = YES;
    window.rootViewController = controller;
    g_clipboardPanelWindow = window;

    // 键盘 frame 初值：活跃键盘实例 → 通知缓存 → 屏幕底部占位。
    CGRect keyboardFrame = CGRectZero;
    if (!DXClipboardProbeKeyboardFrame(&keyboardFrame)) {
        CGRect bounds = [UIScreen mainScreen].bounds;
        keyboardFrame = CGRectMake(0, CGRectGetHeight(bounds) - 260, CGRectGetWidth(bounds), 260);
    }
    controller.keyboardFrame = keyboardFrame;
    [controller reloadSnapshot];

    window.hidden = NO;

    // 键盘位置跟踪：面板随键盘移动/隐藏。
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(keyboardFrameChanged:)
                                               name:UIKeyboardWillChangeFrameNotification
                                             object:nil];
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