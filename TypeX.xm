#import "common.h"
#import "TypeX.h"
#import "DXShared.h"
#import "DXHelper.h"
#import "DXQuickActionProvider.h"
#import "DXPasteChip.h"
#import "DXAIPanel.h"
#import "DXKeyboardPanel.h"
#import "DXGlobalPanel.h"
#import "DXStatusBarGestures.h"
#import "DXSystemOpenBroker.h"
#import "DXFloatingApp.h"
#import "DXFloatingAppInput.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <unistd.h>
#import <SpringBoardServices/SpringBoardServices.h>


id delegate;
UIKeyboardImpl *kbImpl;
UIColor *currentTintColor;
UIColor *currentBackgroundTintColor;
BOOL isLandscape = NO;
NSMutableDictionary *prefs;
BOOL isDictating = NO;
BOOL toggledOn = YES;
UIKeyboardDockView *dockView;
//BOOL isSandboxed = NO;
BOOL singleTapDictationEnabled = NO;
BOOL singleTapGlobeEnabled = NO;
BOOL isSpringBoard = YES;
BOOL isApplication = NO;
BOOL isSafari = NO;
//BOOL shouldSendScrollExecution = YES;
UIKeyboardDockView *dockV;
NSBundle *tweakBundle;
BOOL firstInit = YES;
DXStudlyCapsType spongebobEntropy;

static const CGFloat kDXTopToolbarHeight = 41.5;
static char kDXTopAccessoryContainerKey;
static NSUInteger topToolbarPresentationGeneration;
static __weak UIResponder *topToolbarCurrentResponder;

@interface DXTopAccessoryContainer : UIInputView
@property(nonatomic, strong) DXCollectionView *toolbar;
@property(nonatomic, strong) UIView *originalAccessory;
@end

@implementation DXTopAccessoryContainer

// 工具栏自身高度：多行模式随行数增长（preferredToolbarHeight），其余为固定
// 单行高度。容器与原附件的占位都跟随这个值。
- (CGFloat)dxToolbarHeight {
    CGFloat preferred = self.toolbar.preferredToolbarHeight;
    return preferred > 0.0 ? preferred : kDXTopToolbarHeight;
}

- (CGFloat)dxOriginalAccessoryHeight {
    if (!self.originalAccessory) return 0.0;
    CGFloat height = MAX(0.0, CGRectGetHeight(self.originalAccessory.frame));
    if (height <= 0.0) {
        CGFloat intrinsicHeight = [self.originalAccessory intrinsicContentSize].height;
        if (intrinsicHeight != UIViewNoIntrinsicMetric) height = MAX(0.0, intrinsicHeight);
    }
    return height;
}

- (CGFloat)dxDesiredHeight {
    CGFloat originalHeight = [self dxOriginalAccessoryHeight];
    return [self dxToolbarHeight] + (originalHeight > 0.0 ? originalHeight + 1.0 : 0.0);
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(UIViewNoIntrinsicMetric, [self dxDesiredHeight]);
}

// An input accessory is initially measured from its frame on some UIKit paths
// and from self-sizing on others.  Supplying both answers prevents the old
// one-row frame (41.5pt) from clipping the bottom/first row when multi-row mode
// increases the toolbar height.
- (CGSize)sizeThatFits:(CGSize)size {
    return CGSizeMake(size.width, [self dxDesiredHeight]);
}

- (CGSize)systemLayoutSizeFittingSize:(CGSize)targetSize {
    return CGSizeMake(targetSize.width, [self dxDesiredHeight]);
}

- (CGSize)systemLayoutSizeFittingSize:(CGSize)targetSize
        withHorizontalFittingPriority:(UILayoutPriority)horizontalFittingPriority
              verticalFittingPriority:(UILayoutPriority)verticalFittingPriority {
    return CGSizeMake(targetSize.width, [self dxDesiredHeight]);
}

- (void)dxSynchronizeHeight {
    CGFloat desiredHeight = [self dxDesiredHeight];
    [self invalidateIntrinsicContentSize];

    // Apple documents the frame as the sizing source for ordinary input
    // accessory views. UIInputView self-sizing covers the newer fitting path;
    // keeping the frame in sync also covers hosts that still use the former.
    CGRect frame = self.frame;
    // Row spacing is adjustable in 0.1pt steps, so preserve sub-point height
    // changes instead of treating them as layout noise.
    if (fabs(CGRectGetHeight(frame) - desiredHeight) > 0.01) {
        frame.size.height = desiredHeight;
        self.frame = frame;
    }
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat toolbarHeight = [self dxToolbarHeight];
    self.toolbar.frame = CGRectMake(0.0, 0.0, CGRectGetWidth(self.bounds), toolbarHeight);
    if (self.originalAccessory) {
        CGFloat originalHeight = [self dxOriginalAccessoryHeight];
        self.originalAccessory.frame = CGRectMake(0.0, toolbarHeight + 1.0,
                                                   CGRectGetWidth(self.bounds), originalHeight);
    }
    [self dxApplyBackgroundColor];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self dxApplyBackgroundColor];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self dxSynchronizeHeight];
    [self dxApplyBackgroundColor];
}

- (void)setBackgroundColor:(UIColor *)backgroundColor {
    if (backgroundColor && CGColorGetAlpha(backgroundColor.CGColor) > 0.01) {
        [super setBackgroundColor:backgroundColor];
    } else {
        [self dxApplyBackgroundColor];
    }
}

- (void)dxApplyBackgroundColor {
    UIColor *backgroundColor = self.originalAccessory.backgroundColor;
    if (!backgroundColor || CGColorGetAlpha(backgroundColor.CGColor) <= 0.01) {
        if (@available(iOS 13.0, *)) {
            backgroundColor = [UIColor systemBackgroundColor];
        } else {
            backgroundColor = [UIColor whiteColor];
        }
    }
    [super setBackgroundColor:backgroundColor];
}

@end

static inline BOOL DXResponderSupportsInputAccessoryView(UIResponder *responder) {
    return [responder respondsToSelector:@selector(setInputAccessoryView:)] &&
           [responder respondsToSelector:@selector(inputAccessoryView)];
}

