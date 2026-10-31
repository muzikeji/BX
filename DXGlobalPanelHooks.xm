#import "DXGlobalPanel.h"
#import "DXGlobalPanelPolicy.h"
#import "DXDockPanelTouchPolicy.h"
#import "DXDockGesturePolicy.h"
#import "DXGlobalActionExecutor.h"
#import "DXKeyboardPanelPreferences.h"
#import "DXPanelRegistry.h"
#import "common.h"
#import <objc/runtime.h>

static char DXDockPanelHandlerKey;
static char DXDockRecognizerKey;
static NSHashTable *DXDockGestureHandlers;
static void DXTryInstallGlobalPanelHooks(void);

@interface DXDockPanelGestureHandler : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, weak) UIView *dock;
@property(nonatomic, weak) UIWindow *sourceWindow;
@property(nonatomic, weak) UIWindow *installedWindow;
@property(nonatomic, strong) UIPanGestureRecognizer *pan;
@property(nonatomic, copy) NSDictionary *snapshot;
@property(nonatomic, copy) NSString *direction;
@property(nonatomic, assign) CGRect sourceFrame;
@property(nonatomic, assign) CGRect sourceBounds;
@property(nonatomic, assign) NSUInteger generation;
@property(nonatomic, assign) BOOL opened;
@property(nonatomic, assign) BOOL loggedRejectedTouch;
- (BOOL)available;
- (BOOL)hasAction:(NSString *)direction preferences:(NSDictionary *)preferences;
- (BOOL)validSession;
- (void)clearSession;
- (void)invalidated:(NSNotification *)notification;
- (void)dockPan:(UIPanGestureRecognizer *)gesture;
@end

