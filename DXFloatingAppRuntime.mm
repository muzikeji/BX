// Scene-layer hosting and foreground assertions follow the mechanisms in
// PullOver-X (c1d3rDev / PullOver-X contributors, GPL-3.0). TypeX owns this
// session, requester identity, UI and routing; no PullOver-X binary is used.
#import "DXFloatingApp.h"
#import "DXFloatingAppSession.h"
#import "DXFloatingAppShelfChannel.h"
#import "DXFloatingAppGeometry.h"
#import "DXFloatingAppInput.h"
#import "DXGlobalPanel.h"
#import "common.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <notify.h>
#include <math.h>
#include <limits.h>
#include <signal.h>
#include <errno.h>

static NSString * const DXFloatRequester = @"com.lindo.typex.floating-app";
static void *DXFloatLayerObservation = &DXFloatLayerObservation;
static void *DXFloatContentObservation = &DXFloatContentObservation;
// 卡片延迟显示窗口：期间挂接内容则直接带内容显示，超时才显示加载指示。
static const NSTimeInterval DXFloatCardPresentDelay = 0.25;
static NSBundle *tweakBundle;
static BOOL DXFloatHooksReady;

static id DXFloatObject(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (![object respondsToSelector:selector] || signature.numberOfArguments != 2 ||
        (strcmp(signature.methodReturnType, "@") && strcmp(signature.methodReturnType, "#"))) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(object, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static id DXFloatObjectArgument(id object, NSString *name, id argument) {
    SEL selector = NSSelectorFromString(name);
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (![object respondsToSelector:selector] || signature.numberOfArguments != 3 ||
        strcmp(signature.methodReturnType, "@") || strcmp([signature getArgumentTypeAtIndex:2], "@")) return nil;
    @try { return ((id (*)(id, SEL, id))objc_msgSend)(object, selector, argument); }
    @catch (__unused NSException *exception) { return nil; }
}

static NSInteger DXFloatInteger(id object, NSString *name, NSInteger fallback) {
    SEL selector = NSSelectorFromString(name);
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (![object respondsToSelector:selector] || signature.numberOfArguments != 2) return fallback;
    const char *type = signature.methodReturnType;
    if (!type || !strchr("cCsSiIlLqQB", type[0]) || type[1]) return fallback;
    @try {
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.target = object; invocation.selector = selector;
        [invocation invoke];
        // Sign-extension matters for -1 failure/PID values.
        if (signature.methodReturnLength == 1) { int8_t value = 0; [invocation getReturnValue:&value]; return value; }
        if (signature.methodReturnLength == 2) { int16_t value = 0; [invocation getReturnValue:&value]; return value; }
        if (signature.methodReturnLength == 4) { int32_t value = 0; [invocation getReturnValue:&value]; return value; }
        if (signature.methodReturnLength == 8) { int64_t value = 0; [invocation getReturnValue:&value]; return (NSInteger)value; }
    } @catch (__unused NSException *exception) {}
    return fallback;
}

static void DXFloatSetBool(id object, NSString *name, BOOL value) {
    SEL selector = NSSelectorFromString(name);
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (![object respondsToSelector:selector] || signature.numberOfArguments != 3 ||
        strcmp(signature.methodReturnType, "v")) return;
    const char *argument = [signature getArgumentTypeAtIndex:2];
    if (strcmp(argument, @encode(BOOL)) && strcmp(argument, "c")) return;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(object, selector, value);
}

static NSString *DXFloatIdentifier(id application) {
    if ([application isKindOfClass:NSString.class]) return application;
    id identifier = DXFloatObject(application, @"bundleIdentifier") ?: DXFloatObject(application, @"applicationIdentifier")
        ?: DXFloatObject(application, @"displayIdentifier");
    return [identifier isKindOfClass:NSString.class] ? identifier : nil;
}

static id DXFloatApplication(NSString *identifier) {
    id controller = DXFloatObject(NSClassFromString(@"SBApplicationController"), @"sharedInstance");
    return DXFloatObjectArgument(controller, @"applicationWithBundleIdentifier:", identifier)
        ?: DXFloatObjectArgument(controller, @"applicationWithDisplayIdentifier:", identifier);
}

static NSString *DXFloatFrontmostIdentifier(void) {
    return DXFloatIdentifier(DXFloatObject(UIApplication.sharedApplication, @"_accessibilityFrontMostApplication"));
}

static BOOL DXFloatSceneMatches(id scene, NSString *bundleIdentifier) {
    id value = DXFloatObject(scene, @"identifier");
    if (![value isKindOfClass:NSString.class] || !bundleIdentifier.length) return NO;
    NSString *identifier = value;
    return [identifier isEqual:bundleIdentifier] || [identifier hasPrefix:[bundleIdentifier stringByAppendingString:@"-"]]
        || [identifier hasPrefix:[@"sceneID:" stringByAppendingFormat:@"%@-", bundleIdentifier]];
}

static id DXFloatFindScene(NSString *identifier) {
    id manager = DXFloatObject(NSClassFromString(@"FBSceneManager"), @"sharedInstance");
    SEL enumerate = NSSelectorFromString(@"enumerateScenesWithBlock:");
    __block id bestScene;
    __block NSInteger bestScore = -1;
    if ([manager respondsToSelector:enumerate]) {
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(manager, enumerate, ^(id scene, __unused BOOL *stop) {
                if (!DXFloatSceneMatches(scene, identifier) || !DXFloatInteger(scene, @"isValid", YES)) return;
                NSString *sceneIdentifier = DXFloatObject(scene, @"identifier");
                NSInteger score = [sceneIdentifier hasSuffix:@"-default"] ? 100 : 10;
                if (DXFloatInteger(scene, @"isActive", NO)) score += 1;
                if (score > bestScore) { bestScene = scene; bestScore = score; }
            });
        } @catch (__unused NSException *exception) {}
    }
    if (bestScene) return bestScene;
    id application = DXFloatApplication(identifier);
    for (NSString *name in @[@"mainScene", @"_mainScene", @"scene"]) {
        id scene = DXFloatObject(application, name);
        if (scene && DXFloatInteger(scene, @"isValid", YES) && DXFloatSceneMatches(scene, identifier)) return scene;
    }
    return nil;
}

static pid_t DXFloatPID(NSString *identifier) {
    id application = DXFloatApplication(identifier);
    NSInteger pid = DXFloatInteger(application, @"pid", 0);
    if (pid <= 0) pid = DXFloatInteger(DXFloatObject(application, @"processState"), @"pid", 0);
    return pid > 0 && pid <= INT_MAX ? (pid_t)pid : 0;
}

static NSString *DXFloatConstant(const char *name) {
    NSString * __unsafe_unretained *symbol = (NSString * __unsafe_unretained *)dlsym(RTLD_DEFAULT, name);
    return symbol && [*symbol isKindOfClass:NSString.class] ? *symbol : nil;
}

NSString *DXFloatingBundleIdentifierForURL(NSURL *url) {
    if (!NSThread.isMainThread || !url.scheme.length) return nil;
    id workspace = DXFloatObject(NSClassFromString(@"LSApplicationWorkspace"), @"defaultWorkspace");
    NSString *identifier = DXFloatIdentifier(DXFloatObjectArgument(workspace, @"applicationForOpeningResource:", url));
    if (DXIsValidBundleIdentifier(identifier) && DXFloatApplication(identifier)) return identifier;
    id candidates = DXFloatObjectArgument(workspace, @"applicationsAvailableForOpeningURL:", url);
    if (![candidates isKindOfClass:NSArray.class] || ![candidates count])
        candidates = DXFloatObjectArgument(workspace, @"applicationsAvailableForHandlingURLScheme:", url.scheme);
    if ([candidates isKindOfClass:NSArray.class]) {
        for (id application in candidates) {
            identifier = DXFloatIdentifier(application);
            if (DXIsValidBundleIdentifier(identifier) && DXFloatApplication(identifier)) return identifier;
        }
    }
    // Settings' private schemes aren't included in every LaunchServices list.
    if ([@[@"prefs", @"app-prefs"] containsObject:url.scheme.lowercaseString] && DXFloatApplication(@"com.apple.Preferences"))
        return @"com.apple.Preferences";
    return nil;
}

@class DXFloatingAppCoordinator;

static BOOL DXFloatConfigureBackdropHitTesting(id layer) {
    // WindowServer 先选择触摸所属的渲染图层，再进入该进程的 UIKit hitTest。
    // clearColor 的背景仅有 UIKit 点击层还不够：必须显式让透明边界参与命中。
    for (NSString *getterName in @[@"allowsHitTesting", @"hitTestsAsOpaque"]) {
        SEL getter = NSSelectorFromString(getterName);
        NSString *setterName = [NSString stringWithFormat:@"set%@%@:",
            [[getterName substringToIndex:1] uppercaseString], [getterName substringFromIndex:1]];
        SEL setter = NSSelectorFromString(setterName);
        NSMethodSignature *getSignature = [layer methodSignatureForSelector:getter];
        NSMethodSignature *setSignature = [layer methodSignatureForSelector:setter];
        if (![layer respondsToSelector:getter] || ![layer respondsToSelector:setter] ||
            getSignature.numberOfArguments != 2 || setSignature.numberOfArguments != 3 ||
            strcmp(setSignature.methodReturnType, "v")) return NO;
        const char *result = getSignature.methodReturnType;
        const char *argument = [setSignature getArgumentTypeAtIndex:2];
        if ((strcmp(result, "B") && strcmp(result, "c")) ||
            (strcmp(argument, "B") && strcmp(argument, "c"))) return NO;
        @try {
            ((void (*)(id, SEL, bool))objc_msgSend)(layer, setter, true);
            if (!((bool (*)(id, SEL))objc_msgSend)(layer, getter)) return NO;
        } @catch (__unused NSException *exception) { return NO; }
    }
    return YES;
}

@interface DXFloatingAppWindow : UIWindow
@property(nonatomic, weak) UIView *card;
@property(nonatomic, weak) UIView *backdrop;
@end
@implementation DXFloatingAppWindow
- (BOOL)canBecomeKeyWindow { return NO; }
- (bool)_shouldCreateContextAsSecure { return YES; }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || !self.card || self.card.hidden) return nil;
    CGPoint local = [self.card convertPoint:point fromView:self];
    if ([self.card pointInside:local withEvent:event]) return [self.card hitTest:local withEvent:event];
    // 外部点击由独立背景层接收；不在 hitTest 中改变窗口生命周期。
    UIView *backdrop = self.backdrop;
    if (!backdrop) return nil;
    CGPoint backgroundPoint = [backdrop convertPoint:point fromView:self];
    return [backdrop hitTest:backgroundPoint withEvent:event];
}
@end