// Messages' ChatKit input manages its own keyboard accessory (the compose bar
// stays visible with the keyboard dismissed and it validates its input session
// state). Replacing such a responder's inputAccessoryView aborts keyboard
// presentation, so the top toolbar must never take the accessory there. The
// dock toolbar is unaffected. The class-prefix check also covers ChatKit inputs
// hosted outside the Messages process (e.g. share-sheet composition).
static BOOL DXResponderHasManagedInputBar(UIResponder *responder) {
    static BOOL isMessagesProcess;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        isMessagesProcess = [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.MobileSMS"];
    });
    if (isMessagesProcess) return YES;

    Class cls = [responder class];
    for (NSInteger depth = 0; cls && depth < 4; depth++) {
        if ([NSStringFromClass(cls) hasPrefix:@"CK"]) return YES;
        cls = [cls superclass];
    }
    return NO;
}

static UIView *DXInputAccessoryView(UIResponder *responder) {
    if (!DXResponderSupportsInputAccessoryView(responder)) return nil;
    return [responder performSelector:@selector(inputAccessoryView)];
}

static void DXSetInputAccessoryView(UIResponder *responder, UIView *view) {
    if (DXResponderSupportsInputAccessoryView(responder)) {
        [responder performSelector:@selector(setInputAccessoryView:) withObject:view];
    }
}

static BOOL DXToolbarHasShortcuts(DXCollectionView *toolbar) {
    return toolbar.shortcutConfigurationAvailable &&
           [toolbar.shortcuts[kbuttonsImages12] count] > 0;
}

static BOOL DXBottomShelfMode(void) {
    id value = prefs[kFloatingShelfEnabledKey];
    return [value isKindOfClass:NSNumber.class] && [value boolValue];
}
static BOOL DXStockDockRequiresHiding(UIKeyboardDockView *dock) {
    // initWithFrame may run before the private dock-item tree is assembled.
    // A source declaration is not proof that this getter exists on each iOS.
    if (!dock.window) return NO;
    SEL selector = NSSelectorFromString(@"centerDockItem");
    NSMethodSignature *signature = [dock methodSignatureForSelector:selector];
    if (![dock respondsToSelector:selector] || signature.numberOfArguments != 2 ||
        strcmp(signature.methodReturnType, "@")) return NO;
    @try {
        id item = ((id (*)(id, SEL))objc_msgSend)(dock, selector);
        selector = NSSelectorFromString(@"view");
        signature = [item methodSignatureForSelector:selector];
        if (![item respondsToSelector:selector] || signature.numberOfArguments != 2 ||
            strcmp(signature.methodReturnType, "@")) return NO;
        id view = ((id (*)(id, SEL))objc_msgSend)(item, selector);
        return [view isKindOfClass:UIView.class] && !((UIView *)view).hidden;
    } @catch (__unused NSException *exception) { return NO; }
}
static void DXApplyBottomToolbarVisibility(UIKeyboardDockView *dock) {
    if (!dock) return;
    BOOL shelfMode = DXBottomShelfMode();
    BOOL stockHidden = DXStockDockRequiresHiding(dock);
    BOOL available = DXPrefsManager.sharedInstance.preferencesAvailable && preferencesBool(kEnabledkey, YES) &&
        toggledOn && !isLandscape && !isDictating && !stockHidden;
    dock.typex.hidden = !available || shelfMode || !DXToolbarHasShortcuts(dock.typex);
    dock.appShelf.hidden = !available || !shelfMode || !dock.appShelf.hasApps;
}

// An app can be injected before SpringBoard has finished seeding the shared
// snapshot.  DXPrefsManager intentionally keeps that first read unavailable
// instead of showing default buttons, but a later snapshot must be adopted by
// the already-running app.  Re-read only while unavailable so the normal
// toolbar/layout path stays cheap and a cold-launch race can recover without
// requiring the user to kill the app.
static BOOL DXReloadPreferencesIfUnavailable(void) {
    DXPrefsManager *manager = [DXPrefsManager sharedInstance];
    if (manager.preferencesAvailable) return NO;

    [manager reload];
    if (!manager.preferencesAvailable) return NO;

    prefs = [manager.prefs mutableCopy];
    toggledOn = preferencesBool(kToggledOnkey, YES);
    return YES;
}

static BOOL DXShouldDisplayTopAccessory(DXTopAccessoryContainer *container) {
    BOOL enabled = preferencesBool(kEnabledkey, YES);
    return enabled && toggledOn && !isLandscape && !isDictating &&
           DXToolbarHasShortcuts(container.toolbar);
}

static UIView *DXAccessoryByWrappingReplacement(UIResponder *responder, UIView *replacement) {
    DXTopAccessoryContainer *container = objc_getAssociatedObject(responder, &kDXTopAccessoryContainerKey);
    if (!container || DXResponderHasManagedInputBar(responder) ||
        replacement == container || replacement == container.toolbar ||
        !DXShouldDisplayTopAccessory(container)) {
        return replacement;
    }

    if (container.originalAccessory != replacement) {
        [container.originalAccessory removeFromSuperview];
        container.originalAccessory = replacement;
    }
    if (replacement && replacement.superview != container) {
        [container addSubview:replacement];
    }
    [container dxSynchronizeHeight];
    [container dxApplyBackgroundColor];
    return container;
}