@implementation DXDockPanelGestureHandler
- (instancetype)init {
    if ((self = [super init])) {
        for (NSString *name in @[UIApplicationWillResignActiveNotification, UISceneWillDeactivateNotification,
            UIDeviceOrientationDidChangeNotification, @"mubXLayoutChanged"])
            [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(invalidated:) name:name object:nil];
    }
    return self;
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    UIWindow *window = _installedWindow;
    UIPanGestureRecognizer *pan = _pan;
    if (!window || !pan) return;
    void (^remove)(void) = ^{ pan.enabled = NO; if (pan.view == window) [window removeGestureRecognizer:pan]; };
    if (NSThread.isMainThread) remove(); else dispatch_async(dispatch_get_main_queue(), remove);
}
- (void)clearSession {
    self.sourceWindow = nil; self.snapshot = nil; self.direction = nil; self.opened = NO;
}
- (void)invalidated:(NSNotification *)notification {
    (void)notification;
    if (!NSThread.isMainThread) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf invalidated:nil]; });
        return;
    }
    self.generation++;
    [self clearSession];
}
- (BOOL)available {
    DXPrefsManager *manager = DXPrefsManager.sharedInstance;
    if (!NSThread.isMainThread || !manager.preferencesAvailable || !self.dock.window || self.dock.window != self.installedWindow ||
        !DXDockPanelViewVisible(self.dock, self.installedWindow) ||
        [[DXGlobalPanel sharedInstance] isVisible] || ![DXGlobalPanel deviceUnlocked]) return NO;
    UIWindowScene *scene = self.dock.window.windowScene;
    if (scene && scene.activationState != UISceneActivationStateForegroundActive) return NO;
    CGRect frame = [self.dock convertRect:self.dock.bounds toView:self.dock.window];
    if (CGRectIsNull(frame) || CGRectIsInfinite(frame) || CGRectIsEmpty(CGRectIntersection(frame, self.dock.window.bounds))) return NO;
    return DXKeyboardPanelBool(manager.prefs, kEnabledkey, YES);
}
- (BOOL)hasAction:(NSString *)direction preferences:(NSDictionary *)preferences {
    NSString *selector = DXDockGestureSelector(preferences, direction);
    if (DXPanelAllowed(preferences, selector, DXPanelGestureKind)) return DXKeyboardPanelBool(preferences, kDXPanelGlobalEnabled, YES);
    return DXIsLinkActionSelector(selector) && DXGlobalCustomActionSupported(DXDockGestureDefinition(preferences, selector, kLinkActionskey));
}
- (BOOL)validSession {
    return self.snapshot && self.sourceWindow && [self available] && self.sourceWindow == self.dock.window &&
        [self.snapshot isEqual:DXPrefsManager.sharedInstance.prefs] &&
        CGRectEqualToRect(self.sourceFrame, [self.dock convertRect:self.dock.bounds toView:self.sourceWindow]) &&
        CGRectEqualToRect(self.sourceBounds, self.sourceWindow.bounds);
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    if (!NSThread.isMainThread || gesture != self.pan) return NO;
    // A second finger invalidates the first finger's pending action as well.
    if (self.snapshot && self.pan.numberOfTouches > 0) { [self invalidated:nil]; return NO; }
    [self invalidated:nil];
    UIWindow *window = self.dock.window;
    if (window != self.installedWindow || touch.window != window) return NO;
    CGPoint point = [touch locationInView:window];
    CGRect frame = [self.dock convertRect:self.dock.bounds toView:window];
    CGFloat below = MAX(0, CGRectGetMaxY(window.bounds) - CGRectGetMaxY(frame));
    if (!DXDockPanelOriginAllowed(point.x - frame.origin.x, point.y - frame.origin.y, frame.size.width, frame.size.height, below)) return NO;
    if (!DXDockPanelTouchIsBackground(self.dock, touch.view, point)) {
        if (!self.loggedRejectedTouch) {
            self.loggedRejectedTouch = YES;
            NSLog(@"[MUBX][DockGesture] rejected icon/control hit=%@", NSStringFromClass(touch.view.class));
        }
        return NO;
    }
    if (![self available]) return NO;
    NSDictionary *preferences = DXPrefsManager.sharedInstance.prefs;
    BOOL active = NO;
    for (NSString *direction in DXDockGestureDirections()) active |= [self hasAction:direction preferences:preferences];
    if (!active) return NO;
    self.sourceWindow = self.dock.window;
    self.snapshot = [preferences copy]; self.sourceFrame = frame; self.sourceBounds = window.bounds;
    NSLog(@"[MUBX][DockGesture] tracking request=%lu zone=%@ hit=%@", (unsigned long)self.generation,
        point.y > CGRectGetMaxY(frame) ? @"below" : @"inside", NSStringFromClass(touch.view.class));
    return YES;
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    if (recognizer != self.pan || ![self validSession]) { [self invalidated:nil]; return NO; }
    UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)recognizer;
    CGPoint delta = [pan translationInView:self.sourceWindow];
    if (CGPointEqualToPoint(delta, CGPointZero)) delta = [pan velocityInView:self.sourceWindow];
    NSString *direction = DXDockGestureDirection(delta.x, delta.y);
    if (![self hasAction:direction preferences:self.snapshot]) { [self invalidated:nil]; return NO; }
    self.direction = direction;
    return YES;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    // A configured Dock gesture owns this background touch. In particular,
    // opening a panel must not also start SpringBoard's upward transition.
    // Disabled/unassigned directions still fail in ShouldBegin.
    if (!NSThread.isMainThread || ![self validSession]) return NO;
    BOOL active = NO;
    for (NSString *direction in DXDockGestureDirections()) active |= [self hasAction:direction preferences:self.snapshot];
    return gesture == self.pan && !objc_getAssociatedObject(other, &DXDockRecognizerKey) &&
        [other isKindOfClass:UIPanGestureRecognizer.class] && ![other isKindOfClass:UIScreenEdgePanGestureRecognizer.class] &&
        active;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    (void)gesture; (void)other;
    return NO;
}
- (void)dockPan:(UIPanGestureRecognizer *)gesture {
    if (!NSThread.isMainThread || gesture != self.pan) return;
    if (gesture.state == UIGestureRecognizerStateCancelled || gesture.state == UIGestureRecognizerStateFailed) {
        if (self.sourceWindow && !self.opened) NSLog(@"[MUBX][DockGesture] cancelled request=%lu state=%ld", (unsigned long)self.generation, (long)gesture.state);
        [self invalidated:nil]; return;
    }
    if (gesture.state == UIGestureRecognizerStateEnded &&
        !self.opened && [self validSession] && [self hasAction:self.direction preferences:self.snapshot]) {
        CGPoint delta = [gesture translationInView:self.sourceWindow];
        NSString *selector = DXDockGestureSelector(self.snapshot, self.direction);
        BOOL isPanel = DXPanelAllowed(self.snapshot, selector, DXPanelGestureKind);
        if (DXDockGestureCompletes(self.direction, delta.x, delta.y)) {
            self.opened = YES;
            NSString *direction = self.direction;
            NSUInteger request = self.generation;
            NSLog(@"[MUBX][DockGesture] trigger request=%lu direction=%@ panel=%d", (unsigned long)request, direction, isPanel);
            if (isPanel) {
                NSDictionary *snapshot = self.snapshot;
                CGRect frame = self.sourceFrame, bounds = self.sourceBounds;
                __weak typeof(self) weakSelf = self;
                __weak UIWindow *source = self.sourceWindow;
                // Finish UIKit's source-window touch delivery before installing
                // the dismiss controls in a new window. A new touch/transition
                // invalidates this request rather than reopening stale UI.
                dispatch_async(dispatch_get_main_queue(), ^{
                    DXDockPanelGestureHandler *handler = weakSelf;
                    UIWindow *window = source;
                    BOOL current = handler && handler.generation == request && window && [handler available] &&
                        handler.dock.window == window && [snapshot isEqual:DXPrefsManager.sharedInstance.prefs] &&
                        CGRectEqualToRect(frame, [handler.dock convertRect:handler.dock.bounds toView:window]) &&
                        CGRectEqualToRect(bounds, window.bounds) && [handler hasAction:direction preferences:snapshot];
                    if (!current) {
                        NSLog(@"[MUBX][DockGesture] presentation cancelled request=%lu", (unsigned long)request);
                        return;
                    }
                    [DXGlobalPanel.sharedInstance presentPanelSelector:selector fromWindow:window origin:@"dockgesture"];
                });
            } else {
                NSDictionary *snapshot = self.snapshot;
                __weak typeof(self) weakSelf = self;
                __weak UIWindow *source = self.sourceWindow;
                DXExecuteGlobalCustomAction(DXDockGestureDefinition(snapshot, selector, kLinkActionskey), ^(DXSystemOpenResult result) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        DXDockPanelGestureHandler *handler = weakSelf;
                        BOOL current = handler && handler.generation == request && source && handler.dock.window == source &&
                            [handler available] && [snapshot isEqual:DXPrefsManager.sharedInstance.prefs];
                        NSLog(@"[MUBX][DockGesture] result request=%lu direction=%@ status=%llu current=%d",
                            (unsigned long)request, direction, (unsigned long long)result, current);
                    });
                });
            }
        }
    }
    if (gesture.state == UIGestureRecognizerStateEnded) [self clearSession];
}
@end