@interface DXFloatingAppCardController : UIViewController <UIGestureRecognizerDelegate>
@property(nonatomic, weak) DXFloatingAppCoordinator *owner;
@property(nonatomic, strong) UIView *card;
@property(nonatomic, strong) UIView *backdrop;
@property(nonatomic, strong) UIView *canvas;
@property(nonatomic, strong) UIView *content;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@property(nonatomic) CGSize canvasSize;
@property(nonatomic) CGPoint normalizedCenter;
// 悬浮设置页写入的最大占屏比例；打开时注入，悬浮期间随 prefs 变更热更。
@property(nonatomic) CGFloat maxScale;
// 悬浮设置页写入的水平停靠位置（0=居左 1=居中 2=居右）；拖动后以拖动为准。
@property(nonatomic) NSInteger horizontalAlignment;
@property(nonatomic) BOOL horizontalCustomized;
@property(nonatomic) CGFloat requestedZoom;
@property(nonatomic) CGFloat displayedZoom;
@property(nonatomic) CGFloat pinchStartZoom;
@property(nonatomic, strong) UIPanGestureRecognizer *dragGesture;
@property(nonatomic, strong) UIPinchGestureRecognizer *pinchGesture;
- (void)setTitle:(NSString *)title;
- (void)setHostViews:(NSArray<UIView *> *)views canvasSize:(CGSize)size;
- (void)applyPinchScale:(CGFloat)scale phase:(DXFloatPinchPhase)phase;
@end

@interface DXFloatingAppCoordinator : NSObject
@property(nonatomic, strong) DXFloatingAppShelfState *shelf;
@property(nonatomic) BOOL shelfStartupReady;
@property(nonatomic, strong) id shelfLaunchObserver;
@property(nonatomic, strong) DXFloatingAppSession *session;
@property(nonatomic, strong) DXFloatingAppWindow *window;
@property(nonatomic, strong) DXFloatingAppCardController *controller;
@property(nonatomic, strong) id scene;
@property(nonatomic, strong) id baseScene;
@property(nonatomic, copy) NSString *baseIdentifier;
@property(nonatomic, strong) id originalSettings;
@property(nonatomic, strong) id layerManager;
@property(nonatomic, strong) id fallbackHostManager;
@property(nonatomic, strong) id assertion;
@property(nonatomic, strong) NSArray *publishedLayers;
@property(nonatomic, copy) NSURL *requestedURL;
@property(nonatomic) BOOL urlAccepted;
@property(nonatomic) BOOL hasContent;
@property(nonatomic) BOOL observingLayers;
@property(nonatomic) pid_t processPID;
@property(nonatomic) BOOL activeLease;
@property(nonatomic) BOOL sceneCreationAttempted;
@property(nonatomic) BOOL loggedProcessWait;
@property(nonatomic) BOOL loggedContentWait;
@property(nonatomic) BOOL observingContent;
@property(nonatomic) BOOL windowPresented;
@property(nonatomic) CFAbsoluteTime prepareStartedAt;
@property(nonatomic, strong) NSArray<NSNumber *> *notifyTokens;
@property(nonatomic) int inputSessionToken;
@property(nonatomic) int inputToken;
@property(nonatomic) int inputSceneToken;
@property(nonatomic) uint32_t inputNonce;
@property(nonatomic) uint8_t inputGesture;
@property(nonatomic) BOOL inputGestureFinished;
+ (instancetype)shared;
- (void)open:(NSString *)identifier url:(NSURL *)url deadline:(NSDate *)deadline reply:(DXSystemOpenReply)reply;
- (void)close;
- (void)minimize;
- (void)applyPreferencesChanged;
- (BOOL)shelfEnabled;
- (void)publishShelf;
- (void)finishShelfStartup;
- (void)cleanup:(DXSystemOpenResult)result reason:(NSString *)reason;
- (void)poll:(NSUInteger)generation;
- (BOOL)evaluate:(NSUInteger)generation;
- (BOOL)adoptScene:(id)scene pid:(pid_t)pid generation:(NSUInteger)generation;
- (void)presentCardIfPending:(NSUInteger)generation;
- (void)publishLayers;
- (void)startInputRelay;
- (void)receivePinchWord:(uint64_t)word nonce:(uint32_t)nonce;
- (void)stopInputRelay;
- (BOOL)protectsScene:(id)scene;
- (id)protectedSettings:(id)settings scene:(id)scene;
@end