static void DXInstallTopAccessoryForResponder(UIResponder *responder, BOOL reloadConfiguration) {
    if (!responder || (!isApplication && !isSpringBoard) ||
        DXResponderHasManagedInputBar(responder) || !DXResponderSupportsInputAccessoryView(responder)) return;

    BOOL preferencesRecovered = DXReloadPreferencesIfUnavailable();
    BOOL enabled = preferencesBool(kEnabledkey, YES);
    DXTopAccessoryContainer *container = objc_getAssociatedObject(responder, &kDXTopAccessoryContainerKey);
    UIView *currentAccessory = DXInputAccessoryView(responder);
    BOOL mayCreate = enabled && toggledOn && !isLandscape && !isDictating &&
                     [DXPrefsManager sharedInstance].preferencesAvailable;
    BOOL createdContainer = NO;

    if (!container && mayCreate) {
        container = [[DXTopAccessoryContainer alloc] initWithFrame:CGRectMake(0.0, 0.0, 0.0,
                                                                               kDXTopToolbarHeight)
                                                     inputViewStyle:UIInputViewStyleDefault];
        container.allowsSelfSizing = YES;
        // 与工具栏同源的方向钉扎：外层 trait 方向瞬态变化会让内部布局镜像，
        // 把容器钉在 LTR，工具栏继承到的 trait 方向随之稳定。
        container.semanticContentAttribute = UISemanticContentAttributeForceLeftToRight;
        container.clipsToBounds = YES;
        container.toolbar = [[DXCollectionView alloc] initWithConfiguration:@"top"];
        container.toolbar.clipsToBounds = YES;
        [container addSubview:container.toolbar];
        [container dxSynchronizeHeight];
        objc_setAssociatedObject(responder, &kDXTopAccessoryContainerKey, container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        createdContainer = YES;
    }
    if (!container) return;

    if ((reloadConfiguration || preferencesRecovered) && !createdContainer) {
        CGFloat previousToolbarHeight = CGRectGetHeight(container.toolbar.frame);
        // 偏好快照没变时跳过整表重载：无谓的 reloadData 让复用 cell 跨位置
        // 换位，键盘装配期多次重布局里会闪出一帧内容错位（顺序闪变根因）。
        // 快照对比覆盖按钮数据/样式/手势绑定/色调等全部可见输入；真正的偏好
        // 变更必然返回 YES，这里照常生效。
        if ([container.toolbar reloadShortcutConfiguration]) {
            [container.toolbar.collectionViewLayout invalidateLayout];
            [container.toolbar reloadData];
            // 多行模式增减行数会改变工具栏自身高度：失效容器高度并让输入视图重新
            // 测量，否则新行数要等键盘下一次重建才生效。
            if (fabs([container dxToolbarHeight] - previousToolbarHeight) > 0.01) {
                [container dxSynchronizeHeight];
                [container layoutIfNeeded];
                if (responder.isFirstResponder) [responder reloadInputViews];
            }
        }
    }

    BOOL shouldDisplay = DXShouldDisplayTopAccessory(container);
    if (!shouldDisplay) {
        container.toolbar.hidden = YES;
        if (currentAccessory == container) {
            [container.originalAccessory removeFromSuperview];
            DXSetInputAccessoryView(responder, container.originalAccessory);
            if (responder.isFirstResponder) [responder reloadInputViews];
        }
        return;
    }

    if (currentAccessory != container && currentAccessory != container.toolbar && currentAccessory != nil) {
        if (container.originalAccessory != currentAccessory) {
            [container.originalAccessory removeFromSuperview];
            container.originalAccessory = currentAccessory;
        }
        if (currentAccessory.superview != container) [container addSubview:currentAccessory];
        [container dxSynchronizeHeight];
    }

    [container dxApplyBackgroundColor];
    container.toolbar.hidden = NO;
    if (currentAccessory != container) {
        DXSetInputAccessoryView(responder, container);
        if (responder.isFirstResponder) [responder reloadInputViews];
    }
}

static UIResponder *DXTopToolbarResponder(UIKeyboardImpl *keyboard) {
    if (topToolbarCurrentResponder.isFirstResponder &&
        DXResponderSupportsInputAccessoryView(topToolbarCurrentResponder)) {
        return topToolbarCurrentResponder;
    }

    UIResponder *active = DXKeyboardInputDelegate(keyboard);
    if (DXResponderSupportsInputAccessoryView(active)) return active;

    SEL selectableSelector = NSSelectorFromString(@"selectableInputDelegate");
    if ([keyboard respondsToSelector:selectableSelector]) {
        id (*sendObject)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        UIResponder *selectable = sendObject(keyboard, selectableSelector);
        if (DXResponderSupportsInputAccessoryView(selectable)) return selectable;
    }
    return active;
}

static void DXRefreshActiveTopToolbarWithConfiguration(BOOL reloadConfiguration) {
    UIKeyboardImpl *keyboard = [objc_getClass("UIKeyboardImpl") activeInstance];
    UIResponder *responder = DXTopToolbarResponder(keyboard);
    static dispatch_once_t onceDiagToken;
    dispatch_once(&onceDiagToken, ^{
        // 一次性体检：进程内第一次键盘刷新时把顶部工具栏全部门控值打到 syslog。
        NSLog(@"[TypeX] diag: top refresh keyboard=%@ responder=%@ enabled=%d toggledOn=%d landscape=%d dictating=%d prefsAvail=%d",
              keyboard, NSStringFromClass([responder class]),
              preferencesBool(kEnabledkey, YES), toggledOn, isLandscape, isDictating,
              [DXPrefsManager sharedInstance].preferencesAvailable);
    });
    DXInstallTopAccessoryForResponder(responder, reloadConfiguration);
}

static void DXRefreshActiveTopToolbar(void) {
    DXRefreshActiveTopToolbarWithConfiguration(YES);
}

@interface DXTopToolbarLifecycleObserver : NSObject
@end

@implementation DXTopToolbarLifecycleObserver

- (void)keyboardDidShow:(NSNotification *)notification {
    (void)notification;
    NSUInteger generation = ++topToolbarPresentationGeneration;
    // The responder already loaded the current configuration before becoming
    // first responder. At this point only re-wrap the accessory UIKit finalized;
    // reloading the collection here exposes a second, visibly different layout
    // pass after the keyboard is already on screen.
    DXRefreshActiveTopToolbarWithConfiguration(NO);

    // Some keyboards install their own accessory asynchronously on their first
    // presentation. Retry after that work completes and wrap the final view.
    for (NSNumber *delay in @[@0.05, @0.20]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (generation == topToolbarPresentationGeneration) {
                DXRefreshActiveTopToolbarWithConfiguration(NO);
            }
        });
    }
}

- (void)keyboardWillHide:(NSNotification *)notification {
    (void)notification;
    ++topToolbarPresentationGeneration;
}

@end

static DXTopToolbarLifecycleObserver *topToolbarLifecycleObserver;

// TypeX 自带 AI 面板的 SpringBoard 端承载。键盘进程内建窗口会被限制在键盘宿主
// 区域内（第三方键盘扩展里完全无法悬浮），所以工具栏只写 ai-chat-request 通道，
// 面板统一在 SB 创建。origin=sb（桌面键盘工具栏）立即弹出；app 来源等回到桌面
// 再显示（超 5 分钟丢弃）。桌面可见性由 %hook SBHomeScreenViewController 维护，
// 不用 SBMainWorkspace/applicationState 探测——app 前台时 applicationState 恒
// Active，探测必然失效（3.0.84 的教训）。
static NSString *g_aiPendingSeedText;
static BOOL g_aiPendingClipboardImage;
static double g_aiPendingCreatedAt;
static BOOL g_aiDesktopVisible;

