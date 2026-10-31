#import "DXFloatingAppInput.h"
#import <UIKit/UIKit.h>
#import <notify.h>
#import <objc/message.h>
#include <unistd.h>
#include <string.h>

// Scene-hosted touches are delivered to the target process, not the host card's
// UIKit gesture tree. Observe them in that app's own window and relay only scale.
@interface DXFloatingAppInputClient : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic) int sessionToken;
@property(nonatomic) int inputToken;
@property(nonatomic) int sceneToken;
@property(nonatomic) uint64_t sceneHash;
@property(nonatomic) uint32_t nonce;
@property(nonatomic) uint32_t gestureNonce;
@property(nonatomic) uint8_t gestureSerial;
@property(nonatomic, strong) NSMapTable<UIWindow *, UIPinchGestureRecognizer *> *gestures;
- (void)refresh;
@end

@implementation DXFloatingAppInputClient
- (instancetype)init {
    if ((self = [super init])) {
        _sessionToken = _inputToken = _sceneToken = NOTIFY_TOKEN_INVALID;
        _gestures = [NSMapTable weakToStrongObjectsMapTable];
    }
    return self;
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (_sessionToken != NOTIFY_TOKEN_INVALID) notify_cancel(_sessionToken);
    if (_inputToken != NOTIFY_TOKEN_INVALID) notify_cancel(_inputToken);
    if (_sceneToken != NOTIFY_TOKEN_INVALID) notify_cancel(_sceneToken);
}
- (BOOL)matchesWindow:(UIWindow *)window {
    id scene = window.windowScene;
    SEL selector = NSSelectorFromString(@"_sceneIdentifier");
    NSMethodSignature *signature = [scene methodSignatureForSelector:selector];
    if (![scene respondsToSelector:selector] || signature.numberOfArguments != 2 ||
        strcmp(signature.methodReturnType, "@")) return NO;
    @try {
        id identifier = ((id (*)(id, SEL))objc_msgSend)(scene, selector);
        return self.sceneHash && DXFloatInputSceneHash(identifier) == self.sceneHash;
    } @catch (__unused NSException *exception) { return NO; }
}
- (BOOL)isCurrent {
    uint64_t word = 0;
    return self.nonce && self.sessionToken != NOTIFY_TOKEN_INVALID &&
        notify_get_state(self.sessionToken, &word) == NOTIFY_STATUS_OK &&
        word == DXFloatInputSessionWord((uint32_t)getpid(), self.nonce);
}
- (void)refresh {
    uint64_t word = 0;
    if (self.sessionToken != NOTIFY_TOKEN_INVALID) notify_get_state(self.sessionToken, &word);
    uint32_t nonce = (uint32_t)word == (uint32_t)getpid() ? (uint32_t)(word >> 32) : 0;
    if (nonce != self.nonce) {
        // Clear identity before disabling gestures: cancellation must not emit
        // a scale for a revoked or replacement session.
        self.nonce = 0; self.gestureNonce = 0; self.sceneHash = 0;
        for (UIWindow *window in self.gestures.keyEnumerator) {
            [window removeGestureRecognizer:[self.gestures objectForKey:window]];
        }
        [self.gestures removeAllObjects];
        if (self.inputToken != NOTIFY_TOKEN_INVALID) notify_cancel(self.inputToken);
        if (self.sceneToken != NOTIFY_TOKEN_INVALID) notify_cancel(self.sceneToken);
        self.inputToken = NOTIFY_TOKEN_INVALID;
        self.sceneToken = NOTIFY_TOKEN_INVALID;
        if (nonce && notify_register_check(DXFloatInputName((uint32_t)getpid()).UTF8String, &_inputToken) == NOTIFY_STATUS_OK &&
            notify_register_check(DXFloatInputSceneName((uint32_t)getpid()).UTF8String, &_sceneToken) == NOTIFY_STATUS_OK &&
            notify_get_state(self.sceneToken, &_sceneHash) == NOTIFY_STATUS_OK && self.sceneHash) self.nonce = nonce;
        if (!self.nonce) {
            if (self.inputToken != NOTIFY_TOKEN_INVALID) notify_cancel(self.inputToken);
            if (self.sceneToken != NOTIFY_TOKEN_INVALID) notify_cancel(self.sceneToken);
            self.inputToken = self.sceneToken = NOTIFY_TOKEN_INVALID;
            self.sceneHash = 0;
        }
    }
    if (![self isCurrent]) return;
    NSUInteger installed = 0;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || ![scene.session.role isEqual:UIWindowSceneSessionRoleApplication]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden || ![self matchesWindow:window] || [self.gestures objectForKey:window]) continue;
            UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pinch:)];
            pinch.delegate = self;
            [window addGestureRecognizer:pinch];
            [self.gestures setObject:pinch forKey:window];
            installed++;
        }
    }
    if (installed) NSLog(@"[MUBX][FloatingApp] input installed windows=%lu", (unsigned long)installed);
}
- (void)windowVisible:(__unused NSNotification *)notification { [self refresh]; }
- (BOOL)gestureRecognizer:(__unused UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    return [self isCurrent] && [self matchesWindow:touch.window];
}
- (BOOL)gestureRecognizer:(__unused UIGestureRecognizer *)gesture
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    // Don't block single-finger scrolling while the pinch waits for two fingers.
    return ![other isKindOfClass:UIPinchGestureRecognizer.class];
}
- (BOOL)gestureRecognizer:(__unused UIGestureRecognizer *)gesture
        shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    return [self isCurrent] && [other isKindOfClass:UIPinchGestureRecognizer.class];
}
- (void)pinch:(UIPinchGestureRecognizer *)gesture {
    if (![self isCurrent] || self.inputToken == NOTIFY_TOKEN_INVALID) return;
    DXFloatPinchPhase phase;
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
            self.gestureSerial++; if (!self.gestureSerial) self.gestureSerial = 1;
            self.gestureNonce = self.nonce; phase = DXFloatPinchBegan; break;
        case UIGestureRecognizerStateChanged: phase = DXFloatPinchChanged; break;
        case UIGestureRecognizerStateEnded: phase = DXFloatPinchEnded; break;
        case UIGestureRecognizerStateCancelled: phase = DXFloatPinchCancelled; break;
        default: return;
    }
    if (self.gestureNonce != self.nonce) return;
    uint64_t word = DXFloatPinchWord(self.nonce, self.gestureSerial, phase, gesture.scale);
    if (word && notify_set_state(self.inputToken, word) == NOTIFY_STATUS_OK)
        notify_post(DXFloatInputName((uint32_t)getpid()).UTF8String);
    if (phase == DXFloatPinchBegan || phase == DXFloatPinchEnded)
        NSLog(@"[MUBX][FloatingApp] input pinch phase=%u serial=%u", phase, self.gestureSerial);
}
@end

void DXStartFloatingAppInputClient(void) {
    if ([NSProcessInfo.processInfo.processName isEqual:@"SpringBoard"] ||
        ![NSBundle.mainBundle.bundleURL.pathExtension.lowercaseString isEqual:@"app"]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        static DXFloatingAppInputClient *client;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            client = [DXFloatingAppInputClient new];
            __weak DXFloatingAppInputClient *weakClient = client;
            int token = NOTIFY_TOKEN_INVALID;
            if (notify_register_dispatch(DXFloatInputSessionName.UTF8String, &token,
                dispatch_get_main_queue(), ^(__unused int notificationToken) { [weakClient refresh]; }) != NOTIFY_STATUS_OK) return;
            client.sessionToken = token;
            [NSNotificationCenter.defaultCenter addObserver:client selector:@selector(windowVisible:)
                name:UIWindowDidBecomeVisibleNotification object:nil];
            [NSNotificationCenter.defaultCenter addObserver:client selector:@selector(windowVisible:)
                name:UISceneDidActivateNotification object:nil];
            [client refresh];
        });
    });
}