@implementation DXFloatingAppCardController
- (instancetype)init {
    if ((self = [super init])) {
        self.normalizedCenter = CGPointMake(0.5, 0.45);
        self.horizontalAlignment = 1;
        self.requestedZoom = self.displayedZoom = self.pinchStartZoom = 1;
    }
    return self;
}
- (void)loadView {
    self.view = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.view.backgroundColor = UIColor.clearColor;
    self.backdrop = [[UIView alloc] initWithFrame:self.view.bounds];
    self.backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.backdrop.backgroundColor = UIColor.clearColor;
    BOOL hitTestingConfigured = DXFloatConfigureBackdropHitTesting(self.backdrop.layer);
    // 不支持显式图层命中的系统使用实际绘制的轻微遮罩，避免再次漏收 App 外部点击。
    if (!hitTestingConfigured) self.backdrop.backgroundColor = [UIColor colorWithWhite:0 alpha:0.03];
    NSLog(@"[TypeX][FloatingApp] backdrop routing configured=%d", hitTestingConfigured);
    [self.backdrop addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(outsideTapped:)]];
    [self.view addSubview:self.backdrop];
    self.card = [[UIView alloc] init];
    self.card.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.card.layer.cornerRadius = 16;
    self.card.layer.masksToBounds = YES;
    [self.view addSubview:self.card];
    UIView *header = [[UIView alloc] init]; header.tag = 41;
    [self.card addSubview:header];
    self.titleLabel = [[UILabel alloc] init]; self.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    self.titleLabel.textColor = UIColor.labelColor;
    [header addSubview:self.titleLabel];
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem]; close.tag = 42;
    [close setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    close.accessibilityLabel = LOCALIZED(@"FLOATING_APP_CLOSE");
    [close addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:close];
    // "-" 最小化：收起小窗并把目标挂后台，与右侧关闭按钮相邻。
    UIButton *minimize = [UIButton buttonWithType:UIButtonTypeSystem]; minimize.tag = 43;
    [minimize setImage:[UIImage systemImageNamed:@"minus.circle.fill"] forState:UIControlStateNormal];
    minimize.accessibilityLabel = LOCALIZED(@"FLOATING_APP_MINIMIZE");
    [minimize addTarget:self action:@selector(minimizeTapped) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:minimize];
    UIPanGestureRecognizer *drag = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)];
    drag.maximumNumberOfTouches = 1;
    drag.delegate = self;
    self.dragGesture = drag;
    [header addGestureRecognizer:drag];
    self.pinchGesture = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pinch:)];
    self.pinchGesture.delegate = self;
    [self.card addGestureRecognizer:self.pinchGesture];
    self.content = [[UIView alloc] init]; self.content.clipsToBounds = YES;
    [self.card addSubview:self.content];
    self.canvas = [[UIView alloc] init]; [self.content addSubview:self.canvas];
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [self.content addSubview:self.spinner]; [self.spinner startAnimating];
}
- (void)closeTapped { [self.owner close]; }
- (void)minimizeTapped { [self.owner minimize]; }
- (void)outsideTapped:(UITapGestureRecognizer *)gesture {
    DXFloatingAppCoordinator *owner = self.owner;
    // 收起/替换窗口后，已经排队的旧点击不能影响新的悬浮会话。
    if (gesture.state != UIGestureRecognizerStateEnded || !owner || owner.controller != self ||
        owner.window.hidden || owner.window.card != self.card || owner.window.backdrop != gesture.view) return;
    NSLog(@"[TypeX][FloatingApp] outside tap minimize");
    [owner minimize];
}
- (void)setTitle:(NSString *)title { [self loadViewIfNeeded]; self.titleLabel.text = title; }
- (void)drag:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self.view];
    if (!CGPointEqualToPoint(translation, CGPointZero)) self.horizontalCustomized = YES;
    CGPoint center = self.card.center;
    center.x += translation.x; center.y += translation.y;
    self.normalizedCenter = CGPointMake(center.x / MAX(1, self.view.bounds.size.width), center.y / MAX(1, self.view.bounds.size.height));
    [gesture setTranslation:CGPointZero inView:self.view];
    [self.view setNeedsLayout]; [self.view layoutIfNeeded];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    if (gesture == self.dragGesture) {
        for (UIView *view = touch.view; view && view != gesture.view; view = view.superview)
            if ([view isKindOfClass:UIControl.class]) return NO;
    }
    return YES;
}
- (void)pinch:(UIPinchGestureRecognizer *)gesture {
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan: [self applyPinchScale:gesture.scale phase:DXFloatPinchBegan]; break;
        case UIGestureRecognizerStateChanged: [self applyPinchScale:gesture.scale phase:DXFloatPinchChanged]; break;
        case UIGestureRecognizerStateEnded: [self applyPinchScale:gesture.scale phase:DXFloatPinchEnded]; break;
        case UIGestureRecognizerStateCancelled: [self applyPinchScale:1 phase:DXFloatPinchCancelled]; break;
        default: break;
    }
}
- (void)applyPinchScale:(CGFloat)scale phase:(DXFloatPinchPhase)phase {
    if (!isfinite(scale) || scale <= 0) return;
    if (phase == DXFloatPinchBegan) self.pinchStartZoom = self.displayedZoom;
    self.requestedZoom = phase == DXFloatPinchCancelled ? self.pinchStartZoom : self.pinchStartZoom * scale;
    [self.view setNeedsLayout]; [self.view layoutIfNeeded];
    if (phase == DXFloatPinchEnded || phase == DXFloatPinchCancelled) {
        self.requestedZoom = self.displayedZoom;
        NSLog(@"[TypeX][FloatingApp] resize zoom=%.3f", (double)self.displayedZoom);
    }
}
- (void)placeCard:(CGSize)size available:(CGRect)available {
    self.displayedZoom = DXFloatingAppZoom(size, available, self.requestedZoom);
    CGPoint center = CGPointMake(CGRectGetMinX(self.view.bounds) + self.view.bounds.size.width * self.normalizedCenter.x,
                                 CGRectGetMinY(self.view.bounds) + self.view.bounds.size.height * self.normalizedCenter.y);
    CGRect frame = DXFloatingAppFrame(size, available, self.displayedZoom, center,
                                     self.horizontalAlignment, self.horizontalCustomized);
    self.card.transform = CGAffineTransformIdentity;
    self.card.bounds = (CGRect){CGPointZero, size};
    self.card.center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    self.card.transform = CGAffineTransformMakeScale(self.displayedZoom, self.displayedZoom);
    if (self.horizontalCustomized) {
        self.normalizedCenter = CGPointMake((self.card.center.x - CGRectGetMinX(self.view.bounds)) / MAX(1, self.view.bounds.size.width),
                                            (self.card.center.y - CGRectGetMinY(self.view.bounds)) / MAX(1, self.view.bounds.size.height));
    }
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    if (CGRectIsEmpty(bounds)) return;
    UIEdgeInsets safe = self.view.safeAreaInsets;
    CGSize size = self.canvasSize;
    if (size.width < 1 || size.height < 1) size = UIScreen.mainScreen.bounds.size;
    CGFloat cap = (self.maxScale >= 0.30 && self.maxScale <= 1.0) ? self.maxScale : 0.72;
    UIView *header = [self.card viewWithTag:41];
    [self.card bringSubviewToFront:header];
    // 100% 视为全屏接管：卡片铺满整屏、内容铺满卡片，标题栏悬浮在安全区下方，
    // 保证关闭/最小化/拖动仍可用；其余比例保持留白小窗布局。
    if (cap >= 0.999) {
        CGFloat scale = MIN(1.0, MIN(bounds.size.width / size.width, bounds.size.height / size.height));
        CGFloat width = bounds.size.width, height = bounds.size.height;
        CGFloat headerY = MAX(0, safe.top);
        [self placeCard:bounds.size available:bounds];
        self.card.layer.cornerRadius = self.displayedZoom >= 0.999 ? 0 : 16;
        header.frame = CGRectMake(0, headerY, width, 44);
        header.backgroundColor = [UIColor.secondarySystemBackgroundColor colorWithAlphaComponent:0.9];
        [header viewWithTag:42].frame = CGRectMake(width - 44, 0, 44, 44);
        [header viewWithTag:43].frame = CGRectMake(width - 88, 0, 44, 44);
        self.titleLabel.frame = CGRectMake(12, 0, MAX(0, width - 104), 44);
        self.content.frame = (CGRect){CGPointZero, bounds.size};
        self.canvas.transform = CGAffineTransformIdentity;
        self.canvas.bounds = (CGRect){CGPointZero, size};
        self.canvas.center = CGPointMake(width / 2, height / 2);
        self.canvas.transform = CGAffineTransformMakeScale(scale, scale);
        self.spinner.center = CGPointMake(width / 2, height / 2);
        return;
    }
    CGRect available = UIEdgeInsetsInsetRect(bounds, UIEdgeInsetsMake(safe.top + 8, safe.left, safe.bottom + 8, safe.right));
    if (CGRectIsEmpty(available)) return;
    CGFloat scale = MIN(cap, MIN(available.size.width / size.width, MAX(1, available.size.height - 44) / size.height));
    CGFloat width = size.width * scale, height = size.height * scale + 44;
    self.card.layer.cornerRadius = 16;
    [self placeCard:CGSizeMake(width, height) available:available];
    header.frame = CGRectMake(0, 0, width, 44);
    header.backgroundColor = UIColor.clearColor;
    [header viewWithTag:42].frame = CGRectMake(width - 44, 0, 44, 44);
    [header viewWithTag:43].frame = CGRectMake(width - 88, 0, 44, 44);
    self.titleLabel.frame = CGRectMake(12, 0, MAX(0, width - 104), 44);
    self.content.frame = CGRectMake(0, 44, width, height - 44);
    self.canvas.transform = CGAffineTransformIdentity;
    self.canvas.bounds = (CGRect){CGPointZero, size};
    self.canvas.center = CGPointMake(width / 2, (height - 44) / 2);
    self.canvas.transform = CGAffineTransformMakeScale(scale, scale);
    self.spinner.center = CGPointMake(width / 2, (height - 44) / 2);
}
- (void)setHostViews:(NSArray<UIView *> *)views canvasSize:(CGSize)size {
    self.canvasSize = size;
    for (UIView *view in [self.canvas.subviews copy]) [view removeFromSuperview];
    for (UIView *view in views) {
        view.frame = (CGRect){CGPointZero, size};
        view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.canvas addSubview:view];
    }
    [self.spinner stopAnimating];
    [self.view setNeedsLayout]; [self.view layoutIfNeeded];
}
@end

static UIWindowScene *DXFloatWindowScene(void) {
    UIWindowScene *fallback;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        NSString *identity = windowScene.session.persistentIdentifier ?: @"";
        NSString *role = windowScene.session.role ?: @"";
        if ([identity isEqual:@"com.apple.springboard"]) return windowScene;
        if ([identity.lowercaseString containsString:@"keyboard"] || [identity.lowercaseString containsString:@"systemaperture"] ||
            [role.lowercaseString containsString:@"keyboard"] || [role.lowercaseString containsString:@"systemaperture"]) continue;
        if ([NSStringFromClass(windowScene.class) isEqual:@"SBWindowScene"]) fallback = windowScene;
    }
    return fallback;
}

static void DXFloatApplySettings(id scene, id settings) {
    SEL three = NSSelectorFromString(@"updateSettings:withTransitionContext:completion:");
    SEL two = NSSelectorFromString(@"updateSettings:withTransitionContext:");
    if ([scene respondsToSelector:three]) ((void (*)(id, SEL, id, id, id))objc_msgSend)(scene, three, settings, nil, nil);
    else if ([scene respondsToSelector:two]) ((void (*)(id, SEL, id, id))objc_msgSend)(scene, two, settings, nil);
}

static void DXFloatForegroundSettings(id settings, BOOL foreground) {
    DXFloatSetBool(settings, @"setForeground:", foreground);
    DXFloatSetBool(settings, @"setBackgrounded:", !foreground);
    SEL reasons = NSSelectorFromString(@"setDeactivationReasons:");
    if (foreground && [settings respondsToSelector:reasons]) ((void (*)(id, SEL, unsigned long long))objc_msgSend)(settings, reasons, 0);
}