static void DXPresentAIPanelFromPending(void) {
    NSString *seed = g_aiPendingSeedText;
    BOOL clipboardImage = g_aiPendingClipboardImage;
    g_aiPendingSeedText = nil;
    g_aiPendingClipboardImage = NO;
    [DXAIPanel presentInSpringBoardWithSeedText:seed clipboardImage:clipboardImage];
}

static void DXPresentAIPanelWhenDesktop(void) {
    if (!g_aiPendingSeedText && !g_aiPendingClipboardImage) return;
    if (!g_aiDesktopVisible) return;
    if ([NSDate date].timeIntervalSince1970 - g_aiPendingCreatedAt > 300.0) {
        g_aiPendingSeedText = nil;
        g_aiPendingClipboardImage = NO;
        return;
    }
    DXPresentAIPanelFromPending();
}

static void DXOpenAIPanelWithRequest(NSDictionary *request) {
    NSString *requestID = [request[@"requestID"] isKindOfClass:[NSString class]] ? request[@"requestID"] : nil;
    if (requestID.length == 0) return;

    static NSString *lastAIRequestID;
    @synchronized(TypeXAIChatRequestKey) {
        if ([lastAIRequestID isEqualToString:requestID]) return;
        lastAIRequestID = [requestID copy];
    }

    // 请求带落盘时间戳，超过 30 秒视为陈旧投递（迟到通知的场景）。
    double created = [request[@"created"] isKindOfClass:[NSNumber class]] ? [request[@"created"] doubleValue] : 0;
    if (created <= 0 || fabs([NSDate date].timeIntervalSince1970 - created) > 30.0) return;

    NSString *mode = [request[@"mode"] isKindOfClass:[NSString class]] ? request[@"mode"] : nil;
    g_aiPendingSeedText = ([mode isEqualToString:@"text"] && [request[@"text"] isKindOfClass:[NSString class]])
        ? request[@"text"] : nil;
    if (g_aiPendingSeedText.length == 0) g_aiPendingSeedText = nil;
    g_aiPendingClipboardImage = [mode isEqualToString:@"image"];
    g_aiPendingCreatedAt = created;

    if ([request[@"origin"] isKindOfClass:[NSString class]] &&
        [request[@"origin"] isEqualToString:@"sb"]) {
        DXPresentAIPanelFromPending();
    } else {
        DXPresentAIPanelWhenDesktop();
    }
}

static void aiChatRequestCallback(CFNotificationCenterRef center,
                                  void *observer,
                                  CFStringRef name,
                                  const void *object,
                                  CFDictionaryRef userInfo) {
    NSDictionary *request = DXQuickActionSharedValue(TypeXAIChatRequestKey);
    if (![request isKindOfClass:[NSDictionary class]]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        DXOpenAIPanelWithRequest(request);
    });
}

// Button chrome (height/radius/spacing/border/width scale) is read per
// configuration inside DXCollectionView; there are no shared globals for it.

CGFloat heightOffset = heightOffsetDefault;

#pragma mark hook

// The iOS 16+ paste-permission alert ("允许「X」粘贴来自「Y」的内容？") is a plain
// in-process UIAlertController. Detection is deliberately narrow -- a two-action
// alert whose allow button carries the exact system string and whose title
// mentions pasting -- so no unrelated alert is ever dismissed. If a future iOS
// ships a different alert shape, the check fails closed and the prompt simply
// shows as usual.
static BOOL DXIsPastePermissionAlert(UIAlertController *alert) {
    if (alert.preferredStyle != UIAlertControllerStyleAlert) return NO;
    if (alert.actions.count != 2) return NO;

    NSString *title = alert.title ?: @"";
    BOOL titleMentionsPaste = [title containsString:@"粘贴"] ||
                              [title localizedCaseInsensitiveContainsString:@"paste"];
    if (!titleMentionsPaste) return NO;

    for (UIAlertAction *action in alert.actions) {
        NSString *actionTitle = action.title;
        if ([actionTitle isEqualToString:@"允许粘贴"] ||
            [actionTitle isEqualToString:@"Allow Paste"]) {
            return YES;
        }
    }
    return NO;
}

static void reloadPrefs(void);

%group TypeX

%hook UIKeyboardImpl

- (void)layoutSubviews {
    %orig;
    // The first keyboard presentation can finish wiring its input delegate only
    // after the responder's own becomeFirstResponder: has already returned.
    DXRefreshActiveTopToolbarWithConfiguration(NO);
}

%end

%hook UITextField

- (void)didMoveToWindow {
    %orig;
    if (self.window) DXInstallTopAccessoryForResponder(self, NO);
}

- (BOOL)becomeFirstResponder {
    // inputAccessoryView must be present before UIKit starts constructing the
    // first keyboard for this responder. Installing after %orig is too late in
    // Settings search fields and only takes effect on the next presentation.
    topToolbarCurrentResponder = self;
    DXInstallTopAccessoryForResponder(self, YES);
    BOOL result = %orig;
    if (result) {
        DXInstallTopAccessoryForResponder(self, NO);
    } else if (topToolbarCurrentResponder == self) {
        topToolbarCurrentResponder = nil;
    }
    return result;
}

- (void)setInputAccessoryView:(UIView *)inputAccessoryView {
    UIView *effectiveAccessory = DXAccessoryByWrappingReplacement(self, inputAccessoryView);
    %orig(effectiveAccessory);
}

- (void)layoutSubviews {
    %orig;
    if (self.isFirstResponder) {
        topToolbarCurrentResponder = self;
        DXInstallTopAccessoryForResponder(self, NO);
    }
}

%end

%hook UITextView

- (void)didMoveToWindow {
    %orig;
    if (self.window) DXInstallTopAccessoryForResponder(self, NO);
}

- (BOOL)becomeFirstResponder {
    topToolbarCurrentResponder = self;
    DXInstallTopAccessoryForResponder(self, YES);
    BOOL result = %orig;
    if (result) {
        DXInstallTopAccessoryForResponder(self, NO);
    } else if (topToolbarCurrentResponder == self) {
        topToolbarCurrentResponder = nil;
    }
    return result;
}

- (void)setInputAccessoryView:(UIView *)inputAccessoryView {
    UIView *effectiveAccessory = DXAccessoryByWrappingReplacement(self, inputAccessoryView);
    %orig(effectiveAccessory);
}

- (void)layoutSubviews {
    %orig;
    if (self.isFirstResponder) {
        topToolbarCurrentResponder = self;
        DXInstallTopAccessoryForResponder(self, NO);
    }
}

%end

