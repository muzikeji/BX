#import "DXKeyboardPanel.h"
#import "DXKeyboardPanelPreferences.h"
#import "DXPanelRegistry.h"
#import "DXKeyboardPanelGeometry.h"
#import "DXKeyboardPanelLayout.h"
#import "DXPanelPagedGridView.h"
#import "DXPanelSystemControlsView.h"
#import "DXPanelControlSession.h"
#import "DXKeyboardPanelHostPolicy.h"
#import "DXCollectionView.h"
#import "DXHelper.h"
#import "DXShared.h"
#import "common.h"
#import <objc/message.h>
#import <objc/runtime.h>

@interface DXKeyboardPanelOverlay : UIView
@property(nonatomic, assign) CGRect panelRect;
@end
@implementation DXKeyboardPanelOverlay
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!CGRectContainsPoint(self.panelRect, point)) return nil;
    return [super hitTest:point withEvent:event];
}
@end

@interface DXKeyboardPanelButton : UIButton
@property(nonatomic, copy) NSString *actionSelector;
@property(nonatomic, strong) UIImageView *actionImage;
@property(nonatomic, strong) UILabel *actionLabel;
@end
@implementation DXKeyboardPanelButton
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.5 : 1;
}
@end

@interface DXKeyboardPanel ()
@property(nonatomic, strong) NSHashTable<DXCollectionView *> *toolbars;
@property(nonatomic, weak) UIWindow *window;
@property(nonatomic, weak) UIWindowScene *sessionScene;
@property(nonatomic, strong) DXKeyboardPanelOverlay *overlay;
@property(nonatomic, strong) UIView *panel;
@property(nonatomic, strong) UIScrollView *scroll;
@property(nonatomic, strong) DXPanelPagedGridView *grid;
@property(nonatomic, strong) DXPanelSystemControlsView *systemControls;
@property(nonatomic, strong) DXPanelControlSession *controlSession;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UIButton *closeButton;
@property(nonatomic, strong) NSArray<DXKeyboardPanelButton *> *buttons;
@property(nonatomic, weak) DXCollectionView *source;
@property(nonatomic, weak) UIWindow *sourceWindow;
@property(nonatomic, weak) UIResponder *input;
@property(nonatomic, weak) UIScreen *keyboardScreen;
@property(nonatomic, assign) CGRect keyboardFrame;
@property(nonatomic, assign) BOOL hasKeyboardFrame;
@property(nonatomic, assign) BOOL dark;
@property(nonatomic, assign) CGFloat scale;
@property(nonatomic, assign) NSInteger columns;
@property(nonatomic, copy) NSDictionary *snapshot;
@end

@implementation DXKeyboardPanel
+ (instancetype)sharedInstance {
    static DXKeyboardPanel *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}