// Register the hosted scene with the system switcher. A suspended launch alone
// never creates a recent-app layout. These signatures are from iOS 17 runtime
// headers; every call is gated for iOS 16/17 availability and ABI shape.
static BOOL DXFloatRegisterSwitcherCard(NSString *identifier, id scene, id windowScene) {
    if (!NSThread.isMainThread || !DXIsValidBundleIdentifier(identifier) || !scene || !windowScene) return NO;
    NSString *sceneIdentifier = DXFloatObject(scene, @"identifier");
    if (!DXFloatSceneMatches(scene, identifier) || !sceneIdentifier.length) return NO;
    id coordinator = DXFloatObject(NSClassFromString(@"SBMainSwitcherControllerCoordinator"), @"sharedInstance");
    Class itemClass = NSClassFromString(@"SBDisplayItem");
    SEL factory = NSSelectorFromString(@"applicationDisplayItemWithBundleIdentifier:sceneIdentifier:");
    NSMethodSignature *signature = [itemClass methodSignatureForSelector:factory];
    if (![itemClass respondsToSelector:factory] || signature.numberOfArguments != 4 ||
        strcmp(signature.methodReturnType, "@") || strcmp([signature getArgumentTypeAtIndex:2], "@") ||
        strcmp([signature getArgumentTypeAtIndex:3], "@")) return NO;
    @try {
        id item = ((id (*)(id, SEL, id, id))objc_msgSend)(itemClass, factory, identifier, sceneIdentifier);
        if (!item) return NO;
        if (DXFloatObjectArgument(coordinator, @"_appLayoutContainingDisplayItem:", item)) return YES;
        for (NSString *name in @[@"addAppLayoutForDisplayItem:windowScene:completion:",
                                 @"addCenterRoleAppLayoutForDisplayItem:windowScene:completion:"]) {
            SEL add = NSSelectorFromString(name);
            signature = [coordinator methodSignatureForSelector:add];
            if (![coordinator respondsToSelector:add] || signature.numberOfArguments != 5 ||
                strcmp(signature.methodReturnType, "v") || strcmp([signature getArgumentTypeAtIndex:2], "@") ||
                strcmp([signature getArgumentTypeAtIndex:3], "@") || strcmp([signature getArgumentTypeAtIndex:4], "@?")) continue;
            // No retained host/session state in the completion; registration
            // remains valid after the floating window is released.
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(coordinator, add, item, windowScene, ^{});
            return YES;
        }
    } @catch (NSException *exception) {
        NSLog(@"[TypeX][FloatingApp] switcher registration exception=%@", exception.name);
    }
    return NO;
}

