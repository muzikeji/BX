#import "DXSensitiveURLExecutor.h"

static dispatch_queue_t DXSensitiveURLQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.lindo.mubx.open.sensitive-rpc", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static BOOL DXSensitiveRequestExpired(NSProgress *request, NSDate *deadline) {
    return !request || request.cancelled || !deadline || !(deadline.timeIntervalSinceNow > 0);
}

void DXExecuteSensitiveURL(NSURL *url, NSDate *deadline, NSProgress *request,
                          DXSensitiveURLDelivery deliver, DXSystemOpenReply reply) {
    NSString *scheme = url.scheme.lowercaseString;
    dispatch_async(DXSensitiveURLQueue(), ^{
        @autoreleasepool {
            __block DXSystemOpenResult result = DXSystemOpenUnavailable;
            if (DXSensitiveRequestExpired(request, deadline)) {
                result = DXSystemOpenExpired;
            } else if (deliver) {
                // SBSOpenSensitiveURLAndUnlock is a synchronous client entry
                // point into SpringBoard. Waiting for it on SpringBoard's UI
                // thread can hold up the URL dispatch it is asking to perform.
                NSLog(@"[MUBXSB] sensitive RPC begin scheme=%@", scheme);
                @try { result = deliver(url) ? DXSystemOpenSucceeded : DXSystemOpenFailed; }
                @catch (NSException *exception) {
                    NSLog(@"[MUBXSB] sensitive RPC exception=%@", exception.name);
                    result = DXSystemOpenFailed;
                }
                NSLog(@"[MUBXSB] sensitive RPC end scheme=%@ result=%llu", scheme, (unsigned long long)result);
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                // The RPC cannot be cancelled once entered. A stale request must
                // not report success after a newer action or a timeout.
                if (DXSensitiveRequestExpired(request, deadline)) {
                    result = DXSystemOpenExpired;
                }
                if (reply) reply(result);
            });
        }
    });
}
