#import "DXSystemRecordingSession.h"
#import "DXSystemActionInvocation.h"

static const NSTimeInterval DXRecordingReplyTimeout = 7.5; // Before the transport's 10-second timeout.

static NSNumber *DXRecordingState(id recorder, NSString *name) {
    id value = nil;
    return DXSystemInvoke(recorder, name, @[], &value) && [value isKindOfClass:NSNumber.class] ? value : nil;
}

// A private method's presence alone does not establish its call ABI. Never
// fall back to an app recording/broadcast method or a URL-returning stop route.
static BOOL DXRecordingInterfaceAvailable(id recorder, BOOL stopping) {
    SEL selector = NSSelectorFromString(stopping ? @"stopSystemRecording:" : @"startSystemRecordingWithMicrophoneEnabled:handler:");
    if (![recorder respondsToSelector:selector]) return NO;
    NSMethodSignature *signature = [recorder methodSignatureForSelector:selector];
    if (!signature || strcmp(DXSystemUnqualifiedType(signature.methodReturnType), "v") ||
        signature.numberOfArguments != (stopping ? 3 : 4)) return NO;
    if (!stopping) {
        const char *flag = DXSystemUnqualifiedType([signature getArgumentTypeAtIndex:2]);
        if (strcmp(flag, "B") && strcmp(flag, "c")) return NO;
    }
    return !strcmp(DXSystemUnqualifiedType([signature getArgumentTypeAtIndex:stopping ? 2 : 3]), "@?");
}

@interface DXSystemRecordingSession ()
@property(nonatomic) BOOL busy;
@property(nonatomic) BOOL stopping;
@property(nonatomic) BOOL timedOut;
@property(nonatomic) NSUInteger generation;
@property(nonatomic, copy) DXSystemOpenReply pendingReply;
@property(nonatomic, strong) id activeRecorder;
@end

@implementation DXSystemRecordingSession
- (void)finish:(DXSystemOpenResult)result generation:(NSUInteger)generation {
    if (!self.busy || self.generation != generation) return;
    DXSystemOpenReply reply = self.pendingReply;
    self.pendingReply = nil;
    self.activeRecorder = nil;
    self.busy = NO;
    self.timedOut = NO;
    NSLog(@"[MUBX][SystemRecording] completion generation=%lu result=%llu", (unsigned long)generation, (unsigned long long)result);
    if (reply) reply(result);
}
- (void)toggleRecorder:(id)recorder microphoneEnabled:(BOOL)enabled reply:(DXSystemOpenReply)reply {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (reply) reply(DXSystemOpenUnavailable); });
        return;
    }
    if (self.busy && self.timedOut) {
        // A lost native callback must not keep the slot forever once the
        // requested terminal state is observed. Old callbacks stay invalid.
        NSNumber *recording = DXRecordingState(self.activeRecorder, @"isRecording");
        BOOL settled = recording && (self.stopping ? !recording.boolValue : recording.boolValue);
        if (settled) [self finish:DXSystemOpenSucceeded generation:self.generation];
    }
    if (self.busy) { if (reply) reply(DXSystemOpenBusy); return; }
    NSNumber *recording = DXRecordingState(recorder, @"isRecording");
    if (!recording) { if (reply) reply(DXSystemOpenUnavailable); return; }
    // RPScreenRecorder in SpringBoard only drives the system recording (app
    // captures and broadcasts run in their own processes), so the public
    // isRecording flag alone decides start versus stop. No private state
    // getter exists to separate the two.
    BOOL stopping = recording.boolValue;
    if (!DXRecordingInterfaceAvailable(recorder, stopping)) {
        NSLog(@"[MUBX][SystemRecording] unavailable stage=interface stopping=%d", stopping);
        if (reply) reply(DXSystemOpenUnavailable);
        return;
    }
    if (!stopping) {
        NSNumber *available = DXRecordingState(recorder, @"isAvailable");
        if (!available || !available.boolValue) { if (reply) reply(DXSystemOpenUnavailable); return; }
    }
    self.busy = YES;
    self.stopping = stopping;
    self.activeRecorder = recorder;
    self.pendingReply = reply;
    NSUInteger generation = ++self.generation;
    NSLog(@"[MUBX][SystemRecording] submit generation=%lu stopping=%d microphone=%d", (unsigned long)generation, stopping, enabled);
    // ReplayKit may complete on a worker queue. Only the current operation
    // can consume a reply, including synchronous or duplicate callbacks.
    __weak typeof(self) weakSelf = self;
    void (^completion)(NSError *) = ^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            if (!self.busy || self.generation != generation) return;
            if (error) NSLog(@"[MUBX][SystemRecording] native error domain=%@ code=%ld", error.domain, (long)error.code);
            [self finish:error ? DXSystemOpenFailed : DXSystemOpenSucceeded generation:generation];
        });
    };
    NSString *selector = stopping ? @"stopSystemRecording:" : @"startSystemRecordingWithMicrophoneEnabled:handler:";
    NSArray *arguments = stopping ? @[completion] : @[@(enabled), completion];
    if (!DXSystemInvoke(recorder, selector, arguments, NULL)) {
        [self finish:DXSystemOpenUnavailable generation:generation];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(DXRecordingReplyTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (!self.busy || self.generation != generation) return;
        self.timedOut = YES;
        DXSystemOpenReply timedOutReply = self.pendingReply;
        self.pendingReply = nil;
        NSLog(@"[MUBX][SystemRecording] timeout generation=%lu; outcome unknown, no retry", (unsigned long)generation);
        if (timedOutReply) timedOutReply(DXSystemOpenTimedOut);
        // Keep the flight guard until native completion or an observed terminal
        // state. A timeout never starts/stops a recording or retries an action.
    });
}
@end