@implementation DXFloatingAppCoordinator
+ (instancetype)shared {
    static DXFloatingAppCoordinator *coordinator;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tweakBundle = [NSBundle bundleWithPath:bundlePath];
        coordinator = [self new]; coordinator.session = [DXFloatingAppSession new];
        coordinator.inputSessionToken = coordinator.inputToken = coordinator.inputSceneToken = NOTIFY_TOKEN_INVALID;
        if (notify_register_check(DXFloatInputSessionName.UTF8String, &coordinator->_inputSessionToken) == NOTIFY_STATUS_OK) {
            // Revoke any marker left behind by the previous SpringBoard process.
            notify_set_state(coordinator.inputSessionToken, 0);
            notify_post(DXFloatInputSessionName.UTF8String);
        }
    });
    return coordinator;
}
- (void)startInputRelay {
    if (self.inputToken != NOTIFY_TOKEN_INVALID || self.processPID <= 1 || !self.window) return;
    if (self.inputSessionToken == NOTIFY_TOKEN_INVALID &&
        notify_register_check(DXFloatInputSessionName.UTF8String, &_inputSessionToken) != NOTIFY_STATUS_OK) return;
    uint32_t nonce = arc4random(); if (!nonce) nonce = 1;
    NSUInteger generation = self.session.generation;
    pid_t pid = self.processPID;
    uint64_t sceneHash = DXFloatInputSceneHash(DXFloatObject(self.scene, @"identifier"));
    if (!sceneHash || notify_register_check(DXFloatInputSceneName((uint32_t)pid).UTF8String, &_inputSceneToken) != NOTIFY_STATUS_OK) return;
    __weak typeof(self) weakSelf = self;
    int token = NOTIFY_TOKEN_INVALID;
    if (notify_register_dispatch(DXFloatInputName((uint32_t)pid).UTF8String, &token,
        dispatch_get_main_queue(), ^(int eventToken) {
        DXFloatingAppCoordinator *host = weakSelf;
        if (![host.session isCurrent:generation] || host.inputNonce != nonce || host.processPID != pid ||
            DXFloatPID(host.session.bundleIdentifier) != pid || !host.window || host.window.hidden ||
            ![DXGlobalPanel deviceUnlocked]) return;
        uint64_t word = 0;
        if (notify_get_state(eventToken, &word) == NOTIFY_STATUS_OK) [host receivePinchWord:word nonce:nonce];
    }) != NOTIFY_STATUS_OK) { notify_cancel(self.inputSceneToken); self.inputSceneToken = NOTIFY_TOKEN_INVALID; return; }
    self.inputToken = token; self.inputNonce = nonce; self.inputGesture = 0; self.inputGestureFinished = NO;
    notify_set_state(token, 0);
    if (notify_set_state(self.inputSceneToken, sceneHash) != NOTIFY_STATUS_OK ||
        notify_set_state(self.inputSessionToken, DXFloatInputSessionWord((uint32_t)pid, nonce)) != NOTIFY_STATUS_OK) {
        [self stopInputRelay]; return;
    }
    notify_post(DXFloatInputSessionName.UTF8String);
    NSLog(@"[TypeX][FloatingApp] input relay ready pid=%d generation=%lu", pid, (unsigned long)generation);
}
- (void)receivePinchWord:(uint64_t)word nonce:(uint32_t)nonce {
    uint8_t serial = 0; DXFloatPinchPhase phase; double scale = 0;
    if (self.inputNonce != nonce || !DXFloatDecodePinch(word, nonce, &serial, &phase, &scale)) return;
    if (serial != self.inputGesture) {
        self.inputGesture = serial; self.inputGestureFinished = NO;
        // Notifications coalesce: Changed/Ended may be the first sample.
        [self.controller applyPinchScale:phase == DXFloatPinchBegan ? scale : 1 phase:DXFloatPinchBegan];
        if (phase == DXFloatPinchBegan) return;
    } else if (self.inputGestureFinished || phase == DXFloatPinchBegan) return;
    [self.controller applyPinchScale:scale phase:phase];
    if (phase == DXFloatPinchEnded || phase == DXFloatPinchCancelled) self.inputGestureFinished = YES;
}
- (void)stopInputRelay {
    uint64_t word = 0;
    if (self.inputSessionToken != NOTIFY_TOKEN_INVALID && self.inputNonce &&
        notify_get_state(self.inputSessionToken, &word) == NOTIFY_STATUS_OK &&
        word == DXFloatInputSessionWord((uint32_t)self.processPID, self.inputNonce)) {
        notify_set_state(self.inputSessionToken, 0);
        notify_post(DXFloatInputSessionName.UTF8String);
    }
    self.inputNonce = 0; self.inputGesture = 0; self.inputGestureFinished = NO;
    if (self.inputToken != NOTIFY_TOKEN_INVALID) notify_cancel(self.inputToken);
    if (self.inputSceneToken != NOTIFY_TOKEN_INVALID) notify_cancel(self.inputSceneToken);
    self.inputToken = NOTIFY_TOKEN_INVALID;
    self.inputSceneToken = NOTIFY_TOKEN_INVALID;
}
- (BOOL)protectsScene:(id)scene {
    return NSThread.isMainThread && self.activeLease && self.session.state != DXFloatingAppIdle &&
        (scene == self.scene || scene == self.baseScene);
}
- (id)protectedSettings:(id)settings scene:(id)scene {
    if (![self protectsScene:scene]) return settings;
    @try {
        id mutableSettings = DXFloatObject(settings, @"mutableCopy");
        if (!mutableSettings) return settings;
        DXFloatForegroundSettings(mutableSettings, YES);
        return mutableSettings;
    } @catch (__unused NSException *exception) { return settings; }
}
- (BOOL)shelfEnabled {
    id value = DXPrefsManager.sharedInstance.readPrefs[kFloatingShelfEnabledKey];
    return [value isKindOfClass:NSNumber.class] && [value boolValue];
}
- (void)publishShelf {
    if (!self.shelf) self.shelf = [DXFloatingAppShelfState new];
    NSMutableDictionary *snapshot = [self.shelf.snapshot mutableCopy];
    // This method is called from the tweak's dyld constructor. Even a guarded
    // SBLockScreenManager.sharedInstance call there asserts inside dispatch_once
    // before SpringBoard has launched; @try cannot make that initialization safe.
    snapshot[@"unlocked"] = self.shelfStartupReady ? @([DXGlobalPanel deviceUnlocked]) : @NO;
    snapshot[@"foreground"] = self.shelfStartupReady ? (DXFloatFrontmostIdentifier() ?: @"") : @"";
    if (!DXPublishFloatingShelf(snapshot)) NSLog(@"[TypeX][FloatingShelf] snapshot publish failed");
}
- (void)finishShelfStartup {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self finishShelfStartup]; }); return; }
    if (self.shelfStartupReady) return;
    self.shelfStartupReady = YES;
    if (self.shelfLaunchObserver) {
        [NSNotificationCenter.defaultCenter removeObserver:self.shelfLaunchObserver];
        self.shelfLaunchObserver = nil;
    }
    [self publishShelf];
    NSLog(@"[TypeX][FloatingShelf] startup ready");
}
- (void)close {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self close]; }); return; }
    NSString *identifier = self.session.bundleIdentifier;
    pid_t pid = identifier.length ? DXFloatPID(identifier) : 0;
    [self cleanup:DXSystemOpenFailed reason:@"close-button"];
    // Resolve before and after releasing the lease: never signal a stale PID,
    // the underlying foreground app, SpringBoard, or a newly reopened session.
    if (!DXIsValidBundleIdentifier(identifier) || [identifier isEqual:@"com.apple.springboard"]) return;
    if (pid <= 1 || DXFloatPID(identifier) != pid) {
        NSLog(@"[TypeX][FloatingApp] close process absent or changed bundleID=%@", identifier);
        return;
    }
    if ([DXFloatFrontmostIdentifier() isEqual:identifier] || [self.session.bundleIdentifier isEqual:identifier]) {
        NSLog(@"[TypeX][FloatingApp] close skipped takeover/reopen bundleID=%@", identifier);
        return;
    }
    int result = kill(pid, SIGKILL);
    int error = result == 0 ? 0 : errno;
    NSLog(@"[TypeX][FloatingApp] close terminate bundleID=%@ pid=%d result=%d errno=%d", identifier, pid, result, error);
}
- (void)minimize {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self minimize]; }); return; }
    NSString *identifier = self.session.bundleIdentifier;
    // Keep the canonical scene available while constructing its display item.
    BOOL switcherRequested = DXFloatRegisterSwitcherCard(identifier, self.scene, self.window.windowScene);
    if (self.session.state == DXFloatingAppLive && [self.shelf park:identifier]) {
        NSLog(@"[TypeX][FloatingShelf] park first bundleID=%@ count=%lu", identifier, (unsigned long)self.shelf.items.count);
    }
    [self cleanup:DXSystemOpenFailed reason:@"minimize-button"];
    // 收起小窗后把目标以挂起方式重新停靠：进程仍在则原地保活，进程被系统
    // 回收则挂起重建，保证应用驻留后台而不是随托管解除一并退出。
    if (identifier.length) {
        BOOL parked = [self prewarm:identifier];
        NSLog(@"[TypeX][FloatingApp] minimize bundleID=%@ parked=%d switcherRequested=%d", identifier, parked, switcherRequested);
    }
}
- (void)applyPreferencesChanged {
    // 折叠动作分组、切换任意开关等所有 writePrefs 都会广播 kPrefsChangedIdentifier；
    // 悬浮卡片不该因此被拆掉，只把卡片消费的两项设置（比例/停靠位）热更进当前会话。
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self applyPreferencesChanged]; }); return; }
    DXPrefsManager *manager = DXPrefsManager.sharedInstance;
    [manager reload];
    NSDictionary *preferences = manager.readPrefs;
    if (self.session.state == DXFloatingAppLive && [self shelfEnabled])
        [self.shelf activate:self.session.bundleIdentifier title:self.controller.titleLabel.text];
    [self publishShelf];
    if (self.session.state == DXFloatingAppIdle || !self.controller) return;
    self.controller.maxScale = DXFloatingCardMaxScaleFromPreferences(preferences);
    self.controller.horizontalAlignment = DXFloatingCardPositionFromPreferences(preferences);
    [self.controller.view setNeedsLayout];
}
- (void)cleanup:(DXSystemOpenResult)result reason:(NSString *)reason {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self cleanup:result reason:reason]; }); return; }
    NSString *identifier = self.session.bundleIdentifier;
    if ([reason isEqual:@"close-button"]) [self.shelf remove:identifier];
    else if ([reason isEqual:@"target-switch"] && self.session.state == DXFloatingAppLive) [self.shelf park:identifier];
    [self.shelf releaseActive];
    [self publishShelf];
    [self stopInputRelay];
    self.activeLease = NO;
    // Revoke callbacks before releasing the scene or removing the views.
    [self.session finish:result];
    if (self.observingLayers && self.layerManager) {
        @try { [self.layerManager removeObserver:self forKeyPath:@"layers" context:DXFloatLayerObservation]; }
        @catch (__unused NSException *exception) {}
    }
    self.observingLayers = NO;
    if (self.observingContent && self.scene) {
        @try { [self.scene removeObserver:self forKeyPath:@"contentState" context:DXFloatContentObservation]; }
        @catch (__unused NSException *exception) {}
    }
    self.observingContent = NO;
    if (self.assertion && [self.assertion respondsToSelector:NSSelectorFromString(@"invalidate")]) {
        @try { ((void (*)(id, SEL))objc_msgSend)(self.assertion, NSSelectorFromString(@"invalidate")); }
        @catch (__unused NSException *exception) {}
    }
    self.assertion = nil;
    if (self.fallbackHostManager && [self.fallbackHostManager respondsToSelector:NSSelectorFromString(@"disableHostingForRequester:")]) {
        @try { ((void (*)(id, SEL, id))objc_msgSend)(self.fallbackHostManager, NSSelectorFromString(@"disableHostingForRequester:"), DXFloatRequester); }
        @catch (__unused NSException *exception) {}
    }
    @try {
        // A user-initiated full-screen takeover keeps its system foreground
        // state. General cleanup backgrounds the app; only the close button
        // explicitly terminates its captured process after the lease is released.
        if (self.scene && ![DXFloatFrontmostIdentifier() isEqual:identifier]) {
            id settings = DXFloatObject(self.originalSettings, @"mutableCopy") ?: DXFloatObject(self.scene, @"mutableSettings");
            DXFloatForegroundSettings(settings, NO);
            DXFloatApplySettings(self.scene, settings);
        }
    } @catch (__unused NSException *exception) {}
    self.window.hidden = YES; self.window.rootViewController = nil;
    self.window = nil; self.controller = nil;
    self.scene = nil; self.baseScene = nil; self.baseIdentifier = nil;
    self.originalSettings = nil; self.layerManager = nil; self.fallbackHostManager = nil;
    self.publishedLayers = nil; self.requestedURL = nil; self.urlAccepted = NO;
    self.hasContent = NO; self.processPID = 0; self.sceneCreationAttempted = NO;
    self.loggedProcessWait = NO; self.loggedContentWait = NO;
    self.windowPresented = NO; self.prepareStartedAt = 0;
    if (identifier.length) NSLog(@"[TypeX][FloatingApp] release bundleID=%@ reason=%@", identifier, reason);
}
- (BOOL)prewarm:(NSString *)identifier {
    UIApplication *application = UIApplication.sharedApplication;
    SEL launch = NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:");
    NSMethodSignature *signature = [application methodSignatureForSelector:launch];
    if (![application respondsToSelector:launch] || signature.numberOfArguments != 4) return NO;
    const char *argument = [signature getArgumentTypeAtIndex:3];
    if (strcmp([signature getArgumentTypeAtIndex:2], "@") || (strcmp(argument, @encode(BOOL)) && strcmp(argument, "c"))) return NO;
    @try {
        if (!strcmp(signature.methodReturnType, "v")) {
            ((void (*)(id, SEL, id, BOOL))objc_msgSend)(application, launch, identifier, YES); return YES;
        }
        if (!strcmp(signature.methodReturnType, @encode(BOOL)) || !strcmp(signature.methodReturnType, "c"))
            return ((BOOL (*)(id, SEL, id, BOOL))objc_msgSend)(application, launch, identifier, YES);
    } @catch (__unused NSException *exception) {}
    return NO;
}
- (BOOL)deliverURL:(NSURL *)url generation:(NSUInteger)generation {
    // The workspace URL-open channel (openURL:application:options:
    // clientPort:withResult:) is the same entry an application's openURL
    // funnels through; it re-enters the trusted-open hook where this session
    // marks the activation suspended. A self-assembled openApplication
    // request with payload options is not a system request shape and dies on
    // non-LaunchServices schemes (prefs:/app-prefs:) before the target ever
    // launches, which surfaced as an endless spinner on the card.
    id service = DXFloatObject(NSClassFromString(@"FBSSystemService"), @"sharedService");
    SEL open = NSSelectorFromString(@"openURL:application:options:clientPort:withResult:");
    SEL createPort = NSSelectorFromString(@"createClientPort");
    NSString *suspendedKey = DXFloatConstant("FBSOpenApplicationOptionKeyActivateSuspended");
    NSMethodSignature *signature = [service methodSignatureForSelector:open];
    if (![service respondsToSelector:open] || ![service respondsToSelector:createPort] ||
        signature.numberOfArguments != 7 || strcmp(signature.methodReturnType, "v") ||
        strcmp([signature getArgumentTypeAtIndex:2], "@") || strcmp([signature getArgumentTypeAtIndex:3], "@") ||
        strcmp([signature getArgumentTypeAtIndex:4], "@")) return NO;
    const char *portType = [signature getArgumentTypeAtIndex:5];
    if (strcmp(portType, "I") && strcmp(portType, "i")) return NO;
    if (!suspendedKey.length) return NO;
    NSMutableDictionary *options = [@{suspendedKey: @YES,
        @"__TypeXFloatingGeneration": @(generation)} mutableCopy];
    __weak typeof(self) weakSelf = self;
    @try {
        // FBSSystemServiceResultCallback carries an NSError per the vendored
        // header; a rejected open must fail the card immediately instead of
        // spinning until the readiness deadline.
        mach_port_t port = ((mach_port_t (*)(id, SEL))objc_msgSend)(service, createPort);
        ((void (*)(id, SEL, id, id, id, mach_port_t, id))objc_msgSend)(service, open, url,
            self.session.bundleIdentifier, options, port, ^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                DXFloatingAppCoordinator *host = weakSelf;
                if (![host.session isCurrent:generation]) return;
                if (error) {
                    NSLog(@"[TypeX][FloatingApp] URL rejected bundleID=%@ error=%@",
                        host.session.bundleIdentifier, error.localizedDescription ?: error.domain);
                    [host cleanup:DXSystemOpenFailed reason:@"url-delivery-failed"];
                    return;
                }
                host.urlAccepted = YES;
                NSLog(@"[TypeX][FloatingApp] URL accepted bundleID=%@ generation=%lu", host.session.bundleIdentifier, (unsigned long)generation);
            });
        });
        return YES;
    } @catch (__unused NSException *exception) { return NO; }
}
- (BOOL)acquireAssertion {
    if (self.assertion) return YES;
    Class targetClass = NSClassFromString(@"RBSTarget"), attributeClass = NSClassFromString(@"RBSLegacyAttribute");
    Class assertionClass = NSClassFromString(@"RBSAssertion");
    SEL targetSelector = NSSelectorFromString(@"targetWithPid:"), attributeSelector = NSSelectorFromString(@"attributeWithReason:flags:");
    SEL initializer = NSSelectorFromString(@"initWithExplanation:target:attributes:"), acquire = NSSelectorFromString(@"acquireWithError:");
    if (![targetClass respondsToSelector:targetSelector] || ![attributeClass respondsToSelector:attributeSelector] ||
        ![assertionClass instancesRespondToSelector:initializer] || ![assertionClass instancesRespondToSelector:acquire]) return NO;
    @try {
        id target = ((id (*)(id, SEL, int))objc_msgSend)(targetClass, targetSelector, self.processPID);
        id attribute = ((id (*)(id, SEL, NSUInteger, NSUInteger))objc_msgSend)(attributeClass, attributeSelector, 7, (1U << 0) | (1U << 1) | (1U << 3) | (1U << 5));
        if (!target || !attribute) return NO;
        id assertion = ((id (*)(id, SEL, id, id, id))objc_msgSend)([assertionClass alloc], initializer,
            @"TypeX live floating application", target, @[attribute]);
        NSError *error;
        if (!((BOOL (*)(id, SEL, NSError **))objc_msgSend)(assertion, acquire, &error)) return NO;
        self.assertion = assertion;
        return YES;
    } @catch (__unused NSException *exception) { return NO; }
}
- (void)open:(NSString *)identifier url:(NSURL *)url deadline:(NSDate *)deadline reply:(DXSystemOpenReply)reply {
    if (!NSThread.isMainThread || !self.shelfStartupReady || !DXFloatHooksReady || ![DXGlobalPanel deviceUnlocked] || !DXIsValidBundleIdentifier(identifier) ||
        !DXFloatApplication(identifier) || deadline.timeIntervalSinceNow <= 0) {
        if (reply) reply(DXSystemOpenUnavailable); return;
    }
    if (!url && self.session.state == DXFloatingAppLive && [self.session.bundleIdentifier isEqual:identifier]) {
        if (reply) reply(DXSystemOpenSucceeded); return;
    }
    NSString *frontmost = DXFloatFrontmostIdentifier();
    if ([frontmost isEqual:identifier]) { if (reply) reply(DXSystemOpenBusy); return; }
    UIWindowScene *windowScene = DXFloatWindowScene();
    if (!windowScene) { if (reply) reply(DXSystemOpenUnavailable); return; }
    for (NSDictionary *item in self.shelf.items) if (!DXFloatApplication(item[@"bundleID"])) [self.shelf remove:item[@"bundleID"]];
    [self cleanup:DXSystemOpenBusy reason:@"target-switch"];
    NSUInteger generation = [self.session beginBundleIdentifier:identifier deadline:deadline reply:reply];
    self.baseIdentifier = frontmost;
    self.baseScene = frontmost.length ? DXFloatFindScene(frontmost) : nil;
    self.requestedURL = url; self.urlAccepted = !url;
    self.controller = [DXFloatingAppCardController new]; self.controller.owner = self;
    NSDictionary *preferences = DXPrefsManager.sharedInstance.readPrefs;
    self.controller.maxScale = DXFloatingCardMaxScaleFromPreferences(preferences);
    self.controller.horizontalAlignment = DXFloatingCardPositionFromPreferences(preferences);
    id application = DXFloatApplication(identifier);
    NSString *title = DXFloatObject(application, @"displayName") ?: identifier;
    [self.controller setTitle:title];
    self.window = [[DXFloatingAppWindow alloc] initWithWindowScene:windowScene];
    self.window.frame = windowScene.coordinateSpace.bounds;
    self.window.backgroundColor = UIColor.clearColor;
    self.window.windowLevel = 100;
    self.window.rootViewController = self.controller;
    self.window.card = self.controller.card;
    self.window.backdrop = self.controller.backdrop;
    // 卡片先保持隐藏：内容在延迟窗口内挂接则直接带内容显示，超时才显示加载
    // 指示；失败路径保持隐藏拆窗，不再闪现空转卡片。
    self.window.hidden = YES;
    self.prepareStartedAt = CFAbsoluteTimeGetCurrent();
    NSLog(@"[TypeX][FloatingApp] prepare bundleID=%@ generation=%lu scheme=%@", identifier, (unsigned long)generation, url.scheme ?: @"none");
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(DXFloatCardPresentDelay * NSEC_PER_SEC)), dispatch_get_main_queue(),
        ^{ [weakSelf presentCardIfPending:generation]; });
    // 热恢复：进程存活且存在有效 Scene 时先同步采纳托管，内容即刻挂接。
    // 挂起启动请求仍然补发：最小化会释放运行断言并后台化目标（进程被系统挂
    // 起），场景前台化设置只表达渲染意图，不能保证挂起进程被唤醒；这次请求
    // 是确定性的唤醒源，也是冷启动时进程与场景的准备通道。
    pid_t pid = DXFloatPID(identifier);
    if (pid > 0) {
        id scene = DXFloatFindScene(identifier);
        if (scene && DXFloatInteger(scene, @"isValid", YES)) {
            if (![self adoptScene:scene pid:pid generation:generation]) return;
            NSLog(@"[TypeX][FloatingApp] hot resume bundleID=%@ pid=%d generation=%lu", identifier, pid, (unsigned long)generation);
        }
    }
    if (url ? ![self deliverURL:url generation:generation] : ![self prewarm:identifier]) {
        [self cleanup:DXSystemOpenUnavailable reason:@"suspended-launch-unavailable"]; return;
    }
    [self poll:generation];
}
- (CGSize)canvasSize {
    id settings = DXFloatObject(self.scene, @"settings");
    SEL frame = NSSelectorFromString(@"frame");
    NSMethodSignature *signature = [settings methodSignatureForSelector:frame];
    if ([settings respondsToSelector:frame] && signature.numberOfArguments == 2 && !strcmp(signature.methodReturnType, @encode(CGRect))) {
        CGRect rect = ((CGRect (*)(id, SEL))objc_msgSend)(settings, frame);
        if (isfinite(rect.size.width) && isfinite(rect.size.height) && rect.size.width > 1 && rect.size.height > 1) return rect.size;
    }
    return UIScreen.mainScreen.bounds.size;
}
- (void)publishLayers {
    if (!NSThread.isMainThread || !self.activeLease || !self.scene || !self.controller) return;
    // A scene with an unready content state can already own layers. Don't
    // acknowledge an icon/launch placeholder as a live application.
    NSInteger contentState = DXFloatInteger(self.scene, @"contentState", 2);
    if (contentState != 2) {
        // One-shot: distinguishes a stalled scene (waiting content) from a
        // target that never launched (waiting process) in device syslog.
        if (!self.loggedContentWait) {
            self.loggedContentWait = YES;
            NSLog(@"[TypeX][FloatingApp] waiting content bundleID=%@ contentState=%ld",
                self.session.bundleIdentifier, (long)contentState);
        }
        return;
    }
    @try {
        id collection = DXFloatObject(self.layerManager, @"layers");
        NSArray *layers = [collection isKindOfClass:NSArray.class] ? collection : DXFloatObject(collection, @"array");
        if ([layers isKindOfClass:NSArray.class]) {
            if ([self.publishedLayers isEqualToArray:layers] && CGSizeEqualToSize(self.controller.canvasSize, [self canvasSize])) return;
            NSMutableArray<UIView *> *main = [NSMutableArray array], *external = [NSMutableArray array];
            for (id layer in layers) {
                BOOL keyboard = DXFloatInteger(layer, @"isKeyboardLayer", NO);
                BOOL isExternal = DXFloatObject(layer, @"externalSceneID") != nil;
                NSString *className = keyboard ? @"_UIKeyboardLayerHostView" : isExternal ? @"_UIExternalSceneLayerHostView" : @"_UIContextLayerHostView";
                NSString *method = keyboard ? @"initWithKeyboardLayer:owningScene:" : isExternal ? @"initWithSceneLayer:parentScene:" : @"initWithSceneLayer:";
                Class hostClass = NSClassFromString(className);
                SEL initializer = NSSelectorFromString(method);
                if (![hostClass isSubclassOfClass:UIView.class] || ![hostClass instancesRespondToSelector:initializer]) continue;
                UIView *view = (keyboard || isExternal)
                    ? ((id (*)(id, SEL, id, id))objc_msgSend)([hostClass alloc], initializer, layer, self.scene)
                    : ((id (*)(id, SEL, id))objc_msgSend)([hostClass alloc], initializer, layer);
                if (view) {
                    NSMutableArray *destination = (keyboard || isExternal) ? external : main;
                    [destination addObject:view];
                }
            }
            if (main.count) {
                [main addObjectsFromArray:external];
                [self.controller setHostViews:main canvasSize:[self canvasSize]];
                self.publishedLayers = [layers copy]; self.hasContent = YES;
                [self presentCardIfPending:self.session.generation];
                return;
            }
        }
        if (self.hasContent) return;
        id manager = self.fallbackHostManager ?: DXFloatObject(self.scene, @"hostManager");
        SEL enable = NSSelectorFromString(@"enableHostingForRequester:orderFront:");
        SEL get = NSSelectorFromString(@"hostViewForRequester:enableAndOrderFront:");
        if (![manager respondsToSelector:enable] || ![manager respondsToSelector:get]) return;
        if (!self.fallbackHostManager) ((void (*)(id, SEL, id, BOOL))objc_msgSend)(manager, enable, DXFloatRequester, YES);
        self.fallbackHostManager = manager;
        UIView *view = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(manager, get, DXFloatRequester, YES);
        if ([view isKindOfClass:UIView.class] && DXFloatInteger(view, @"isHosting", YES)) {
            [self.controller setHostViews:@[view] canvasSize:[self canvasSize]]; self.hasContent = YES;
            [self presentCardIfPending:self.session.generation];
        }
    } @catch (NSException *exception) {
        NSLog(@"[TypeX][FloatingApp] layer publication exception=%@", exception.name);
    }
}
- (id)createDefaultSceneIfNeeded:(NSString *)identifier {
    // Only prepare a missing default scene. Never invalidate an existing app
    // scene or create a second app instance to obtain a floating presentation.
    id existing = DXFloatFindScene(identifier);
    if (existing) return existing;
    id manager = DXFloatObject(NSClassFromString(@"FBSceneManager"), @"sharedInstance");
    SEL create = NSSelectorFromString(@"createSceneWithDefinition:initialParameters:");
    if (![manager respondsToSelector:create]) return nil;
    @try {
        id definition = DXFloatObject(NSClassFromString(@"FBSMutableSceneDefinition"), @"definition");
        id identity = DXFloatObjectArgument(NSClassFromString(@"FBSSceneIdentity"), @"identityForIdentifier:", [NSString stringWithFormat:@"sceneID:%@-default", identifier]);
        id client = DXFloatObjectArgument(NSClassFromString(@"FBSSceneClientIdentity"), @"identityForBundleID:", identifier);
        id specification = DXFloatObject(NSClassFromString(@"UIApplicationSceneSpecification"), @"specification");
        id parameters = DXFloatObjectArgument(NSClassFromString(@"FBSMutableSceneParameters"), @"parametersForSpecification:", specification);
        Class settingsClass = NSClassFromString(@"UIMutableApplicationSceneSettings");
        if (!definition || !identity || !client || !specification || !parameters || !settingsClass) return nil;
        id settings = [settingsClass new];
        for (NSString *method in @[@"setIdentity:", @"setClientIdentity:", @"setSpecification:"])
            if (![definition respondsToSelector:NSSelectorFromString(method)]) return nil;
        if (![parameters respondsToSelector:NSSelectorFromString(@"setSettings:")] ||
            ![settings respondsToSelector:NSSelectorFromString(@"setFrame:")]) return nil;
        ((void (*)(id, SEL, id))objc_msgSend)(definition, NSSelectorFromString(@"setIdentity:"), identity);
        ((void (*)(id, SEL, id))objc_msgSend)(definition, NSSelectorFromString(@"setClientIdentity:"), client);
        ((void (*)(id, SEL, id))objc_msgSend)(definition, NSSelectorFromString(@"setSpecification:"), specification);
        id display = DXFloatObject(UIScreen.mainScreen, @"displayConfiguration");
        if (display && [settings respondsToSelector:NSSelectorFromString(@"setDisplayConfiguration:")])
            ((void (*)(id, SEL, id))objc_msgSend)(settings, NSSelectorFromString(@"setDisplayConfiguration:"), display);
        CGRect frame = (CGRect){CGPointZero, self.window.bounds.size};
        ((void (*)(id, SEL, CGRect))objc_msgSend)(settings, NSSelectorFromString(@"setFrame:"), frame);
        DXFloatForegroundSettings(settings, YES);
        DXFloatSetBool(settings, @"setDeviceOrientationEventsEnabled:", YES);
        UIInterfaceOrientation orientation = self.window.windowScene.interfaceOrientation;
        if (orientation == UIInterfaceOrientationUnknown) orientation = UIInterfaceOrientationPortrait;
        if ([settings respondsToSelector:NSSelectorFromString(@"setInterfaceOrientation:")])
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(settings, NSSelectorFromString(@"setInterfaceOrientation:"), orientation);
        ((void (*)(id, SEL, id))objc_msgSend)(parameters, NSSelectorFromString(@"setSettings:"), settings);
        id clientSettings = [NSClassFromString(@"UIMutableApplicationSceneClientSettings") new];
        if ([clientSettings respondsToSelector:NSSelectorFromString(@"setInterfaceOrientation:")] &&
            [parameters respondsToSelector:NSSelectorFromString(@"setClientSettings:")]) {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(clientSettings, NSSelectorFromString(@"setInterfaceOrientation:"), orientation);
            ((void (*)(id, SEL, id))objc_msgSend)(parameters, NSSelectorFromString(@"setClientSettings:"), clientSettings);
        }
        NSLog(@"[TypeX][FloatingApp] prepare missing default scene bundleID=%@", identifier);
        return ((id (*)(id, SEL, id, id))objc_msgSend)(manager, create, definition, parameters);
    } @catch (__unused NSException *exception) { return nil; }
}
// 卡片展示唯一入口：内容先到则直接带内容显示，延迟窗口超时兜底显示加载指示。
- (void)presentCardIfPending:(NSUInteger)generation {
    if (![self.session isCurrent:generation] || self.windowPresented || !self.window) return;
    self.windowPresented = YES;
    self.window.hidden = NO;
    NSLog(@"[TypeX][FloatingApp] card presented bundleID=%@ generation=%lu content=%d elapsed=%dms",
        self.session.bundleIdentifier, (unsigned long)generation, self.hasContent,
        (int)((CFAbsoluteTimeGetCurrent() - self.prepareStartedAt) * 1000));
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    BOOL layerObservation = context == DXFloatLayerObservation;
    if (!layerObservation && context != DXFloatContentObservation) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context]; return;
    }
    NSUInteger generation = self.session.generation;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self.session isCurrent:generation]) return;
        if (layerObservation ? object != self.layerManager : object != self.scene) return;
        // Preparing 期间图层/内容状态变化立即评估并完成恢复，轮询只作兜底；
        // Live 之后图层变化仍需刷新键盘等宿主视图。
        if (self.session.state != DXFloatingAppPreparing) {
            if (layerObservation) [self publishLayers];
            return;
        }
        [self evaluate:generation];
    });
}
// 采纳一个已解析的目标场景：前台化设置、运行断言、图层与内容观察一次到位。
// 失败分支内部已清理会话；返回 NO 表示会话已结束，调用方不得继续轮询。
- (BOOL)adoptScene:(id)scene pid:(pid_t)pid generation:(NSUInteger)generation {
    self.scene = scene; self.processPID = pid;
    self.originalSettings = DXFloatObject(DXFloatObject(scene, @"settings"), @"copy");
    self.activeLease = YES;
    id settings = DXFloatObject(scene, @"mutableSettings") ?: DXFloatObject(self.originalSettings, @"mutableCopy");
    @try {
        DXFloatForegroundSettings(settings, YES); DXFloatApplySettings(scene, settings);
    } @catch (__unused NSException *exception) { [self cleanup:DXSystemOpenFailed reason:@"scene-activation"]; return NO; }
    if (![self acquireAssertion]) { [self cleanup:DXSystemOpenUnavailable reason:@"assertion-unavailable"]; return NO; }
    self.layerManager = DXFloatObject(scene, @"layerManager");
    if (self.layerManager) {
        @try {
            [self.layerManager addObserver:self forKeyPath:@"layers" options:NSKeyValueObservingOptionNew context:DXFloatLayerObservation];
            self.observingLayers = YES;
        } @catch (__unused NSException *exception) {}
    }
    // contentState 不是保证 KVO 的公开属性：注册失败不影响流程，轮询兜底读取。
    @try {
        [scene addObserver:self forKeyPath:@"contentState" options:NSKeyValueObservingOptionNew context:DXFloatContentObservation];
        self.observingContent = YES;
    } @catch (__unused NSException *exception) {}
    NSLog(@"[TypeX][FloatingApp] scene acquired bundleID=%@ pid=%d generation=%lu", self.session.bundleIdentifier, pid, (unsigned long)generation);
    return YES;
}
// 一次就绪评估：采纳/校验场景、接力输入、发布图层并尽快完成恢复。
// open 的热路径、图层/内容观察与轮询 tick 共用，观察路径先于轮询完成。
- (BOOL)evaluate:(NSUInteger)generation {
    if (![self.session isCurrent:generation]) return NO;
    NSString *identifier = self.session.bundleIdentifier;
    pid_t pid = DXFloatPID(identifier);
    if (self.processPID > 0 && pid != self.processPID) { [self cleanup:DXSystemOpenUnavailable reason:@"process-ended"]; return NO; }
    if (!self.scene && pid > 0) {
        id scene = DXFloatFindScene(identifier);
        if (!scene && !self.sceneCreationAttempted && self.session.deadline.timeIntervalSinceNow < DXSystemOpenRequestTTL - 1.0) {
            self.sceneCreationAttempted = YES;
            scene = [self createDefaultSceneIfNeeded:identifier];
        }
        if (scene && ![self adoptScene:scene pid:pid generation:generation]) return NO;
    }
    if (self.scene && !DXFloatInteger(self.scene, @"isValid", YES)) { [self cleanup:DXSystemOpenUnavailable reason:@"scene-invalid"]; return NO; }
    if (self.scene) [self startInputRelay];
    [self publishLayers];
    if (self.hasContent && self.urlAccepted && self.session.state == DXFloatingAppPreparing) {
        NSLog(@"[TypeX][FloatingApp] live bundleID=%@ generation=%lu elapsed=%dms", identifier,
            (unsigned long)generation, (int)((CFAbsoluteTimeGetCurrent() - self.prepareStartedAt) * 1000));
        // Register only ready content; failed/expired preparations never consume a slot.
        if ([self shelfEnabled] || [self.shelf contains:identifier]) {
            [self.shelf activate:identifier title:self.controller.titleLabel.text];
            [self publishShelf];
        }
        [self.session publishLive:generation];
    }
    return YES;
}
- (void)poll:(NSUInteger)generation {
    if (![self.session isCurrent:generation]) return;
    if (![DXGlobalPanel deviceUnlocked]) { [self cleanup:DXSystemOpenUnavailable reason:@"locked"]; return; }
    if (self.session.hasExpired) { [self cleanup:DXSystemOpenTimedOut reason:@"content-timeout"]; return; }
    NSString *frontmost = DXFloatFrontmostIdentifier();
    if (![frontmost ?: @"" isEqual:self.baseIdentifier ?: @""]) {
        [self cleanup:DXSystemOpenUnavailable reason:@"native-takeover"]; return;
    }
    NSString *identifier = self.session.bundleIdentifier;
    pid_t pid = DXFloatPID(identifier);
    if (pid <= 0 && !self.loggedProcessWait && self.session.deadline.timeIntervalSinceNow < DXSystemOpenRequestTTL - 2.0) {
        self.loggedProcessWait = YES;
        NSLog(@"[TypeX][FloatingApp] waiting process bundleID=%@", identifier);
    }
    if ([self evaluate:generation]) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weakSelf poll:generation]; });
    }
}
@end

