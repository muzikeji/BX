#import "DXClipboardCapture.h"
#import "common.h"
#import "DXShared.h"
#import <UIKit/UIKit.h>
#import <notify.h>

static const NSUInteger kDXClipboardCaptureMaxItems = 30;

@interface DXClipboardCapture () {
    NSInteger _lastCapturedChangeCount;
}
@property(nonatomic, assign) BOOL started;
@property(nonatomic, copy) NSString *processBundleIdentifier;
@end

@implementation DXClipboardCapture

+ (instancetype)sharedCapture {
    static DXClipboardCapture *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (void)capturePasteboardAfterWrite {
    if (!self.started || [NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"]) return;
    if (!preferencesBool(kClipboardEnabledKey, YES)) return;

    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
    NSInteger changeCount = pasteboard.changeCount;
    if (changeCount == _lastCapturedChangeCount) return;
    _lastCapturedChangeCount = changeCount;
    if (!pasteboard.hasStrings) return;
    NSString *text = pasteboard.string;
    if (!text.length || !preferencesBool(kClipboardSaveTextKey, YES)) return;

    NSDictionary *capture = @{
        @"bundle": self.processBundleIdentifier ?: @"unknown",
        @"at": @([[NSDate date] timeIntervalSince1970]),
        @"changeCount": @(pasteboard.changeCount),
        @"text": text,
    };

    NSMutableArray *queue = [NSMutableArray array];
    id existing = DXQuickActionSharedValue(kClipboardCaptureKey);
    if ([existing isKindOfClass:[NSArray class]]) {
        [queue addObjectsFromArray:existing];
    } else if ([existing isKindOfClass:[NSDictionary class]]) {
        [queue addObject:existing];
    }
    [queue addObject:capture];
    if (queue.count > kDXClipboardCaptureMaxItems) {
        [queue removeObjectsInRange:NSMakeRange(0, queue.count - kDXClipboardCaptureMaxItems)];
    }
    if (!DXSetQuickActionSharedValue(queue, kClipboardCaptureKey)) return;
    notify_post([kClipboardCaptureIdentifier UTF8String]);
}

- (void)start {
    if (self.started) return;
    self.started = YES;
    self.processBundleIdentifier = NSBundle.mainBundle.bundleIdentifier ?: @"unknown";
    // changeCount 是系统级递增计数，-1 保证首个捕获不被误跳过。
    _lastCapturedChangeCount = -1;
}

@end