%hook UIKeyboardDockView
//%property (retain, nonatomic) UIKeyboardDockItemButton *leftDockButton;
//%property (retain, nonatomic) UIKeyboardDockItemButton *rightDockButton;
%property (retain, nonatomic) DXCollectionView *typex;
%property (retain, nonatomic) DXFloatingAppShelfView *appShelf;

- (instancetype)initWithFrame:(CGRect)frame {
    dockView = %orig;
    if (preferencesBool(kEnabledkey,YES) && dockView) {
        self.typex = [[DXCollectionView alloc] initWithConfiguration:@"bottom"];
        
        //self.typex = [[DXCollectionView alloc] init];
        
        self.typex.translatesAutoresizingMaskIntoConstraints = NO;
        //self.typex.transform = CGAffineTransformMakeScale(-1, 1);
        
        [dockView addSubview:self.typex];
        
        // Stock globe/dictation buttons always stay; the toolbar sits between
        // them (69/-60 clear both stock buttons).
        float leading = DXBottomToolbarLeadingInset;
        float trailing = -DXBottomToolbarTrailingInset;

        NSLayoutConstraint *leadingConstraint = [NSLayoutConstraint constraintWithItem:self.typex attribute:NSLayoutAttributeLeading relatedBy:NSLayoutRelationEqual toItem:dockView attribute:NSLayoutAttributeLeading multiplier:1.0 constant:leading];
        leadingConstraint.identifier = @"TypeX";
        [dockView addConstraint:leadingConstraint];

        NSLayoutConstraint *trailingConstraint = [NSLayoutConstraint constraintWithItem:self.typex attribute:NSLayoutAttributeTrailing relatedBy:NSLayoutRelationEqual toItem:dockView attribute:NSLayoutAttributeTrailing multiplier:1.0 constant:trailing];
        trailingConstraint.identifier = @"TypeX";
        [dockView addConstraint:trailingConstraint];

        NSLayoutConstraint *heightConstraint = [NSLayoutConstraint constraintWithItem:self.typex attribute:NSLayoutAttributeHeight relatedBy:NSLayoutRelationEqual toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1.0 constant:heightOffset];
        heightConstraint.identifier = @"TypeX";
        [dockView addConstraint:heightConstraint];

        // Fixed lift above the dock's bottom edge (the former vertical-offset default).
        NSLayoutConstraint *bottomConstraint = [NSLayoutConstraint constraintWithItem:self.typex attribute:NSLayoutAttributeBottom relatedBy:NSLayoutRelationEqual toItem:dockView attribute:NSLayoutAttributeBottom multiplier:1.0 constant:-DXBottomToolbarBottomInset];
        bottomConstraint.identifier = @"TypeX";
        [dockView addConstraint:bottomConstraint];
        self.appShelf = [[DXFloatingAppShelfView alloc] initWithFrame:CGRectZero];
        self.appShelf.translatesAutoresizingMaskIntoConstraints = NO;
        [dockView addSubview:self.appShelf];
        [NSLayoutConstraint activateConstraints:@[
            [self.appShelf.leadingAnchor constraintEqualToAnchor:self.typex.leadingAnchor],
            [self.appShelf.trailingAnchor constraintEqualToAnchor:self.typex.trailingAnchor],
            [self.appShelf.topAnchor constraintEqualToAnchor:self.typex.topAnchor],
            [self.appShelf.bottomAnchor constraintEqualToAnchor:self.typex.bottomAnchor]
        ]];
        __weak UIKeyboardDockView *weakDock = self;
        self.appShelf.contentChanged = ^{ DXApplyBottomToolbarVisibility(weakDock); };


        dispatch_async(dispatch_get_main_queue(), ^{

            kbImpl = [objc_getClass("UIKeyboardImpl") activeInstance];
            delegate = DXKeyboardInputDelegate(kbImpl);
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(toggleTypeX:) name:@"toggleTypeX" object:nil];

            // The keyboard can finish creating its private subviews after UIKeyboardImpl's
            // first layout pass. Refresh once the dock has joined the hierarchy as well.
            DXRefreshActiveTopToolbar();
        });
        
    }
        DXApplyBottomToolbarVisibility(self);
        NSLog(@"[TypeX] diag: dock init typex=%@ enabled=%d toggledOn=%d shortcuts=%d",
              self.typex, preferencesBool(kEnabledkey, YES), toggledOn,
              DXToolbarHasShortcuts(self.typex));
    
    
    return dockV = dockView;
}

%new
- (void)performTypeXToggling:(UILongPressGestureRecognizer*)gesture{
    if (gesture.state == UIGestureRecognizerStateBegan){
        [[NSNotificationCenter defaultCenter] postNotificationName:@"toggleTypeX" object:nil];
    }
}

%new
- (void)performTypeXTogglingTap:(UITapGestureRecognizer*)gesture{
    //if (gesture.state == UIGestureRecognizerStateBegan){
    [[NSNotificationCenter defaultCenter] postNotificationName:@"toggleTypeX" object:nil];
    //}
}