static void (*DXFloatOriginalSceneUpdate3)(id, SEL, id, id, id);
static void (*DXFloatOriginalSceneUpdate2)(id, SEL, id, id);
static void DXFloatSceneUpdate3(id scene, SEL selector, id settings, id context, id completion) {
    settings = [DXFloatingAppCoordinator.shared protectedSettings:settings scene:scene];
    DXFloatOriginalSceneUpdate3(scene, selector, settings, context, completion);
}
static void DXFloatSceneUpdate2(id scene, SEL selector, id settings, id context) {
    settings = [DXFloatingAppCoordinator.shared protectedSettings:settings scene:scene];
    DXFloatOriginalSceneUpdate2(scene, selector, settings, context);
}

// FrontBoard can enter the trusted workspace path after the FBS request. Limit
// this correction to our marked URL request; ordinary app and URL launches are
// never captured or redirected by TypeX's floating host.
static void (*DXFloatOriginalTrustedOpen)(id, SEL, id, id, id, id, id);
static void DXFloatTrustedOpen(id workspace, SEL selector, id application, id options, id activation, id origin, id result) {
    DXFloatingAppCoordinator *host = DXFloatingAppCoordinator.shared;
    NSDictionary *dictionary = [options isKindOfClass:NSDictionary.class] ? options : DXFloatObject(options, @"dictionary");
    if (NSThread.isMainThread && host.session.state == DXFloatingAppPreparing && host.requestedURL &&
        [DXFloatIdentifier(application) isEqual:host.session.bundleIdentifier] &&
        [dictionary[@"__TypeXFloatingGeneration"] unsignedIntegerValue] == host.session.generation) {
        @try {
            SEL description = NSSelectorFromString(@"keyDescriptionForSetting:");
            NSUInteger suspended = NSNotFound;
            if ([activation respondsToSelector:description]) {
                for (NSUInteger setting = 0; setting < 128; setting++) {
                    id key = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(activation, description, setting);
                    if ([key isKindOfClass:NSString.class] && [[(NSString *)key lowercaseString] isEqual:@"suspended"]) { suspended = setting; break; }
                }
            }
            SEL set = NSSelectorFromString(@"setBool:forActivationSetting:");
            if (suspended != NSNotFound && [activation respondsToSelector:set])
                ((void (*)(id, SEL, BOOL, NSUInteger))objc_msgSend)(activation, set, YES, suspended);
        } @catch (__unused NSException *exception) {}
    }
    DXFloatOriginalTrustedOpen(workspace, selector, application, options, activation, origin, result);
}