- (instancetype)init {
    if ((self = [super init])) {
        _toolbars = [NSHashTable weakObjectsHashTable];
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:self selector:@selector(keyboardChanged:) name:UIKeyboardWillChangeFrameNotification object:nil];
        [center addObserver:self selector:@selector(keyboardChanged:) name:UIKeyboardDidShowNotification object:nil];
        [center addObserver:self selector:@selector(keyboardHidden:) name:UIKeyboardWillHideNotification object:nil];
        [center addObserver:self selector:@selector(invalidated:) name:UIApplicationWillResignActiveNotification object:nil];
        [center addObserver:self selector:@selector(invalidated:) name:UISceneWillDeactivateNotification object:nil];
        [center addObserver:self selector:@selector(invalidated:) name:UIDeviceOrientationDidChangeNotification object:nil];
        [center addObserver:self selector:@selector(invalidated:) name:@"mubXLayoutChanged" object:nil];
        [center addObserver:self selector:@selector(invalidated:) name:UITextFieldTextDidBeginEditingNotification object:nil];
        [center addObserver:self selector:@selector(invalidated:) name:UITextFieldTextDidEndEditingNotification object:nil];
        [center addObserver:self selector:@selector(invalidated:) name:UITextViewTextDidBeginEditingNotification object:nil];
        [center addObserver:self selector:@selector(invalidated:) name:UITextViewTextDidEndEditingNotification object:nil];
    }
    return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (UIResponder *)currentInput {
    Class cls = NSClassFromString(@"UIKeyboardImpl");
    UIKeyboardImpl *keyboard = [cls respondsToSelector:@selector(activeInstance)] ? [cls activeInstance] : nil;
    return DXKeyboardInputDelegate(keyboard);
}
- (BOOL)visibleToolbar:(DXCollectionView *)toolbar {
    if (!toolbar || !toolbar.window || toolbar.window.hidden) return NO;
    for (UIView *view = toolbar; view; view = view.superview) {
        if (view.hidden || view.alpha < 0.01) return NO;
    }
    return toolbar.shortcutConfigurationAvailable;
}
- (void)registerToolbar:(DXCollectionView *)toolbar {
    if (![NSThread isMainThread]) return;
    [self.toolbars addObject:toolbar];
    if (self.window && ![self validSession]) [self dismiss];
    else if (self.window) [self layoutPanel];
}
- (void)toolbarDetached:(DXCollectionView *)toolbar {
    if (![NSThread isMainThread]) return;
    [self.toolbars removeObject:toolbar];
    if (self.source == toolbar) [self dismiss];
}
- (BOOL)validSession {
    return [DXPrefsManager.sharedInstance.prefs isEqual:self.snapshot] && [self visibleToolbar:self.source] && self.source.window == self.sourceWindow &&
        self.input && self.input == [self currentInput] &&
        self.window && !self.window.hidden && self.overlay.superview == self.window &&
        self.sessionScene.activationState == UISceneActivationStateForegroundActive;
}
- (void)keyboardChanged:(NSNotification *)note {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self keyboardChanged:note]; });
        return;
    }
    NSValue *value = note.userInfo[UIKeyboardFrameEndUserInfoKey];
    if (![value isKindOfClass:NSValue.class]) return;
    self.keyboardFrame = value.CGRectValue;
    self.keyboardScreen = [note.object isKindOfClass:UIScreen.class] ? note.object : (self.sourceWindow.screen ?: UIScreen.mainScreen);
    self.hasKeyboardFrame = !CGRectIsEmpty(self.keyboardFrame);
    if (self.window && ![self validSession]) [self dismiss];
    else if (self.window) [self layoutPanel];
}
- (void)keyboardHidden:(NSNotification *)note {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self keyboardHidden:note]; });
        return;
    }
    self.hasKeyboardFrame = NO;
    [self dismiss];
}
- (void)invalidated:(NSNotification *)note { (void)note; [self dismiss]; }
- (CGRect)coverageInWindow:(UIWindow *)window {
    CGRect rect = CGRectNull;
    UIScreen *screen = self.sourceWindow.screen;
    if (self.hasKeyboardFrame && (!self.keyboardScreen || self.keyboardScreen == screen)) {
        CGRect keyboard = [window convertRect:self.keyboardFrame fromCoordinateSpace:screen.coordinateSpace];
        rect = DXKeyboardPanelUnionCoverage(rect, keyboard, window.bounds, YES);
    }
    for (DXCollectionView *toolbar in self.toolbars) {
        if (![self visibleToolbar:toolbar] || toolbar.window.screen != screen) continue;
        // Only combine the currently attached keyboard hierarchy, never another scene's toolbar.
        if (toolbar.window != self.sourceWindow && toolbar.window.windowScene != self.sourceWindow.windowScene &&
            toolbar.window.windowScene != window.windowScene) continue;
        CGRect local = [toolbar convertRect:toolbar.bounds toView:toolbar.window];
        CGRect frame = [window convertRect:local fromWindow:toolbar.window];
        rect = DXKeyboardPanelUnionCoverage(rect, frame, window.bounds, NO);
        // Notifications may precede toolbar registration. Measure live keyboard
        // ancestors too, including the candidate row and the dock's bottom inset.
        // Do not use arbitrary app ancestors that could cover the whole screen.
        for (UIView *ancestor = toolbar.superview; ancestor && ancestor != toolbar.window; ancestor = ancestor.superview) {
            NSString *className = NSStringFromClass(ancestor.class);
            if (![className hasPrefix:@"UIInputSet"] && ![className hasPrefix:@"UIKeyboard"]) continue;
            CGRect surface = [ancestor convertRect:ancestor.bounds toView:toolbar.window];
            surface = [window convertRect:surface fromWindow:toolbar.window];
            rect = DXKeyboardPanelUnionCoverage(rect, surface, window.bounds, YES);
        }
    }
    return DXKeyboardPanelFullWidthCoverage(rect, window.bounds);
}
- (UIWindow *)keyboardHostForScene:(UIWindowScene *)scene {
    Class cls = NSClassFromString(@"UIKeyboardImpl");
    UIKeyboardImpl *keyboard = [cls respondsToSelector:@selector(activeInstance)] ? [cls activeInstance] : nil;
    UIWindow *activeWindow = [keyboard isKindOfClass:UIView.class] ? keyboard.window : nil;
    // Locate an already-created remote surface even when it is omitted from
    // UIApplication.windows. Never create a UIKit keyboard window ourselves.
    Class remoteClass = NSClassFromString(@"UIRemoteKeyboardWindow");
    SEL remoteSelector = NSSelectorFromString(@"remoteKeyboardWindowForScreen:create:");
    NSMethodSignature *signature = [remoteClass respondsToSelector:remoteSelector] ? [remoteClass methodSignatureForSelector:remoteSelector] : nil;
    UIWindow *remoteWindow = nil;
    if (signature.numberOfArguments == 4 && !strcmp(signature.methodReturnType, "@") &&
        !strcmp([signature getArgumentTypeAtIndex:2], "@") &&
        (!strcmp([signature getArgumentTypeAtIndex:3], @encode(BOOL)) || !strcmp([signature getArgumentTypeAtIndex:3], "B"))) {
        id found = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(remoteClass, remoteSelector, self.sourceWindow.screen, NO);
        if ([found isKindOfClass:UIWindow.class]) remoteWindow = found;
    }
    NSMutableOrderedSet<UIWindow *> *candidates = [NSMutableOrderedSet orderedSet];
    if (remoteWindow) [candidates addObject:remoteWindow];
    if (activeWindow) [candidates addObject:activeWindow];
    [candidates addObject:self.sourceWindow];
    for (DXCollectionView *toolbar in self.toolbars) {
        if ([self visibleToolbar:toolbar]) [candidates addObject:toolbar.window];
    }
    [candidates addObjectsFromArray:scene.windows ?: @[]];
    [candidates addObjectsFromArray:self.sourceWindow.windowScene.windows ?: @[]];
    // Keyboard windows can belong to a separate UIKit scene. UIApplication's
    // legacy window inventory is still needed to locate that system surface.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [candidates addObjectsFromArray:UIApplication.sharedApplication.windows];
#pragma clang diagnostic pop
    UIWindow *host = nil;
    NSInteger bestRank = 0;
    for (UIWindow *candidate in candidates) {
        if (candidate.hidden || candidate.alpha < 0.01 || candidate.screen != self.sourceWindow.screen) continue;
        UIWindowScene *candidateScene = candidate.windowScene;
        if (candidateScene && candidateScene != scene && candidateScene != self.sourceWindow.windowScene &&
            candidateScene != activeWindow.windowScene && candidate != remoteWindow) continue;
        NSInteger rank = 0;
        for (Class windowClass = candidate.class; windowClass; windowClass = class_getSuperclass(windowClass))
            rank = MAX(rank, DXKeyboardPanelHostRank(NSStringFromClass(windowClass), candidate == activeWindow));
        if (rank > bestRank || (rank && rank == bestRank && candidate.windowLevel > host.windowLevel)) {
            bestRank = rank;
            host = candidate;
        }
    }
    return host;
}
- (void)raiseOverlay {
    if (!self.window || self.overlay.superview != self.window) return;
    CGFloat z = 1;
    for (UIView *sibling in self.window.subviews) {
        if (sibling == self.overlay || !isfinite(sibling.layer.zPosition)) continue;
        z = MAX(z, sibling.layer.zPosition + 1);
    }
    self.overlay.layer.zPosition = z;
    [self.window bringSubviewToFront:self.overlay];
}
- (void)presentFromToolbar:(DXCollectionView *)toolbar panelSelector:(NSString *)selector {
    if (![NSThread isMainThread]) return;
    DXPrefsManager *manager = DXPrefsManager.sharedInstance;
    if (!manager.preferencesAvailable || ![self visibleToolbar:toolbar]) return;
    NSDictionary *preferences = manager.prefs;
    if (!DXPanelAllowed(preferences, selector, DXPanelKeyboardKind)) return;
    NSDictionary *definition = DXPanelDefinition(preferences, selector);
    UIResponder *input = [self currentInput];
    UIWindow *inputWindow = [input isKindOfClass:UIView.class] ? ((UIView *)input).window : nil;
    UIWindowScene *scene = inputWindow.windowScene ?: toolbar.window.windowScene;
    if (!input || !scene || scene.activationState != UISceneActivationStateForegroundActive) {
        NSLog(@"[MUBX][KeyboardPanel] open cancelled: no active source input/scene");
        return;
    }
    [self dismiss];
    [toolbar dismissKeyboardActionChooser];
    self.snapshot = [preferences copy];
    self.source = toolbar;
    self.sourceWindow = toolbar.window;
    self.input = input;
    self.sessionScene = scene;
    [self.toolbars addObject:toolbar];
    NSString *profile = selector;
    NSArray *items = DXPanelItems(preferences, selector);
    preferences = DXPanelPreferences(preferences, selector);
    self.scale = DXKeyboardPanelNumber(preferences, kDXPanelScale, 100, 70, 120) / 100;
    self.columns = (NSInteger)DXKeyboardPanelNumber(preferences, kDXPanelColumns, 4, 3, 5);
    self.dark = DXKeyboardPanelBool(preferences, kDXPanelDark, YES);

    UIWindow *window = [self keyboardHostForScene:scene];
    if (!window) {
        NSLog(@"[MUBX][KeyboardPanel] open cancelled: no keyboard host window");
        [self dismiss];
        return;
    }
    self.window = window;
    self.overlay = [[DXKeyboardPanelOverlay alloc] initWithFrame:window.bounds];
    self.overlay.backgroundColor = UIColor.clearColor;
    self.overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // Join the keyboard's existing render surface, above its content siblings.
    // Do not create/make-key/hide a UIKit keyboard window or alter its root VC.
    [window addSubview:self.overlay];
    UIView *panel = [[UIView alloc] init];
    // A remote keyboard backdrop may not be sampled by UIVisualEffectView.
    // Keep an opaque base so its keys cannot bleed through on SpringBoard.
    panel.backgroundColor = self.dark ? [UIColor colorWithWhite:0.10 alpha:1] : UIColor.systemBackgroundColor;
    panel.layer.cornerRadius = 22;
    panel.clipsToBounds = YES;
    self.panel = panel;
    [self.overlay addSubview:panel];
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:
        self.dark ? UIBlurEffectStyleSystemMaterialDark : UIBlurEffectStyleSystemMaterialLight]];
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blur.frame = panel.bounds;
    blur.contentView.backgroundColor = self.dark ? [UIColor colorWithWhite:0.08 alpha:0.5] : [UIColor colorWithWhite:1 alpha:0.5];
    [panel addSubview:blur];
    UIColor *text = self.dark ? UIColor.whiteColor : UIColor.labelColor;
    UIControl *header = [[UIControl alloc] init];
    header.tag = 30;
    [header addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];
    UISwipeGestureRecognizer *closeSwipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(dismiss)];
    closeSwipe.direction = UISwipeGestureRecognizerDirectionDown;
    [header addGestureRecognizer:closeSwipe];
    [panel addSubview:header];
    UIView *handle = [[UIView alloc] init];
    handle.tag = 31;
    handle.backgroundColor = [text colorWithAlphaComponent:0.45];
    handle.layer.cornerRadius = 2;
    handle.userInteractionEnabled = NO;
    [header addSubview:handle];
    self.titleLabel = [[UILabel alloc] init];
    NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
    self.titleLabel.text = DXPanelString(definition[@"name"]);
    self.titleLabel.textColor = text;
    self.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [panel addSubview:self.titleLabel];
    self.closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.closeButton setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    self.closeButton.tintColor = text;
    self.closeButton.accessibilityLabel = [bundle localizedStringForKey:@"KEYBOARD_PANEL_CLOSE" value:@"Close" table:nil];
    [self.closeButton addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:self.closeButton];

    self.systemControls = [DXPanelSystemControlsView new];
    [self.systemControls configureWithPreferences:preferences preview:NO];
    __weak typeof(self) weakSelf = self;
    __weak DXPanelSystemControlsView *controls = self.systemControls;
    NSString *configuration = [toolbar.configuration copy];
    if (!self.systemControls.hidden) {
        self.controlSession = [[DXPanelControlSession alloc] initWithRequester:^NSProgress *(NSString *action, NSNumber *value, DXPanelSystemControlReply reply) {
            return DXRequestPanelSystemControl(action, value, configuration, reply);
        } validity:^BOOL {
            DXKeyboardPanel *owner = weakSelf;
            return owner && controls && owner.systemControls == controls && [owner validSession];
        } update:^(DXSystemOpenResult result, NSDictionary *state, BOOL busy, NSString *action) {
            [controls applyState:state busy:busy];
            if (result == DXSystemOpenSucceeded) [controls showMessage:nil];
            else {
                NSString *key = result == DXSystemOpenTimedOut ? @"SYSTEM_ACTION_TIMEOUT" :
                    (result == DXSystemOpenFailed ? @"SYSTEM_ACTION_FAILED" : @"SYSTEM_ACTION_UNAVAILABLE");
                [controls showMessage:[bundle localizedStringForKey:key value:@"系统操作不可用" table:nil]];
            }
        }];
        self.systemControls.actionHandler = ^(NSString *action, NSNumber *value) {
            DXKeyboardPanel *owner = weakSelf;
            if (owner.systemControls != controls || ![owner validSession]) { [owner dismiss]; return; }
            [owner.controlSession enqueueAction:action value:value];
        };
    }

    self.scroll = [[UIScrollView alloc] init];
    self.scroll.showsVerticalScrollIndicator = NO;
    self.scroll.directionalLockEnabled = YES;
    [panel addSubview:self.scroll];
    [self.scroll addSubview:self.systemControls];
    self.grid = [DXPanelPagedGridView new];
    self.grid.diagnosticName = @"keyboard";
    __weak DXPanelPagedGridView *grid = self.grid;
    self.grid.blankAction = ^{
        DXKeyboardPanel *owner = weakSelf;
        if (owner.grid == grid) [owner dismiss];
    };
    [self.scroll addSubview:self.grid];
    NSMutableArray *buttons = [NSMutableArray array];
    for (NSDictionary *entry in items) {
        NSString *selector = entry[@"selector"];
        if (![toolbar canExecuteKeyboardPanelSelector:selector]) continue;
        DXKeyboardPanelButton *button = [DXKeyboardPanelButton buttonWithType:UIButtonTypeCustom];
        button.actionSelector = selector;
        button.actionImage = [[UIImageView alloc] init];
        button.actionImage.contentMode = UIViewContentModeScaleAspectFit;
        button.actionImage.tintColor = text;
        button.actionImage.image = [toolbar subActionPanelImageForSelector:selector];
        button.actionLabel = [[UILabel alloc] init];
        NSString *name = entry[@"name"];
        button.actionLabel.text = name.length ? name : [toolbar subActionPanelTitleForSelector:selector];
        button.actionLabel.textColor = text;
        button.actionLabel.numberOfLines = 2;
        button.actionLabel.textAlignment = NSTextAlignmentCenter;
        button.actionLabel.font = [UIFont systemFontOfSize:12 * self.scale];
        button.actionLabel.adjustsFontSizeToFitWidth = YES;
        button.actionLabel.minimumScaleFactor = 0.8;
        button.accessibilityLabel = button.actionLabel.text;
        [button addSubview:button.actionImage];
        [button addSubview:button.actionLabel];
        [button addTarget:self action:@selector(itemTapped:) forControlEvents:UIControlEventTouchUpInside];
        [buttons addObject:button];
    }
    self.buttons = buttons;
    [self.grid configureWithItems:buttons columns:self.columns scale:self.scale];
    UIControl *blank = [[UIControl alloc] init];
    blank.tag = 20;
    [blank addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];
    [self.scroll insertSubview:blank atIndex:0];
    [self layoutPanel];
    if (!self.window) return;
    [self.controlSession enqueueAction:@"state" value:nil];
    NSLog(@"[MUBX][KeyboardPanel] open side=%@ toolbar=%@ items=%lu rect=%@ host=%@ source=%@ toggleRow=%d sliderRow=%d",
        profile, toolbar.configuration, (unsigned long)buttons.count, NSStringFromCGRect(self.overlay.panelRect),
        NSStringFromClass(window.class), NSStringFromClass(toolbar.window.class),
        self.systemControls.showsToggleRow, self.systemControls.showsSliderRow);
}
- (void)layoutPanel {
    if (!self.window) return;
    CGRect coverage = [self coverageInWindow:self.window];
    if (CGRectIsNull(coverage) || CGRectIsEmpty(coverage)) {
        NSLog(@"[MUBX][KeyboardPanel] open cancelled: keyboard geometry unavailable");
        [self dismiss];
        return;
    }
    self.overlay.frame = self.window.bounds;
    self.overlay.bounds = self.window.bounds;
    [self raiseOverlay];
    self.overlay.panelRect = coverage;
    self.panel.frame = coverage;
    CGFloat width = coverage.size.width, height = coverage.size.height;
    [self.panel viewWithTag:30].frame = CGRectMake(0, 0, width, 46);
    [self.panel viewWithTag:31].frame = CGRectMake((width - 38) / 2, 3, 38, 4);
    self.titleLabel.frame = CGRectMake(16, 10, MAX(0, width - 68), 28);
    self.closeButton.frame = CGRectMake(width - 48, 2, 44, 44);
    CGFloat controlsHeight = [self.systemControls preferredHeightForWidth:MAX(0, width - 16)];
    self.scroll.frame = CGRectMake(8, 46, MAX(0, width - 16), MAX(0, height - 54));
    self.systemControls.frame = CGRectMake(0, 0, self.scroll.bounds.size.width, controlsHeight);
    CGFloat gridHeight = [self.grid preferredHeightForWidth:self.scroll.bounds.size.width];
    self.grid.frame = CGRectMake(0, controlsHeight, self.scroll.bounds.size.width, gridHeight);
    [self.grid layoutIfNeeded];
    CGFloat itemWidth = self.scroll.bounds.size.width / self.columns;
    CGFloat circle = DXKeyboardPanelCircle(self.scroll.bounds.size.width, self.columns, self.scale);
    [self.buttons enumerateObjectsUsingBlock:^(DXKeyboardPanelButton *button, NSUInteger index, BOOL *stop) {
        (void)stop;
        (void)index;
        UIView *circleView = [button viewWithTag:10];
        if (!circleView) {
            circleView = [[UIView alloc] init];
            circleView.tag = 10;
            circleView.userInteractionEnabled = NO;
            circleView.backgroundColor = self.dark ? [UIColor colorWithWhite:0 alpha:0.45] : [UIColor colorWithWhite:1 alpha:0.65];
            [button insertSubview:circleView atIndex:0];
        }
        circleView.frame = CGRectMake((itemWidth - circle) / 2, 4, circle, circle);
        circleView.layer.cornerRadius = circle / 2;
        CGFloat icon = circle * 0.52;
        button.actionImage.frame = CGRectMake((itemWidth - icon) / 2, 4 + (circle - icon) / 2, icon, icon);
        button.actionLabel.frame = CGRectMake(3, circle + 9, itemWidth - 6, 30 * self.scale);
    }];
    CGFloat contentHeight = MAX(self.scroll.bounds.size.height, controlsHeight + gridHeight);
    self.scroll.contentSize = CGSizeMake(self.scroll.bounds.size.width, contentHeight);
    [self.scroll viewWithTag:20].frame = CGRectMake(0, 0, self.scroll.bounds.size.width, contentHeight);
}
- (void)itemTapped:(DXKeyboardPanelButton *)button {
    if (![self validSession] || ![self.buttons containsObject:button]) { [self dismiss]; return; }
    DXCollectionView *source = self.source;
    NSString *selector = [button.actionSelector copy];
    if (![source canExecuteKeyboardPanelSelector:selector]) { [self dismiss]; return; }
    // Synchronous dismissal leaves no animation callback that could target a new input session.
    [self dismiss];
    [source dispatchKeyboardPanelSelector:selector sender:button];
}
- (void)dismiss {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self dismiss]; });
        return;
    }
    [self.controlSession invalidate];
    self.controlSession = nil;
    self.systemControls.actionHandler = nil;
    self.systemControls = nil;
    [self.overlay removeFromSuperview];
    self.overlay = nil;
    self.window = nil;
    self.sessionScene = nil;
    self.panel = nil;
    self.grid.blankAction = nil;
    self.grid = nil;
    self.scroll = nil;
    self.buttons = nil;
    self.titleLabel = nil;
    self.closeButton = nil;
    self.source = nil;
    self.sourceWindow = nil;
    self.input = nil;
    self.snapshot = nil;
}
@end
