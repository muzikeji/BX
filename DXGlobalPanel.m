#import "DXGlobalPanel.h"
#import "DXGlobalPanelPolicy.h"
#import "DXGlobalActionExecutor.h"
#import "DXGlobalPanelGeometry.h"
#import "DXKeyboardPanelPreferences.h"
#import "DXPanelRegistry.h"
#import "DXKeyboardPanelLayout.h"
#import "DXPanelPagedGridView.h"
#import "DXPanelSystemControlsView.h"
#import "DXPanelControlSession.h"
#import "DXSystemOpenBroker.h"
#import "DXShortcutsGenerator.h"
#import "DXKeyboardPanel.h"
#import "DXHelper.h"
#import "common.h"
#import <notify.h>
#import <objc/message.h>

@interface DXGlobalPanelWindow : UIWindow
@end
@implementation DXGlobalPanelWindow
- (BOOL)canBecomeKeyWindow { return NO; }
@end

@interface DXGlobalPanelItem : UIButton
@property(nonatomic, copy) NSString *actionSelector;
@property(nonatomic, strong) UIView *circle;
@property(nonatomic, strong) UIImageView *icon;
@property(nonatomic, strong) UILabel *name;
@end
@implementation DXGlobalPanelItem
- (void)setHighlighted:(BOOL)highlighted { [super setHighlighted:highlighted]; self.alpha = highlighted ? 0.5 : 1; }
@end

@interface DXGlobalPanel ()
@property(nonatomic, strong) DXGlobalPanelWindow *window;
@property(nonatomic, strong) UIView *panel;
@property(nonatomic, strong) UIScrollView *scroll;
@property(nonatomic, strong) DXPanelPagedGridView *grid;
@property(nonatomic, strong) UILabel *title;
@property(nonatomic, strong) UILabel *message;
@property(nonatomic, strong) UIButton *closeButton;
@property(nonatomic, strong) UIControl *header;
@property(nonatomic, strong) UIControl *blank;
@property(nonatomic, strong) DXPanelSystemControlsView *controls;
@property(nonatomic, strong) DXPanelControlSession *controlSession;
@property(nonatomic, strong) NSArray<DXGlobalPanelItem *> *items;
@property(nonatomic, strong) NSDictionary *snapshot;
@property(nonatomic, assign) CGFloat scale;
@property(nonatomic, assign) NSInteger columns;
@property(nonatomic, assign) BOOL topAnchored;
@property(nonatomic, assign) BOOL dockPresentation;
@property(nonatomic, assign) NSTimeInterval lastOpen;
- (void)layout;
- (void)showMessage:(NSString *)message;
- (void)systemStateChanged:(NSString *)name;
- (void)dismissForReason:(NSString *)reason;
@end

@interface DXGlobalPanelController : UIViewController
@property(nonatomic, weak) DXGlobalPanel *owner;
@end
@implementation DXGlobalPanelController
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // An old controller's trailing layout must not touch a newer panel.
    if (self.owner.window.rootViewController == self) [self.owner layout];
}
@end

static NSString *DXGlobalLocalized(NSString *key) {
    return [[NSBundle bundleWithPath:bundlePath] localizedStringForKey:key value:key table:nil];
}

// The same frontmost-app query is used by the local PullOver-X project.
// nil means Home Screen; an unavailable/changed ABI is reported separately.
static BOOL DXGlobalPanelHasForegroundApplication(BOOL *known) {
    *known = NO;
    id application = UIApplication.sharedApplication;
    SEL selector = NSSelectorFromString(@"_accessibilityFrontMostApplication");
    if (![application respondsToSelector:selector]) return NO;
    NSMethodSignature *signature = [application methodSignatureForSelector:selector];
    if (signature.numberOfArguments != 2 || strcmp(signature.methodReturnType, "@")) return NO;
    @try {
        id frontmost = ((id (*)(id, SEL))objc_msgSend)(application, selector);
        *known = YES;
        return frontmost != nil;
    } @catch (__unused NSException *exception) { return NO; }
}