void DXStartFloatingAppHost(void) {
    if (!NSThread.isMainThread || ![NSProcessInfo.processInfo.processName isEqual:@"SpringBoard"]) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Load only in SpringBoard; don't add a private runtime dependency to
        // every keyboard host or extension which receives TypeX.dylib.
        dlopen("/System/Library/PrivateFrameworks/RunningBoardServices.framework/RunningBoardServices", RTLD_LAZY);
        typedef void (*DXHookMessage)(Class, SEL, IMP, IMP *);
        DXHookMessage hook = (DXHookMessage)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
        Class sceneClass = NSClassFromString(@"FBScene");
        SEL three = NSSelectorFromString(@"updateSettings:withTransitionContext:completion:");
        SEL two = NSSelectorFromString(@"updateSettings:withTransitionContext:");
        if (hook && class_getInstanceMethod(sceneClass, three)) hook(sceneClass, three, (IMP)DXFloatSceneUpdate3, (IMP *)&DXFloatOriginalSceneUpdate3);
        if (hook && class_getInstanceMethod(sceneClass, two)) hook(sceneClass, two, (IMP)DXFloatSceneUpdate2, (IMP *)&DXFloatOriginalSceneUpdate2);
        DXFloatHooksReady = DXFloatOriginalSceneUpdate3 || DXFloatOriginalSceneUpdate2;
        Class workspaceClass = NSClassFromString(@"SBMainWorkspace");
        SEL trusted = NSSelectorFromString(@"_handleTrustedOpenRequestForApplication:options:activationSettings:origin:withResult:");
        Method trustedMethod = class_getInstanceMethod(workspaceClass, trusted);
        if (hook && trustedMethod && method_getNumberOfArguments(trustedMethod) == 7)
            hook(workspaceClass, trusted, (IMP)DXFloatTrustedOpen, (IMP *)&DXFloatOriginalTrustedOpen);
        DXFloatingAppCoordinator *host = DXFloatingAppCoordinator.shared;
        host.shelf = [DXFloatingAppShelfState new];
        // Publish a locked, empty snapshot now without touching UIKit/SB state.
        // All private state queries wait for UIApplication's launch completion.
        __weak DXFloatingAppCoordinator *weakHost = host;
        host.shelfLaunchObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(__unused NSNotification *notification) {
                // Let the launch notification finish unwinding before asking SB managers.
                dispatch_async(dispatch_get_main_queue(), ^{ [weakHost finishShelfStartup]; });
            }];
        [host publishShelf];
        NSMutableArray *tokens = [NSMutableArray array];
        for (NSString *name in @[@"com.apple.springboard.lockstate", @"com.apple.springboard.hasBlankedScreen", @"com.apple.springboard.frontmostapplicationchanged", kPrefsChangedIdentifier]) {
            int token = NOTIFY_TOKEN_INVALID;
            if (notify_register_dispatch(name.UTF8String, &token, dispatch_get_main_queue(), ^(__unused int notificationToken) {
                if (!host.shelfStartupReady) return;
                if ([name isEqual:kPrefsChangedIdentifier]) { [host applyPreferencesChanged]; return; }
                if (host.session.state == DXFloatingAppIdle) { [host publishShelf]; return; }
                if ([name isEqual:@"com.apple.springboard.hasBlankedScreen"] || ![DXGlobalPanel deviceUnlocked])
                    [host cleanup:DXSystemOpenUnavailable reason:@"screen-locked"];
                else if ([name isEqual:@"com.apple.springboard.frontmostapplicationchanged"] &&
                    ![DXFloatFrontmostIdentifier() ?: @"" isEqual:host.baseIdentifier ?: @""])
                    [host cleanup:DXSystemOpenUnavailable reason:@"foreground-changed"];
            }) == NOTIFY_STATUS_OK) [tokens addObject:@(token)];
        }
        host.notifyTokens = tokens;
        NSLog(@"[TypeX][FloatingApp] host initialized sceneHooks=%d/%d", DXFloatOriginalSceneUpdate3 != NULL, DXFloatOriginalSceneUpdate2 != NULL);
    });
}