- (void)setLeftDockItem:(UIKeyboardDockItem *)dockItem {
    if (preferencesBool(kEnabledkey,YES)){
        // Only read system tint when user hasn't set a custom color
        // (when kShortcutsTintEnabled is NO, meaning "follow system")
        if (!preferencesBool(kShortcutsTintEnabled,NO)){
            currentTintColor = dockItem.button.tintColor;
        }
        if (preferencesInt(kDedicatedGestureButtonkey, 0) == 1 || preferencesInt(kDedicatedGestureButtonkey, 0) == 3){
            %orig;
            if (preferencesInt(kGestureTypekey,0) == 1){
                singleTapGlobeEnabled = NO;
                UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(performTypeXToggling:)];
                longPress.minimumPressDuration = 0.3;
                [dockItem.button addGestureRecognizer:longPress];
            }else{
                singleTapGlobeEnabled = YES;
                [dockItem.button removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
                UITapGestureRecognizer *singleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(performTypeXTogglingTap:)];
                singleTap.numberOfTapsRequired = 1;
                [dockItem.button addGestureRecognizer:singleTap];
            }
            return;
        }
    }
    %orig;
    //self.leftDockButton = dockItem.button;
    /*
     UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(performOriginalLeftDockAction:)];
     longPress.minimumPressDuration = 0.5;
     
     //UITapGestureRecognizer *singleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(performTypeXToggling:)];
     //singleTap.numberOfTapsRequired = 1;
     
     [dockItem.button addGestureRecognizer:longPress];
     //[dockItem.button addGestureRecognizer:singleTap];
     %orig;
     [dockItem.button removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
     [dockItem.button addTarget:self action:@selector(performTypeXToggling:) forControlEvents:UIControlEventTouchUpInside];
     */
}
- (void)setRightDockItem:(UIKeyboardDockItem *)dockItem {
    if (preferencesBool(kEnabledkey,YES)){
        // Only read system tint when user hasn't set a custom color
        if (!preferencesBool(kShortcutsTintEnabled,NO)){
            currentTintColor = dockItem.button.tintColor;
        }
        if (preferencesInt(kDedicatedGestureButtonkey, 0) == 2 || preferencesInt(kDedicatedGestureButtonkey, 0) == 3){
            %orig;
            if (preferencesInt(kGestureTypekey,0) == 1){
                singleTapDictationEnabled = NO;
                UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(performTypeXToggling:)];
                longPress.minimumPressDuration = 0.3;
                [dockItem.button addGestureRecognizer:longPress];
            }else{
                singleTapDictationEnabled = YES;
                [dockItem.button removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
                UITapGestureRecognizer *singleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(performTypeXTogglingTap:)];
                singleTap.numberOfTapsRequired = 1;
                [dockItem.button addGestureRecognizer:singleTap];
            }
            return;
        }
    }
    %orig;
    /*
     NSData *archivedData = [NSKeyedArchiver archivedDataWithRootObject: dockItem.button];
     self.rightDockButton = [NSKeyedUnarchiver unarchiveObjectWithData: archivedData];
     
     UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(performOriginalRightDockAction:)];
     longPress.minimumPressDuration = 0.5;
     
     UITapGestureRecognizer *singleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(performTypeXToggling:)];
     singleTap.numberOfTapsRequired = 1;
     
     [dockItem.button addGestureRecognizer:longPress];
     [dockItem.button addGestureRecognizer:singleTap];
     %orig;
     
     [dockItem.button removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
     */
}

%new
-(void)toggleTypeX:(NSNotification*)notification{
    [[DXKeyboardPanel sharedInstance] dismiss];
    if (preferencesBool(kEnabledHaptickey,YES)){
        [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    }
    toggledOn = DXBottomShelfMode() ? self.appShelf.hidden : self.typex.hidden;
    [[DXPrefsManager sharedInstance] setValue:[NSNumber numberWithBool:toggledOn] forKey:kToggledOnkey];
    
    DXApplyBottomToolbarVisibility(self);
    if (self.typex.hidden) self.typex.alpha = 1.0f;
    else {
        self.typex.alpha = 0.0f;
        [UIView animateWithDuration:0.2 animations:^{ self.typex.alpha = 1.0f; }];
    }
    DXRefreshActiveTopToolbar();
    [self layoutSubviews];
    
}

%new
-(void)updateTypeXTint{
    // Only refresh tint when custom color is NOT enabled
    // (kShortcutsTintEnabled = NO means "follow system tint")
    if (preferencesBool(kShortcutsTintEnabled,NO)) return;

    UIColor *newTintColor = nil;
    if (self.leftDockItem.button){
        newTintColor = self.leftDockItem.button.tintColor;
    }else if (self.rightDockItem.button){
        newTintColor = self.rightDockItem.button.tintColor;
    }else{
        if (@available(iOS 13.0, *)){
            if (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
                newTintColor = [UIColor whiteColor];
            }else{
                newTintColor = [UIColor blackColor];
            }
        }
    }
    // Only notify if the tint actually changed to avoid unnecessary reloadData on every layout
    if (newTintColor && ![newTintColor isEqual:currentTintColor]) {
        currentTintColor = newTintColor;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"typeXLayoutChanged" object:nil];
    }
}

- (void)layoutSubviews{
    %orig;
    if (self.typex && DXReloadPreferencesIfUnavailable()) {
        [self.typex reloadShortcutConfiguration];
        [self.typex.collectionViewLayout invalidateLayout];
        [self.typex reloadData];
    }
    DXApplyBottomToolbarVisibility(self);
    if (preferencesBool(kEnabledkey, YES) && toggledOn && !isLandscape && !isDictating) {
        [self updateTypeXTint];
        UIKeyboardImpl *keyboard = [objc_getClass("UIKeyboardImpl") activeInstance];
        UIResponder *active = DXTopToolbarResponder(keyboard);
        DXInstallTopAccessoryForResponder(active, NO);
    }
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    %orig;
    // Defer tint refresh to next runloop: the system updates dock button
    // tintColor AFTER traitCollectionDidChange returns, so a synchronous
    // read here would still get the old (pre-switch) color.
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf updateTypeXTint];
    });
}

%end

%hook UIKeyboardDockItem
//iOS 13+
-(void)setImageName:(NSString *)imageName{
    if (([imageName isEqualToString:@"mic"] && singleTapDictationEnabled) || ([imageName isEqualToString:@"globe"] && singleTapGlobeEnabled)){
        %orig(@"circle");
        return;
    }
    %orig;
}

//iOS 12
-(id)initWithImageName:(id)imageName identifier:(id)identifier{
    if (@available(iOS 13.0, *)){
    }else{
        if ([identifier isEqualToString:@"dictation"] && singleTapDictationEnabled){
            return %orig(@"UIDownloadProgressBorderThick", identifier);
        }else if ([identifier isEqualToString:@"globe"] && singleTapGlobeEnabled){
            return %orig(@"UIDownloadProgressBorderThick", identifier);
        }
    }
    return %orig;
}
%end

%hook UIDictationController
-(void)switchToDictationInputMode{
    %orig;
    isDictating = YES;
}

-(void)switchToDictationInputModeWithTouch:(id)arg1{
    %orig;
    isDictating = YES;
    
}

-(void)stopDictation:(BOOL)arg1{
    %orig;
    if (arg1){
        isDictating = NO;
    }
    
}


%end

//sstatic BOOL forceHidden = NO;