@implementation DXGlobalPanel
+ (instancetype)sharedInstance {
    static DXGlobalPanel *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [self new]; });
    return instance;
}
+ (BOOL)deviceUnlocked {
    if (!NSThread.isMainThread) return NO;
    Class cls = NSClassFromString(@"SBLockScreenManager");
    SEL shared = NSSelectorFromString(@"sharedInstance"), locked = NSSelectorFromString(@"isUILocked");
    if (![cls respondsToSelector:shared]) return NO;
    @try {
        NSMethodSignature *factory = [cls methodSignatureForSelector:shared];
        if (factory.numberOfArguments != 2 || strcmp(factory.methodReturnType, "@")) return NO;
        id manager = ((id (*)(id, SEL))objc_msgSend)(cls, shared);
        NSMethodSignature *signature = [manager methodSignatureForSelector:locked];
        if (![manager respondsToSelector:locked] || signature.numberOfArguments != 2 ||
            (strcmp(signature.methodReturnType, @encode(BOOL)) && strcmp(signature.methodReturnType, "c"))) return NO;
        return !((BOOL (*)(id, SEL))objc_msgSend)(manager, locked);
    } @catch (__unused NSException *exception) { return NO; }
}
- (instancetype)init {
    if ((self = [super init])) {
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        for (NSString *name in @[UIApplicationWillResignActiveNotification, UISceneWillDeactivateNotification,
            UIDeviceOrientationDidChangeNotification, @"mubXLayoutChanged"])
            [center addObserver:self selector:@selector(interrupted:) name:name object:nil];
    }
    return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; [_controlSession invalidate]; }
