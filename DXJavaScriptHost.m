#import "DXJavaScriptHost.h"
#import "DXJavaScriptEngine.h"
#import "common.h"
#import <objc/runtime.h>

@interface DXJavaScriptChoiceWindow : UIWindow
@end
@implementation DXJavaScriptChoiceWindow
- (BOOL)canBecomeKeyWindow { return NO; }
@end

@interface DXJavaScriptHost ()
@property (nonatomic, strong) DXJavaScriptEngine *engine;
@property (nonatomic, weak) UIView *sourceView;
@property (nonatomic, weak) UIWindow *sourceWindow;
@property (nonatomic, weak) UIWindowScene *scene;
@property (nonatomic, weak) id<UITextInput> input;
@property (nonatomic, copy) id (^provider)(void);
@property (nonatomic, copy) void (^open)(NSString *, NSString *);
@property (nonatomic, copy) void (^error)(NSString *);
@property (nonatomic, copy) NSString *text;
@property (nonatomic, assign) NSRange selection;
@property (nonatomic, assign) NSRange replacement;
@property (nonatomic, copy) NSString *output;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) UIWindow *menuWindow;
@property (nonatomic, strong) UIScrollView *choiceScroll;
@property (nonatomic, strong) UIButton *choiceCancelButton;
@property (nonatomic, strong) NSArray *choices;
@property (nonatomic, strong) NSDate *started;
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, assign) BOOL clipboardInput;
@property (nonatomic, assign) NSInteger clipboardChange;
@end

static DXJavaScriptHost *DXActiveJavaScriptHost;

// Menu rows snap to whole heights so the panel edge never cuts through a
// label; the cap keeps large menus scrollable instead of covering the screen.
static const CGFloat DXJSChoiceRowHeight = 44.0;

// Always return menu-window coordinates, including when the keyboard belongs
// to a different window/scene. A full-screen input container is not a keyboard.
static CGRect DXJSProbeKeyboardFrame(UIWindow *window) {
    Class keyboardClass = objc_getClass("UIKeyboardImpl");
    if (!keyboardClass || ![keyboardClass respondsToSelector:@selector(activeInstance)]) return CGRectZero;
    @try {
        id instance = [keyboardClass performSelector:@selector(activeInstance)];
        if (![instance isKindOfClass:UIView.class]) return CGRectZero;
        UIView *keyboard = instance;
        if (!keyboard.window || keyboard.window.screen != window.screen) return CGRectZero;
        CGRect frame = [keyboard convertRect:keyboard.bounds toView:keyboard.window];
        frame = [keyboard.window convertRect:frame toWindow:window];
        if (CGRectIsNull(frame) || CGRectIsInfinite(frame) || CGRectGetHeight(frame) <= 10.0) return CGRectZero;
        if (CGRectGetMinY(frame) <= 0.0 || CGRectGetMinY(frame) >= CGRectGetHeight(window.bounds) - 10.0) return CGRectZero;
        return frame;
    } @catch (__unused NSException *exception) { return CGRectZero; }
}