%hook _UIKeyboardTextSelectionInteraction
-(BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer{
    if (preferencesBool(kEnabledkey,YES) && [NSStringFromClass([recognizer.view class]) isEqualToString:@"UIKeyboardDockView"]){
        return NO;
    }
    return %orig;
}
%end

%hook UIKeyboardMenuView
-(void)show{
    //if (preferencesBool(kEnabledkey,YES) && !(preferencesInt(kDedicatedGestureButtonkey, 0) < 1)){
    // return;
    //}
    if (preferencesBool(kEnabledkey,YES)){
        if ((preferencesInt(kDedicatedGestureButtonkey, 0) == 1 || preferencesInt(kDedicatedGestureButtonkey, 0) == 3) && [[self inputView].currentImage.description containsString:@"globe"]){
            return;
        }
        if ((preferencesInt(kDedicatedGestureButtonkey, 0) == 2 || preferencesInt(kDedicatedGestureButtonkey, 0) == 3) && [[self inputView].currentImage.description containsString:@"mic"]){
            return;
        }
    }
    
    %orig;
}


%end


%hook UISystemKeyboardDockController

-(void)updateDockItemsVisibility{
    %orig;
    DXApplyBottomToolbarVisibility(self.dockView);
}


%end

// Clipboard image chip companion: auto-answer the paste-permission alert so
// programmatic paste: and the thumbnail read never interrupt the user. Gated by
// the same switch as the chip (or by the AI panel holding the keyboard, so
// pasting a copied image into the panel input is equally uninterrupted); the
// handler runs before dismissal so the pending pasteboard read unblocks
// immediately.
%hook UIAlertController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (![DXPasteChipController isAllowedInCurrentApp] && ![DXAIPanel isPanelInputActive]) return;
    if (!DXIsPastePermissionAlert(self)) return;

    UIAlertAction *allowAction = nil;
    for (UIAlertAction *action in self.actions) {
        if ([action.title isEqualToString:@"允许粘贴"] ||
            [action.title isEqualToString:@"Allow Paste"]) {
            allowAction = action;
            break;
        }
    }
    if (!allowAction) return;
    id handlerObject = [allowAction valueForKey:@"handler"];
    if (!handlerObject) return;
    void (^allowHandler)(UIAlertAction *) = handlerObject;

    allowHandler(allowAction);
    [self dismissViewControllerAnimated:NO completion:nil];
}

%end

// 桌面可见性信号：app 来源的延迟 AI 请求在桌面真正出现时才创建面板。
// 状态栏手势不再依赖桌面可见性簿记：识别器直接挂在状态栏视图上，
// 由系统自身的实例构造/替换路径维护（DXStatusBarGestureHooks.xm）。
%hook SBHomeScreenViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    // 冷启动兜底：ctor 时域读取可能撞上 cfprefsd 未就绪/首解锁前保护而读空，
    // heal 不会播种，所有 App 的工具栏会一直等到本进程下次 heal。桌面首次出现
    // 是早于任何 App 可用的必然事件；prefs 可用时 reload 依旧早退、零成本。
    if (![DXPrefsManager sharedInstance].preferencesAvailable) reloadPrefs();
    g_aiDesktopVisible = YES;
    DXPresentAIPanelWhenDesktop();
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    g_aiDesktopVisible = NO;
}

%end

%end


// 诊断用：把 shortcuts 存储值压缩成 "arr[启用数/禁用数]" 形态的字符串，异常类型
// 直接点名（工具栏全环境消失时先看这里是不是 BAD/空）。
static NSString *DXDiagShortcutShape(id value) {
    if (!value) return @"nil";
    if (![value isKindOfClass:[NSArray class]]) {
        return [NSString stringWithFormat:@"BAD:%@", NSStringFromClass([value class])];
    }
    NSArray *array = (NSArray *)value;
    NSMutableString *shape = [NSMutableString stringWithFormat:@"arr[%lu]", (unsigned long)array.count];
    for (id section in array) {
        NSUInteger count = [section isKindOfClass:[NSArray class]] ? [(NSArray *)section count] : (NSUInteger)-1;
        [shape appendFormat:@"/%lu", (unsigned long)count];
    }
    return shape;
}

static void reloadPrefs(void) {
    [[DXKeyboardPanel sharedInstance] dismiss];
    DXPrefsManager *manager = [DXPrefsManager sharedInstance];
    [manager reload];
    prefs = manager.preferencesAvailable ? [manager.prefs mutableCopy] : nil;
    
    if (firstInit){
        firstInit = NO;
    }
    currentBackgroundTintColor = nil;

    // Shortcuts tint: if enabled, use custom color; otherwise follow system (set in setLeftDockItem/updateTypeXTint)
    if (preferencesBool(kShortcutsTintEnabled,NO)) {
        currentTintColor = DXColorFromHex(prefs[@"shortcutstint"], @"#ff0000");
    }

    // Background tint options share the legacy colorBOOL master switch.
    if (preferencesBool(kColorEnabledkey,NO)){
        if (preferencesBool(kShortcutsBackgroundTintEnabled,YES)) currentBackgroundTintColor = DXColorFromHex(prefs[@"shortcutsbackgroundtint"], @"#5B5B5B");
    }
    
    toggledOn = preferencesBool(kToggledOnkey,YES);
    singleTapGlobeEnabled = ((preferencesInt(kDedicatedGestureButtonkey,0) == 1 || preferencesInt(kDedicatedGestureButtonkey,0) == 3) && (preferencesInt(kGestureTypekey,0) == 0)) ? YES : NO;
    singleTapDictationEnabled = ((preferencesInt(kDedicatedGestureButtonkey,0) == 2 || preferencesInt(kDedicatedGestureButtonkey,0) == 3) && (preferencesInt(kGestureTypekey,0) == 0)) ? YES : NO;


    heightOffset = preferencesFloat(kHeightOffsetkey, heightOffsetDefault);

    // Button chrome (height/radius/spacing/border/width scale) is scoped per
    // toolbar and recomputed inside DXCollectionView's reloadShortcutConfiguration.

    spongebobEntropy = (DXStudlyCapsType)preferencesInt(kSpongebobEntropyKey, DXStudlyCapsTypeRandom);

    // Settings changes arrive while the keyboard dock is still alive.  Refresh
    // its data source and visibility explicitly; iOS 17 no longer recreates the
    // dock view for every preferences update.
    if (dockView.typex) {
        [dockView.typex reloadShortcutConfiguration];
        [dockView.appShelf refresh];
        DXApplyBottomToolbarVisibility(dockView);
        [dockView.typex.collectionViewLayout invalidateLayout];
        [dockView.typex reloadData];
    }
    DXRefreshActiveTopToolbar();
    NSLog(@"[TypeX] diag: prefs avail=%d count=%lu enabled=%d toggledOn=%d bottom=%@ top=%@",
          manager.preferencesAvailable, (unsigned long)prefs.count,
          preferencesBool(kEnabledkey, YES), toggledOn,
          DXDiagShortcutShape(prefs[DXScopedPreferenceKey(kShortcutskey, @"bottom")]),
          DXDiagShortcutShape(prefs[DXScopedPreferenceKey(kShortcutskey, @"top")]));
    /*
     if (dockView){
     [UIView performWithoutAnimation:^{
     [dockView.typex performBatchUpdates:^{
     [dockView.typex reloadData];
     [dockView.typex.collectionViewLayout invalidateLayout];
     } completion:^(BOOL finished) {}];
     
     }];
     }
     */
    /*
     if (dockV){
     dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
     [[DXPrefsManager sharedInstance] setValue:[NSKeyedArchiver archivedDataWithRootObject:dockV.typex] forKey:@"prevState" fromSandbox:!isSpringBoard];
     });
     }
     */
    
    
}