static void DXInstallDockPanelGesture(UIView *dock) {
    if (!NSThread.isMainThread) return;
    DXDockPanelGestureHandler *handler = objc_getAssociatedObject(dock, &DXDockPanelHandlerKey);
    if (handler && handler.installedWindow == dock.window && handler.pan.view == dock.window) return;
    [handler invalidated:nil];
    handler.pan.enabled = NO;
    if (handler.pan && handler.pan.view == handler.installedWindow) [handler.installedWindow removeGestureRecognizer:handler.pan];
    handler.pan = nil;
    handler.installedWindow = nil;
    if (!dock.window) {
        objc_setAssociatedObject(dock, &DXDockPanelHandlerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    handler = [DXDockPanelGestureHandler new];
    handler.dock = dock;
    handler.installedWindow = dock.window;
    if (!DXDockGestureHandlers) DXDockGestureHandlers = [NSHashTable weakObjectsHashTable];
    [DXDockGestureHandlers addObject:handler];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:handler action:@selector(dockPan:)];
    pan.minimumNumberOfTouches = 1;
    pan.maximumNumberOfTouches = 1;
    pan.cancelsTouchesInView = YES;
    pan.delaysTouchesBegan = NO;
    pan.delegate = handler;
    handler.pan = pan;
    objc_setAssociatedObject(pan, &DXDockRecognizerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(dock, &DXDockPanelHandlerKey, handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [dock.window addGestureRecognizer:pan];
    NSLog(@"[MUBX][DockGesture] installed directions=up,left,right class=%@ window=%@", NSStringFromClass(dock.class), NSStringFromClass(dock.window.class));
}

%group MUBXGlobalDock
%hook SBDockView
- (void)didMoveToWindow {
    %orig;
    DXInstallDockPanelGesture((UIView *)self);
}
%end
%end

%group MUBXGlobalTransition
%hook SBMainSwitcherControllerCoordinator
- (void)layoutStateTransitionCoordinator:(id)coordinator transitionDidBeginWithTransitionContext:(id)context {
    for (DXDockPanelGestureHandler *handler in DXDockGestureHandlers.allObjects) [handler invalidated:nil];
    [[DXGlobalPanel sharedInstance] systemTransitionBegan];
    %orig;
}
%end
%end

%group MUBXGlobalLaunch
%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    // SpringBoardHome classes can be loaded after tweak constructors run.
    DXTryInstallGlobalPanelHooks();
}
%end
%end

static void DXTryInstallGlobalPanelHooks(void) {
    if (!NSThread.isMainThread) return;
    static BOOL dockInstalled = NO, transitionInstalled = NO;
    Class dock = NSClassFromString(@"SBDockView");
    if (!dockInstalled && !dock) NSLog(@"[MUBX][GlobalPanel] dock hook pending: SBDockView unavailable");
    if (!dockInstalled && [dock instancesRespondToSelector:@selector(didMoveToWindow)]) {
        %init(MUBXGlobalDock, SBDockView = dock);
        dockInstalled = YES;
        // Also cover a Dock that had already joined its window before hooks.
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithArray:UIApplication.sharedApplication.windows ?: @[]];
        #pragma clang diagnostic pop
        while (pending.count) {
            UIView *view = pending.lastObject;
            [pending removeLastObject];
            if ([view isKindOfClass:dock]) DXInstallDockPanelGesture(view);
            else [pending addObjectsFromArray:view.subviews];
        }
    }
    Class transition = NSClassFromString(@"SBMainSwitcherControllerCoordinator");
    SEL selector = NSSelectorFromString(@"layoutStateTransitionCoordinator:transitionDidBeginWithTransitionContext:");
    Method method = class_getInstanceMethod(transition, selector);
    if (!transitionInstalled && method) {
        NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
        if (signature.numberOfArguments == 4 && !strcmp(signature.methodReturnType, @encode(void)) &&
            !strcmp([signature getArgumentTypeAtIndex:2], "@") && !strcmp([signature getArgumentTypeAtIndex:3], "@")) {
            %init(MUBXGlobalTransition, SBMainSwitcherControllerCoordinator = transition);
            transitionInstalled = YES;
        }
    }
}

%ctor {
    @autoreleasepool {
        if (![NSProcessInfo.processInfo.processName isEqual:@"SpringBoard"]) return;
        DXTryInstallGlobalPanelHooks();
        dispatch_async(dispatch_get_main_queue(), ^{ DXTryInstallGlobalPanelHooks(); });
        Class springBoard = NSClassFromString(@"SpringBoard");
        Method method = class_getInstanceMethod(springBoard, NSSelectorFromString(@"applicationDidFinishLaunching:"));
        if (method) {
            NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
            if (signature.numberOfArguments == 3 && !strcmp(signature.methodReturnType, @encode(void)) &&
                !strcmp([signature getArgumentTypeAtIndex:2], "@")) {
                %init(MUBXGlobalLaunch, SpringBoard = springBoard);
            }
        }
    }
}