@implementation DXJavaScriptHost
+ (void)cancelActive { [DXActiveJavaScriptHost cancel]; }
- (void)cancel {
    if (self.cancelled) return;
    self.cancelled = YES;
    [self.timer invalidate]; self.timer = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.engine cancel]; self.engine = nil;
    self.menuWindow.hidden = YES; self.menuWindow = nil; self.choices = nil;
    self.choiceScroll = nil; self.choiceCancelButton = nil;
    self.provider = nil; self.open = nil; self.error = nil;
    if (DXActiveJavaScriptHost == self) DXActiveJavaScriptHost = nil;
    NSLog(@"[MUBXJS] session closed");
}
- (void)fail:(NSString *)message {
    NSLog(@"[MUBXJS] session failed");
    void (^handler)(NSString *) = self.error;
    [self cancel];
    if (handler) handler(message);
}
- (void)interrupted:(NSNotification *)notification { (void)notification; [self cancel]; }
- (void)inputChanged:(NSNotification *)notification {
    if (notification.object == self.input) [self cancel];
}
- (BOOL)readInputText:(NSString **)text range:(NSRange *)range {
    id<UITextInput> input = self.input;
    for (NSString *name in @[@"beginningOfDocument", @"endOfDocument", @"selectedTextRange", @"textRangeFromPosition:toPosition:",
        @"textInRange:", @"offsetFromPosition:toPosition:", @"positionFromPosition:offset:", @"replaceRange:withText:"]) {
        if (![input respondsToSelector:NSSelectorFromString(name)]) return NO;
    }
    @try {
        if ([input respondsToSelector:@selector(isSecureTextEntry)] && [(id<UITextInputTraits>)input isSecureTextEntry]) return NO;
        if ([input respondsToSelector:@selector(markedTextRange)] && input.markedTextRange) return NO;
        UITextRange *selected = input.selectedTextRange;
        UITextPosition *begin = input.beginningOfDocument;
        UITextRange *whole = [input textRangeFromPosition:begin toPosition:input.endOfDocument];
        if (!selected || !whole) return NO;
        NSString *value = [input textInRange:whole];
        NSInteger start = [input offsetFromPosition:begin toPosition:selected.start];
        NSInteger end = [input offsetFromPosition:begin toPosition:selected.end];
        if (![value isKindOfClass:NSString.class] || value.length > 1024 * 1024 || start < 0 || end < start || (NSUInteger)end > value.length) return NO;
        *text = value; *range = NSMakeRange((NSUInteger)start, (NSUInteger)(end - start));
        return YES;
    } @catch (__unused NSException *exception) { return NO; }
}
- (BOOL)valid {
    if (self.cancelled || !self.sourceWindow || self.sourceWindow.hidden || !self.sourceView ||
        self.sourceView.window != self.sourceWindow || self.sourceView.hidden ||
        !self.input || self.provider() != self.input) return NO;
    for (UIView *view = self.sourceView; view; view = view.superview) {
        if (view.hidden || view.alpha <= 0.01) return NO;
    }
    if (self.scene && self.scene.activationState != UISceneActivationStateForegroundActive) return NO;
    if (self.clipboardInput && UIPasteboard.generalPasteboard.changeCount != self.clipboardChange) return NO;
    NSString *text = nil; NSRange range;
    return [self readInputText:&text range:&range] && [text isEqual:self.text] && NSEqualRanges(range, self.selection);
}
- (void)tick {
    if (![self valid] || -[self.started timeIntervalSinceNow] > 120) [self cancel];
    else if (self.menuWindow) [self layoutChoices];
}
+ (void)startEntry:(NSDictionary *)entry sourceView:(UIView *)view inputProvider:(id (^)(void))provider
             open:(void (^)(NSString *, NSString *))open error:(void (^)(NSString *))error {
    [self cancelActive];
    DXJavaScriptHost *host = [self new];
    host.sourceView = view; host.sourceWindow = view.window;
    host.provider = provider; host.input = provider(); host.open = open; host.error = error;
    UIView *inputView = [(id)host.input isKindOfClass:UIView.class] ? (UIView *)host.input : nil;
    host.scene = inputView.window.windowScene ?: view.window.windowScene;
    id inputMode = entry[@"jsInput"] ?: @"auto";
    id outputMode = entry[@"jsOutput"] ?: @"replace";
    if (![@[@"auto", @"all", @"clipboard"] containsObject:inputMode] ||
        ![@[@"replace", @"insert", @"copy"] containsObject:outputMode]) {
        [host fail:@"Invalid JavaScript action configuration"]; return;
    }
    host.output = outputMode;
    NSString *text = nil; NSRange range;
    if (![host readInputText:&text range:&range] || !view.window) {
        [host fail:NSLocalizedStringFromTableInBundle(@"JS_INPUT_UNAVAILABLE", nil, [NSBundle bundleWithPath:bundlePath], nil)]; return;
    }
    host.text = text; host.selection = range;
    NSString *mode = inputMode;
    host.replacement = [mode isEqual:@"all"] || !range.length ? NSMakeRange(0, text.length) : range;
    NSString *input = [text substringWithRange:host.replacement];
    if ([mode isEqual:@"clipboard"]) {
        host.clipboardInput = YES;
        input = UIPasteboard.generalPasteboard.string ?: @"";
        host.clipboardChange = UIPasteboard.generalPasteboard.changeCount;
        host.replacement = range;
    }
    host.started = [NSDate date]; host.engine = [DXJavaScriptEngine new];
    __weak DXJavaScriptHost *weakHost = host;
    host.engine.actionHandler = ^(NSDictionary *action) { [weakHost execute:action]; };
    host.engine.resultHandler = ^(NSArray *actions, NSError *failure) {
        DXJavaScriptHost *current = weakHost;
        if (!current || current.cancelled) return;
        if (![current valid]) { [current cancel]; return; }
        if (failure) { [current fail:failure.localizedDescription]; return; }
        if (!actions.count) [current cancel];
        else if (actions.count == 1) [current execute:actions.firstObject];
        else [current showChoices:actions];
    };
    DXActiveJavaScriptHost = host;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSString *name in @[UIKeyboardWillHideNotification, UIApplicationWillResignActiveNotification,
        UIDeviceOrientationDidChangeNotification]) [center addObserver:host selector:@selector(interrupted:) name:name object:nil];
    for (NSString *name in @[UITextFieldTextDidChangeNotification, UITextViewTextDidChangeNotification])
        [center addObserver:host selector:@selector(inputChanged:) name:name object:nil];
    host.timer = [NSTimer timerWithTimeInterval:0.15 repeats:YES block:^(__unused NSTimer *timer) {
        DXJavaScriptHost *current = weakHost;
        [current tick];
    }];
    [NSRunLoop.mainRunLoop addTimer:host.timer forMode:NSRunLoopCommonModes];
    NSLog(@"[MUBXJS] session started");
    [host.engine runSource:[entry[@"script"] isKindOfClass:NSString.class] ? entry[@"script"] : @"" input:input];
}
- (void)execute:(NSDictionary *)action {
    // Terminal actions clear the global owner; keep the receiver alive through
    // UIKit's replacement (which can throw or synchronously post notifications).
    __attribute__((objc_precise_lifetime)) DXJavaScriptHost *keepAlive = self;
    (void)keepAlive;
    if (![self valid]) { [self cancel]; return; }
    self.menuWindow.hidden = YES; self.menuWindow = nil; self.choices = nil;
    self.choiceScroll = nil; self.choiceCancelButton = nil;
    NSString *type = action[@"type"], *content = action[@"content"];
    if ([type isEqual:@"function"]) { [self.engine callFunction:content arguments:action[@"args"]]; return; }
    if (![@[@"txt", @"url", @"urlInApp", @"app"] containsObject:type]) { [self fail:@"Unsupported action type"]; return; }
    if (![type isEqual:@"txt"]) {
        if (([type isEqual:@"app"] && !DXIsValidBundleIdentifier(content)) ||
            (![type isEqual:@"app"] && !DXIsOpenableSchemeURLString(content))) { [self fail:@"Invalid URL or application identifier"]; return; }
        void (^open)(NSString *, NSString *) = self.open;
        // Commit one navigation, close the session before it changes focus.
        // Pending returns/callbacks cannot cause a second open or insertion.
        [self cancel];
        if (open) open(type, content);
        return;
    }
    if ([self.output isEqual:@"copy"]) { [self cancel]; UIPasteboard.generalPasteboard.string = content; return; }
    id<UITextInput> input = self.input;
    void (^errorHandler)(NSString *) = self.error;
    NSRange range = [self.output isEqual:@"insert"] ? self.selection : self.replacement;
    @try {
        UITextPosition *start = [input positionFromPosition:input.beginningOfDocument offset:(NSInteger)range.location];
        UITextPosition *end = [input positionFromPosition:start offset:(NSInteger)range.length];
        UITextRange *target = start && end ? [input textRangeFromPosition:start toPosition:end] : nil;
        if (!target) { [self fail:@"Input range is no longer available"]; return; }
        [self cancel];
        [input replaceRange:target withText:content];
    } @catch (__unused NSException *exception) {
        [self cancel];
        if (errorHandler) errorHandler(@"Unable to replace input text");
    }
}
- (void)choiceTapped:(UIButton *)sender {
    if (sender.tag < 0 || (NSUInteger)sender.tag >= self.choices.count) return;
    [self execute:self.choices[(NSUInteger)sender.tag]];
}
- (void)layoutChoices {
    UIWindow *window = self.menuWindow;
    if (!window || self.cancelled) return;
    UIView *inputView = [(id)self.input isKindOfClass:UIView.class] ? (UIView *)self.input : nil;
    CGFloat topInset = MAX(window.safeAreaInsets.top, MAX(inputView.window.safeAreaInsets.top,
                                                        self.sourceWindow.safeAreaInsets.top)) + 12.0;
    CGFloat screenHeight = CGRectGetHeight(window.bounds);
    CGFloat anchorY = CGFLOAT_MAX;
    CGRect keyboardFrame = DXJSProbeKeyboardFrame(window);
    if (!CGRectIsEmpty(keyboardFrame) && CGRectGetMinY(keyboardFrame) > topInset)
        anchorY = CGRectGetMinY(keyboardFrame);

    // The bottom toolbar is inside the keyboard. Its wide ancestors expose
    // the keyboard's upper edge even when UIKeyboardImpl is a full-screen
    // container. The top toolbar itself can be above that edge.
    UIWindow *sourceWindow = self.sourceWindow;
    for (UIView *view = self.sourceView; view && view != sourceWindow; view = view.superview) {
        CGRect frame = [view convertRect:view.bounds toView:sourceWindow];
        frame = [sourceWindow convertRect:frame toWindow:window];
        if (CGRectIsNull(frame) || CGRectIsInfinite(frame) || CGRectIsEmpty(frame)) continue;
        CGFloat y = CGRectGetMinY(frame);
        if ((view == self.sourceView || CGRectGetWidth(frame) >= CGRectGetWidth(window.bounds) * 0.72) &&
            y > topInset && y < screenHeight - 10.0) anchorY = MIN(anchorY, y);
    }
    // If neither hierarchy yields an edge, keep the panel in the upper half
    // instead of reverting to the screen bottom underneath a remote keyboard.
    if (anchorY == CGFLOAT_MAX) anchorY = topInset + (screenHeight - topInset) * 0.5;
    CGFloat bottomLimit = MIN(anchorY - 10.0, screenHeight - window.safeAreaInsets.bottom - 10.0);
    CGFloat gap = 8.0;
    CGFloat available = bottomLimit - topInset;
    if (available < DXJSChoiceRowHeight * 2 + gap) {
        [self fail:@"Not enough space above the keyboard for script choices"]; return;
    }
    CGFloat width = MIN(360.0, CGRectGetWidth(window.bounds) - 32.0);
    CGFloat cap = floor((available - gap - DXJSChoiceRowHeight) / DXJSChoiceRowHeight) * DXJSChoiceRowHeight;
    CGFloat itemsHeight = MIN(self.choices.count * DXJSChoiceRowHeight, cap);
    CGRect frame = CGRectMake((CGRectGetWidth(window.bounds) - width) / 2,
                              bottomLimit - itemsHeight - gap - DXJSChoiceRowHeight, width, itemsHeight);
    if (!CGRectEqualToRect(self.choiceScroll.frame, frame)) {
        self.choiceScroll.frame = frame;
        NSLog(@"[MUBXJS] choices layout rows=%lu top=%.1f bottom=%.1f anchor=%.1f level=%.0f",
              (unsigned long)self.choices.count, frame.origin.y, bottomLimit, anchorY, window.windowLevel);
    }
    self.choiceScroll.contentSize = CGSizeMake(width, self.choices.count * DXJSChoiceRowHeight);
    self.choiceScroll.alwaysBounceVertical = self.choiceScroll.contentSize.height > itemsHeight;
    self.choiceCancelButton.frame = CGRectMake(frame.origin.x, CGRectGetMaxY(frame) + gap, width, DXJSChoiceRowHeight);
}
- (void)showChoices:(NSArray *)choices {
    if (![self valid]) { [self cancel]; return; }
    UIWindowScene *scene = self.scene;
    if (!scene || scene.activationState != UISceneActivationStateForegroundActive) { [self fail:@"No active scene for script choices"]; return; }
    self.choices = choices;
    DXJavaScriptChoiceWindow *window = [[DXJavaScriptChoiceWindow alloc] initWithWindowScene:scene];
    window.frame = scene.coordinateSpace.bounds;
    window.windowLevel = MAX(1000000.0, self.sourceWindow.windowLevel + 1);
    for (UIWindow *candidate in scene.windows) {
        if (candidate != window && candidate != self.menuWindow && !candidate.hidden)
            window.windowLevel = MAX(window.windowLevel, candidate.windowLevel + 1);
    }
    UIViewController *controller = [UIViewController new];
    window.rootViewController = controller;
    UIControl *backdrop = [[UIControl alloc] initWithFrame:window.bounds];
    backdrop.backgroundColor = [UIColor colorWithWhite:0 alpha:0.18];
    backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [backdrop addTarget:self action:@selector(cancel) forControlEvents:UIControlEventTouchUpInside];
    [controller.view addSubview:backdrop];
    // Action-sheet look: choices sit as full-width cells inside one rounded
    // block split by hairlines, cancel is bold in its own block below. The
    // list scrolls in the space above the keyboard; cancel stays accessible
    // below it. Layout uses all available height up to the top safe area.
    CGFloat hairline = 1.0 / UIScreen.mainScreen.scale;
    CGFloat width = MIN(360, CGRectGetWidth(window.bounds) - 32);
    UIScrollView *scroll = [UIScrollView new];
    scroll.backgroundColor = UIColor.clearColor;
    scroll.layer.cornerRadius = 14;
    scroll.clipsToBounds = YES;
    scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [backdrop addSubview:scroll];
    NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
    UIView *itemsBlock = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, choices.count * DXJSChoiceRowHeight)];
    itemsBlock.backgroundColor = UIColor.secondarySystemBackgroundColor;
    itemsBlock.layer.cornerRadius = 14;
    itemsBlock.clipsToBounds = YES;
    [scroll addSubview:itemsBlock];
    for (NSUInteger index = 0; index < choices.count; index++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.frame = CGRectMake(0, index * DXJSChoiceRowHeight, width, DXJSChoiceRowHeight);
        button.tag = (NSInteger)index;
        button.titleLabel.numberOfLines = 2;
        button.titleLabel.font = [UIFont systemFontOfSize:15];
        NSString *title = choices[index][@"title"];
        [button setTitle:title.length ? title : @"∅" forState:UIControlStateNormal];
        [button addTarget:self action:@selector(choiceTapped:) forControlEvents:UIControlEventTouchUpInside];
        [itemsBlock addSubview:button];
        if (index) {
            UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, index * DXJSChoiceRowHeight, width, hairline)];
            line.backgroundColor = UIColor.separatorColor;
            [itemsBlock addSubview:line];
        }
    }
    UIButton *cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    cancelButton.backgroundColor = UIColor.secondarySystemBackgroundColor;
    cancelButton.layer.cornerRadius = 14;
    cancelButton.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [cancelButton setTitle:NSLocalizedStringFromTableInBundle(@"ANSWER_CANCEL", nil, bundle, nil) forState:UIControlStateNormal];
    [cancelButton addTarget:self action:@selector(cancel) forControlEvents:UIControlEventTouchUpInside];
    [backdrop addSubview:cancelButton];
    self.menuWindow.hidden = YES;
    self.menuWindow = window;
    self.choiceScroll = scroll;
    self.choiceCancelButton = cancelButton;
    [self layoutChoices];
    if (self.cancelled) return;
    window.hidden = NO; // Never make key or resign the input responder.
    [self layoutChoices]; // Refresh safe-area insets once the window is visible.
}
@end