static void reloadPrefsNotificationCallback(CFNotificationCenterRef center,
                                             void *observer,
                                             CFStringRef name,
                                             const void *object,
                                             CFDictionaryRef userInfo) {
    // Darwin notifications may arrive while Settings is still unwinding the
    // preference write.  Always refresh on the process main queue so UIKit state
    // and the TypeX view are updated serially and never from the posting thread.
    dispatch_async(dispatch_get_main_queue(), ^{
        reloadPrefs();
    });
}

static void shortcutRefreshRequestCallback(CFNotificationCenterRef center,
                                           void *observer,
                                           CFStringRef name,
                                           const void *object,
                                           CFDictionaryRef userInfo) {
    NSDictionary *request = DXQuickActionSharedValue(TypeXQuickActionRequestKey);
    NSArray *rawBundles = [request[@"bundles"] isKindOfClass:[NSArray class]] ? request[@"bundles"] : nil;
    NSString *requestID = [request[@"requestID"] isKindOfClass:[NSString class]] ? request[@"requestID"] : nil;
    if (rawBundles.count > 2048) rawBundles = nil;
    if (requestID.length == 0) return;

    static NSString *lastRequestID;
    @synchronized([DXQuickActionProvider class]) {
        if ([lastRequestID isEqualToString:requestID]) return;
        lastRequestID = [requestID copy];
    }

    NSMutableOrderedSet<NSString *> *bundleIdentifiers = [NSMutableOrderedSet orderedSet];
    for (id value in rawBundles) {
        if (DXIsValidBundleIdentifier(value)) [bundleIdentifiers addObject:value];
    }
    // Settings normally supplies the two-pass LaunchServices enumeration.
    // The provider falls back to SpringBoard's application registry when the
    // list is empty, so one authoritative static/dynamic pipeline covers both.
    [DXQuickActionProvider refreshSnapshotForBundleIdentifiers:bundleIdentifiers.array
                                                     requestID:requestID];
}

%ctor {
    
    @autoreleasepool {
        
        NSArray *args = [[NSClassFromString(@"NSProcessInfo") processInfo] arguments];
        
        if (args.count != 0){
            NSString *executablePath = args[0];
            if (executablePath){
                NSString *processName = [executablePath lastPathComponent];
                isSpringBoard = [processName isEqualToString:@"SpringBoard"];
                isApplication = [executablePath rangeOfString:@"/Application"].location != NSNotFound;
				isApplication = isApplication ?: ([executablePath rangeOfString:@".appex/"].location != NSNotFound ?: isApplication);
				// RootHide/iOS updates can place an app executable outside the
				// traditional /var/containers/Bundle/Application path.  Use the
				// actual main bundle suffix as a second source of truth so app
				// responders still receive the input accessory in those hosts.
				if (!isSpringBoard && !isApplication) {
					NSString *bundleExtension = NSBundle.mainBundle.bundleURL.pathExtension.lowercaseString;
					isApplication = [bundleExtension isEqualToString:@"app"] ||
					                [bundleExtension isEqualToString:@"appex"];
				}
                //isApplication = [processName isEqualToString:@"MarkupPhotoExtension"] ?: isApplication;
                isSafari = [processName isEqualToString:@"MobileSafari"];
                NSLog(@"[TypeX] diag: ctor proc=%@ sb=%d app=%d", executablePath, isSpringBoard, isApplication);
				
                if (isSpringBoard || isApplication){
                    tweakBundle = [NSBundle bundleWithPath:bundlePath];
                    [tweakBundle load];
                    firstInit = YES;
                    reloadPrefs();
                    %init(TypeX);
                    NSLog(@"[TypeX] diag: hooks installed");
                    topToolbarLifecycleObserver = [[DXTopToolbarLifecycleObserver alloc] init];
                    [[NSNotificationCenter defaultCenter] addObserver:topToolbarLifecycleObserver
                                                             selector:@selector(keyboardDidShow:)
                                                                 name:UIKeyboardDidShowNotification
                                                               object:nil];
                    [[NSNotificationCenter defaultCenter] addObserver:topToolbarLifecycleObserver
                                                             selector:@selector(keyboardWillHide:)
                                                                 name:UIKeyboardWillHideNotification
                                                               object:nil];
                    [[NSNotificationCenter defaultCenter] addObserver:[DXPasteChipController sharedController]
                                                             selector:@selector(keyboardDidShow:)
                                                                 name:UIKeyboardDidShowNotification
                                                               object:nil];
                    [[NSNotificationCenter defaultCenter] addObserver:[DXPasteChipController sharedController]
                                                             selector:@selector(keyboardFrameWillChange:)
                                                                 name:UIKeyboardWillChangeFrameNotification
                                                               object:nil];
                    [[NSNotificationCenter defaultCenter] addObserver:[DXPasteChipController sharedController]
                                                             selector:@selector(keyboardWillHide:)
                                                                 name:UIKeyboardWillHideNotification
                                                               object:nil];
                    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, reloadPrefsNotificationCallback, (CFStringRef)kPrefsChangedIdentifier, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
                    DXStartStatusBarGestures();
                    if (!isSpringBoard) DXStartFloatingAppInputClient();
                    if (isSpringBoard) {
                        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, shortcutRefreshRequestCallback, (CFStringRef)kShortcutRefreshRequestIdentifier, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
                        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, aiChatRequestCallback, (CFStringRef)kAIChatRequestIdentifier, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
                        DXStartSystemOpenBroker();
                        DXStartGlobalPanel();
                        DXStartFloatingAppHost();
                    }
                }
            }
        }
    }
}