void DXPresentFloatingApplication(NSString *bundleIdentifier, NSURL *url, NSDate *deadline, DXSystemOpenReply reply) {
    if (!NSThread.isMainThread || ![NSProcessInfo.processInfo.processName isEqual:@"SpringBoard"]) { if (reply) reply(DXSystemOpenUnavailable); return; }
    DXStartFloatingAppHost();
    [DXFloatingAppCoordinator.shared open:bundleIdentifier url:url deadline:deadline reply:reply];
}

void DXRestoreFloatingAppFromShelf(NSString *identifier, uint64_t revision, NSDate *deadline, DXSystemOpenReply reply) {
    if (!NSThread.isMainThread || ![NSProcessInfo.processInfo.processName isEqual:@"SpringBoard"]) {
        if (reply) reply(DXSystemOpenUnavailable); return;
    }
    DXStartFloatingAppHost();
    DXFloatingAppCoordinator *host = DXFloatingAppCoordinator.shared;
    NSDictionary *snapshot = DXReadFloatingShelf();
    if (!host.shelfStartupReady || ![host shelfEnabled] || ![DXGlobalPanel deviceUnlocked] ||
        ![host.shelf contains:identifier] || [snapshot[@"revision"] unsignedLongLongValue] != revision) {
        if (reply) reply(DXSystemOpenExpired); return;
    }
    if (!DXFloatApplication(identifier)) {
        [host.shelf remove:identifier]; [host publishShelf];
        if (reply) reply(DXSystemOpenUnavailable); return;
    }
    NSLog(@"[TypeX][FloatingShelf] restore bundleID=%@", identifier);
    [host open:identifier url:nil deadline:deadline reply:reply];
}