- (BOOL)isVisible { return self.window && !self.window.hidden; }
- (BOOL)validSession {
    if (!NSThread.isMainThread || ![self isVisible] || ![DXGlobalPanel deviceUnlocked]) return NO;
    UIWindowScene *scene = self.window.windowScene;
    DXPrefsManager *manager = DXPrefsManager.sharedInstance;
    return (!scene || scene.activationState == UISceneActivationStateForegroundActive) &&
        manager.preferencesAvailable && DXKeyboardPanelBool(manager.prefs, kEnabledkey, YES) &&
        DXKeyboardPanelBool(manager.prefs, kDXPanelGlobalEnabled, YES) && [manager.prefs isEqual:self.snapshot];
}
- (void)interrupted:(NSNotification *)notification {
    if (!NSThread.isMainThread) {
        __weak DXGlobalPanelWindow *window = self.window;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (window && self.window == window) [self interrupted:notification];
        });
        return;
    }
    if (![self isVisible]) return;
    NSString *name = notification.name;
    if ([name isEqual:UISceneWillDeactivateNotification] && notification.object != self.window.windowScene) return;
    // Physical orientation/tint updates do not mean the current scene has
    // gone away. Relayout in place; a changed preference snapshot still closes.
    if ([name isEqual:UIDeviceOrientationDidChangeNotification] ||
        ([name isEqual:@"mubXLayoutChanged"] && [self.snapshot isEqual:DXPrefsManager.sharedInstance.prefs])) {
        [self layout];
        return;
    }
    if (self.dockPresentation &&
        ([name isEqual:UIApplicationWillResignActiveNotification] ||
         [name isEqual:UISceneWillDeactivateNotification] || [name isEqual:@"switcher-transition"])) {
        NSLog(@"[MUBX][GlobalPanel] keep origin=dockgesture reason=%@", name);
        return;
    }
    [self dismissForReason:name ?: @"interruption"];
}
- (void)systemStateChanged:(NSString *)name {
    if (!NSThread.isMainThread || ![self isVisible]) return;
    if ([name isEqual:@"com.apple.springboard.lockstate"] && [DXGlobalPanel deviceUnlocked]) return;
    if ([name isEqual:@"com.apple.springboard.frontmostapplicationchanged"]) {
        // Dock presentations are explicitly dismissed by the user, not by
        // delayed/ambiguous Home or app-transition signals. No private query
        // result (including unavailable/throwing APIs) may revoke this policy.
        if (self.dockPresentation) {
            NSLog(@"[MUBX][GlobalPanel] keep origin=dockgesture reason=%@", name);
            return;
        }
        BOOL known = NO;
        BOOL foreground = DXGlobalPanelHasForegroundApplication(&known);
        // A delayed return-to-Home notification must not dismiss a panel just
        // opened there. Actual app activation and unknown state still close.
        if (known && !foreground) return;
    }
    [self dismissForReason:name];
}
- (void)systemTransitionBegan {
    [self interrupted:[NSNotification notificationWithName:@"switcher-transition" object:nil]];
}
- (void)preparePresentationForOrigin:(NSString *)origin {
    // A panel-to-panel action inherits the initiating gesture's policy.
    BOOL dock = [origin isEqual:@"dockgesture"] ||
        ([origin isEqual:@"panel-action"] && self.dockPresentation);
    if (![origin isEqual:@"panel-action"]) self.topAnchored = [origin isEqual:@"statusbar"];
    [self dismiss];
    self.dockPresentation = dock;
}
- (NSDictionary *)definition:(NSString *)selector {
    NSDictionary *panel = DXPanelDisplayDefinition(DXPrefsManager.sharedInstance.prefs, selector);
    if (panel && [panel[@"kind"] isEqual:DXPanelGestureKind]) return panel;
    id definitions = DXPrefsManager.sharedInstance.prefs[kLinkActionskey];
    if (![definitions isKindOfClass:NSArray.class]) return nil;
    for (id entry in definitions)
        if ([entry isKindOfClass:NSDictionary.class] && [entry[@"selector"] isEqual:selector]) return entry;
    return nil;
}
- (void)presentPanelSelector:(NSString *)selector fromWindow:(UIWindow *)sourceWindow origin:(NSString *)origin {
    if (!NSThread.isMainThread || ![NSProcessInfo.processInfo.processName isEqual:@"SpringBoard"]) return;
    DXPrefsManager *manager = DXPrefsManager.sharedInstance;
    [manager reload];
    if (!DXPanelAllowed(manager.prefs, selector, DXPanelGestureKind)) return;
    NSDictionary *panelDefinition = DXPanelDefinition(manager.prefs, selector);
    if (!manager.preferencesAvailable || !DXKeyboardPanelBool(manager.prefs, kEnabledkey, YES) ||
        !DXKeyboardPanelBool(manager.prefs, kDXPanelGlobalEnabled, YES) || ![DXGlobalPanel deviceUnlocked]) {
        NSLog(@"[MUBX][GlobalPanel] open cancelled: preferences/lock gate"); return;
    }
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (now - self.lastOpen < 0.35 && ![origin isEqual:@"panel-action"]) return;
    self.lastOpen = now;
    // Status-bar gestures pull the panel toward the touch at the top edge;
    // in-panel switches keep the current anchor, dock stays bottom.
    [self preparePresentationForOrigin:origin];
    [[DXKeyboardPanel sharedInstance] dismiss];
    NSDictionary *preferences = manager.prefs;
    self.snapshot = [preferences copy];
    NSString *profile = selector;
    NSArray *entries = DXPanelItems(preferences, selector);
    preferences = DXPanelPreferences(preferences, selector);
    self.scale = DXKeyboardPanelNumber(preferences, kDXPanelScale, 100, 70, 120) / 100;
    self.columns = (NSInteger)DXKeyboardPanelNumber(preferences, kDXPanelColumns, 4, 3, 5);
    BOOL dark = DXKeyboardPanelBool(preferences, kDXPanelDark, YES);
    UIColor *text = dark ? UIColor.whiteColor : UIColor.labelColor;

    // SpringBoard has scene-less windows on some supported systems. A fresh
    // owned window is used per presentation and never made key.
    UIWindowScene *scene = sourceWindow.windowScene;
    if (scene && scene.activationState != UISceneActivationStateForegroundActive) { [self dismiss]; return; }
    if (!scene) {
        for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes)
            if ([candidate isKindOfClass:UIWindowScene.class] && candidate.activationState == UISceneActivationStateForegroundActive) {
                scene = (UIWindowScene *)candidate; break;
            }
    }
    self.window = scene ? [[DXGlobalPanelWindow alloc] initWithWindowScene:scene] :
        [[DXGlobalPanelWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.frame = scene ? scene.coordinateSpace.bounds : UIScreen.mainScreen.bounds;
    self.window.backgroundColor = UIColor.clearColor;
    // Use a stable content level rather than overtaking SpringBoard's system
    // overlays, which can place the panel above the screenshot capture range.
    self.window.windowLevel = UIWindowLevelAlert + 1;
    DXGlobalPanelController *controller = [DXGlobalPanelController new];
    controller.owner = self;
    self.window.rootViewController = controller;
    controller.view.frame = self.window.bounds;
    controller.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UIControl *outside = [[UIControl alloc] initWithFrame:controller.view.bounds];
    outside.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    outside.backgroundColor = [UIColor colorWithWhite:0 alpha:0.15];
    [outside addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];
    [controller.view addSubview:outside];
    self.panel = [UIView new];
    self.panel.backgroundColor = dark ? [UIColor colorWithWhite:0.10 alpha:1] : UIColor.systemBackgroundColor;
    self.panel.layer.cornerRadius = 22;
    self.panel.clipsToBounds = YES;
    [controller.view addSubview:self.panel];
    self.header = [UIControl new];
    [self.header addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];
    UISwipeGestureRecognizer *closeSwipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(dismiss)];
    closeSwipe.direction = UISwipeGestureRecognizerDirectionDown;
    [self.header addGestureRecognizer:closeSwipe];
    [self.panel addSubview:self.header];
    self.title = [UILabel new];
    self.title.text = DXPanelString(panelDefinition[@"name"]);
    self.title.textColor = text;
    self.title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [self.panel addSubview:self.title];
    self.closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.closeButton setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    self.closeButton.tintColor = text;
    self.closeButton.accessibilityLabel = DXGlobalLocalized(@"KEYBOARD_PANEL_CLOSE");
    [self.closeButton addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:self.closeButton];
    self.message = [UILabel new];
    self.message.textColor = text;
    self.message.font = [UIFont systemFontOfSize:13];
    self.message.numberOfLines = 2;
    self.message.textAlignment = NSTextAlignmentCenter;
    self.message.hidden = YES;
    [self.panel addSubview:self.message];
    self.scroll = [UIScrollView new];
    self.scroll.showsVerticalScrollIndicator = NO;
    self.scroll.directionalLockEnabled = YES;
    [self.panel addSubview:self.scroll];
    self.blank = [UIControl new];
    [self.blank addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];
    [self.scroll addSubview:self.blank];
    self.controls = [DXPanelSystemControlsView new];
    [self.controls configureWithPreferences:preferences preview:NO];
    [self.scroll addSubview:self.controls];
    __weak typeof(self) weakSelf = self;
    __weak DXPanelSystemControlsView *controls = self.controls;
    if (self.controls.showsToggleRow || self.controls.showsSliderRow) {
        self.controlSession = [[DXPanelControlSession alloc] initWithRequester:^NSProgress *(NSString *action, NSNumber *value, DXPanelSystemControlReply reply) {
            return DXRequestPanelSystemControl(action, value, @"global", reply);
        } validity:^BOOL {
            DXGlobalPanel *owner = weakSelf;
            return owner && owner.controls == controls && [owner validSession];
        } update:^(DXSystemOpenResult result, NSDictionary *state, BOOL busy, NSString *action) {
            (void)action;
            [controls applyState:state busy:busy];
            [controls showMessage:result == DXSystemOpenSucceeded ? nil : DXGlobalLocalized(@"SYSTEM_ACTION_UNAVAILABLE")];
        }];
        self.controls.actionHandler = ^(NSString *action, NSNumber *value) {
            DXGlobalPanel *owner = weakSelf;
            if (owner.controls != controls || ![owner validSession]) { [owner dismiss]; return; }
            [owner.controlSession enqueueAction:action value:value];
        };
    }
    self.grid = [DXPanelPagedGridView new];
    self.grid.diagnosticName = @"gesture";
    __weak DXPanelPagedGridView *grid = self.grid;
    self.grid.blankAction = ^{
        DXGlobalPanel *owner = weakSelf;
        if (owner.grid == grid) [owner dismiss];
    };
    [self.scroll addSubview:self.grid];
    NSMutableArray *buttons = [NSMutableArray array];
    for (NSDictionary *entry in entries) {
        NSDictionary *definition = [self definition:entry[@"selector"]];
        if (!definition) continue;
        DXGlobalPanelItem *button = [DXGlobalPanelItem buttonWithType:UIButtonTypeCustom];
        button.actionSelector = entry[@"selector"];
        button.circle = [UIView new];
        button.circle.backgroundColor = dark ? [UIColor colorWithWhite:0 alpha:0.45] : [UIColor colorWithWhite:1 alpha:0.65];
        button.circle.userInteractionEnabled = NO;
        [button addSubview:button.circle];
        button.icon = [UIImageView new];
        button.icon.userInteractionEnabled = NO;
        button.icon.contentMode = UIViewContentModeScaleAspectFit;
        button.icon.tintColor = text;
        NSString *icon = DXGlobalPanelString(definition[@"icon"]);
        button.icon.image = [DXHelper imageForIconConfig:icon defaultSymbolName:@"square.grid.2x2"];
        [button addSubview:button.icon];
        button.name = [UILabel new];
        button.name.text = [entry[@"name"] length] ? entry[@"name"] : DXGlobalPanelString(definition[@"name"]);
        button.name.textColor = text;
        button.name.font = [UIFont systemFontOfSize:12 * self.scale];
        button.name.numberOfLines = 2;
        button.name.textAlignment = NSTextAlignmentCenter;
        button.name.adjustsFontSizeToFitWidth = YES;
        button.name.minimumScaleFactor = 0.8;
        [button addSubview:button.name];
        button.accessibilityLabel = button.name.text;
        [button addTarget:self action:@selector(itemTapped:) forControlEvents:UIControlEventTouchUpInside];
        [buttons addObject:button];
    }
    self.items = buttons;
    [self.grid configureWithItems:buttons columns:self.columns scale:self.scale];
    self.window.hidden = NO;
    [self.window layoutIfNeeded];
    [self layout];
    [self.controlSession enqueueAction:@"state" value:nil];
    NSLog(@"[MUBX][GlobalPanel] open side=%@ origin=%@ items=%lu scene=%d level=%.0f",
        profile, origin, (unsigned long)buttons.count, scene != nil, (double)self.window.windowLevel);
}
- (void)layout {
    if (!self.window || !self.panel) return;
    UIView *root = self.window.rootViewController.view;
    CGRect bounds = DXGlobalPanelLayoutBounds(root.bounds, self.window.bounds);
    CGFloat width = MIN(500, MAX(0, bounds.size.width - 20));
    CGFloat contentWidth = MAX(0, width - 16);
    CGFloat messageHeight = self.message.text.length ? 44 : 0;
    CGFloat controlsHeight = [self.controls preferredHeightForWidth:contentWidth];
    CGFloat gridHeight = [self.grid preferredHeightForWidth:contentWidth];
    // Header plus the scroll's 8pt bottom inset wrap the scrollable content.
    CGFloat contentHeight = 46 + messageHeight + controlsHeight + gridHeight + 8;
    CGRect frame = DXGlobalPanelFrame(bounds, MAX(self.window.safeAreaInsets.top, root.safeAreaInsets.top),
        MAX(self.window.safeAreaInsets.bottom, root.safeAreaInsets.bottom), contentHeight, self.topAnchored);
    // Initial/transitional geometry can be empty. Let UIKit's next layout
    // finish this same presentation instead of destroying its window.
    if (CGRectIsNull(frame)) return;
    self.panel.frame = frame;
    CGFloat height = frame.size.height;
    self.header.frame = CGRectMake(0, 0, width, 46);
    self.title.frame = CGRectMake(16, 10, MAX(0, width - 68), 28);
    self.closeButton.frame = CGRectMake(width - 48, 2, 44, 44);
    self.message.frame = CGRectMake(10, 46, width - 20, messageHeight);
    self.scroll.frame = CGRectMake(8, 46 + messageHeight, contentWidth, MAX(0, height - 54 - messageHeight));
    self.controls.frame = CGRectMake(0, 0, contentWidth, controlsHeight);
    self.grid.frame = CGRectMake(0, controlsHeight, contentWidth, gridHeight);
    [self.grid layoutIfNeeded];
    CGFloat circle = DXKeyboardPanelCircle(contentWidth, self.columns, self.scale);
    for (NSUInteger index = 0; index < self.items.count; index++) {
        DXGlobalPanelItem *button = self.items[index];
        CGFloat slot = button.bounds.size.width;
        button.circle.frame = CGRectMake((slot - circle) / 2, 4, circle, circle);
        button.circle.layer.cornerRadius = circle / 2;
        CGFloat icon = circle * 0.52;
        button.icon.frame = CGRectMake((slot - icon) / 2, 4 + (circle - icon) / 2, icon, icon);
        CGSize labelSize = [button.name sizeThatFits:CGSizeMake(MAX(0, slot - 6), 30 * self.scale)];
        button.name.frame = DXGlobalPanelLabelFrame(slot, circle, self.scale, labelSize.height);
    }
    CGFloat total = MAX(self.scroll.bounds.size.height, controlsHeight + gridHeight);
    self.scroll.contentSize = CGSizeMake(contentWidth, total);
    self.blank.frame = CGRectMake(0, 0, contentWidth, total);
}
- (void)itemTapped:(DXGlobalPanelItem *)button {
    if (![self validSession] || ![self.items containsObject:button]) { [self dismiss]; return; }
    NSDictionary *entry = [self definition:button.actionSelector];
    if (!entry) { [self dismiss]; return; }
    if (DXIsPanelSelector(button.actionSelector)) {
        NSString *selector = [button.actionSelector copy];
        UIWindow *window = self.window;
        [self presentPanelSelector:selector fromWindow:window origin:@"panel-action"];
        return;
    }
    if (DXGlobalPanelActionNeedsInput(entry)) {
        NSLog(@"[MUBX][GesturePanel] action rejected: input-required");
        [self showMessage:DXGlobalLocalized(@"GLOBAL_PANEL_INPUT_REQUIRED")]; return;
    }
    if (!DXGlobalCustomActionSupported(entry)) {
        [self showMessage:DXGlobalLocalized(@"CUSTOM_ACTION_LINK_ERROR")]; return;
    }
    // Close synchronously before any navigation or confirmation. No delayed
    // callback can insert text or reopen a dismissed/newer panel.
    [self dismiss];
    DXSystemOpenReply reply = ^(DXSystemOpenResult result) {
        NSLog(@"[MUBX][GlobalPanel] action result=%llu", (unsigned long long)result);
    };
    DXExecuteGlobalCustomAction(entry, reply);
}
- (void)showMessage:(NSString *)message {
    self.message.text = message;
    self.message.hidden = !message.length;
    [self layout];
}
- (void)dismiss {
    [self dismissForReason:@"explicit"];
}
- (void)dismissForReason:(NSString *)reason {
    if (!NSThread.isMainThread) {
        __weak DXGlobalPanelWindow *window = self.window;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (window && self.window == window) [self dismissForReason:reason];
        });
        return;
    }
    if ([self isVisible]) NSLog(@"[MUBX][GlobalPanel] close reason=%@ age=%.3f", reason, NSProcessInfo.processInfo.systemUptime - self.lastOpen);
    [self.controlSession invalidate]; self.controlSession = nil;
    self.controls.actionHandler = nil; self.controls = nil;
    self.window.hidden = YES;
    self.window.rootViewController = nil; self.window = nil;
    self.grid.blankAction = nil; self.grid = nil;
    self.panel = nil; self.scroll = nil; self.items = nil; self.snapshot = nil;
    self.dockPresentation = NO;
    self.title = nil; self.message = nil; self.closeButton = nil; self.header = nil; self.blank = nil;
}
@end

void DXStartGlobalPanel(void) {
    if (![NSProcessInfo.processInfo.processName isEqual:@"SpringBoard"]) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (NSString *name in @[@"com.apple.springboard.lockstate", @"com.apple.springboard.frontmostapplicationchanged"]) {
            int token = NOTIFY_TOKEN_INVALID;
            notify_register_dispatch(name.UTF8String, &token, dispatch_get_main_queue(), ^(int deliveredToken) {
                (void)deliveredToken;
                [[DXGlobalPanel sharedInstance] systemStateChanged:name];
            });
        }
    });
}
