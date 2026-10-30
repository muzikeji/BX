#import "DXClipboardService.h"
#import "DXClipboardStore.h"
#import "common.h"
#import <UIKit/UIKit.h>
#import <notify.h>
#import <ImageIO/ImageIO.h>

// Kayoko 同款私有接口：_accessibilityFrontMostApplication 用于取当前前台 App
// 的 SBApplication（仅 SpringBoard 进程有效，字符串消息发送避免硬依赖）。
@interface UIApplication (DXClipboardPrivate)
- (id)_accessibilityFrontMostApplication;
@end

// Kayoko 同款：识别来自 iOS 跨设备（Continuity）的远程剪贴板类型，可跳过。
static NSString *const kDXRemoteClipboardPasteboardType = @"com.apple.is-remote-clipboard";
static NSString *const kDXContinuityBundleIdentifier = @"com.apple.Pasteboard";

typedef NS_ENUM(NSUInteger, DXClipboardCommandType) {
    DXClipboardCommandUnknown = 0,
    DXClipboardCommandFavorite,
    DXClipboardCommandDelete,
    DXClipboardCommandClear,
    DXClipboardCommandImport,
};

@interface DXClipboardService () {
    UIPasteboard *_pasteboard;
    NSInteger _lastChangeCount;
}
@property(nonatomic, strong) DXClipboardStore *store;
@property(nonatomic, strong) NSFileManager *fileManager;
@property(nonatomic, assign) BOOL started;
@property(nonatomic, assign) NSInteger lastQueueChangeCount; // 消费队列时记录 changeCount，轮询去重
@property(nonatomic, strong) NSTimer *pollTimer; // 跨进程变更兜底轮询
@end

@implementation DXClipboardService

+ (instancetype)sharedService {
    static DXClipboardService *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _store = [DXClipboardStore sharedStore];
        _fileManager = [NSFileManager defaultManager];
    }
    return self;
}

- (void)start {
    if (self.started) return;
    self.started = YES;

    // 首次启动迁移 Kayoko 历史可能涉及成百上千行 INSERT 与图片复制，
    // 从 %ctor 主线程同步执行会拖慢 SpringBoard 冷启动（1-2 帧卡顿）。
    // 等 SpringBoard 启动完成后再在 Utility 队列异步迁移，先发布空快照。
    __weak DXClipboardService *weakSelf = self;
    [self publishSnapshot];

    if ([NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"]) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            DXClipboardStore *store = weakSelf.store;
            if ([store prepareDatabase]) {
                [store importKayokoHistory];
            }
        });
    } else {
        if ([self.store prepareDatabase]) {
            [self.store importKayokoHistory];
        }
    }

    _pasteboard = [UIPasteboard generalPasteboard];
    _lastChangeCount = _pasteboard.changeCount;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(generalPasteboardDidChange:)
                                                 name:UIPasteboardChangedNotification
                                               object:_pasteboard];

    // UIPasteboardChangedNotification 只在本进程执行写入时广播。其它 App 的复制
    // 事件不会送达 SpringBoard，因此必须用 changeCount 轮询跨进程兜底。
    if ([NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"]) {
        [self startPollingForCrossProcessChanges];
    }

    // app 进程命令入口（copy/delete/favorite/clear/import）。
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    (__bridge const void *)self,
                                    &DXClipboardCommandCallback,
                                    (CFStringRef)kClipboardCommandIdentifier,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    // app 进程复制采集入口（跨进程内容入队 → SB 落库）。
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    (__bridge const void *)self,
                                    &DXClipboardCaptureCallback,
                                    (CFStringRef)kClipboardCaptureIdentifier,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    // 启动即消费一次，避免 App 采集后 SB 尚未注册时漏掉。
    [self consumePendingCaptures];

    NSLog(@"[TypeX][Clipboard] 剪贴板服务已启动");
}

static void DXClipboardCommandCallback(CFNotificationCenterRef center, void *observer,
                                       CFStringRef name, const void *object,
                                       CFDictionaryRef userInfo) {
    (void)center; (void)name; (void)object; (void)userInfo;
    DXClipboardService *service = (__bridge DXClipboardService *)observer;
    NSDictionary *command = DXQuickActionSharedValue(kClipboardCommandKey);
    if (![command isKindOfClass:[NSDictionary class]]) return;
    // 命令是一次性的：取走后即清除，避免迟到通知被重复消费。
    DXSetQuickActionSharedValue(nil, kClipboardCommandKey);
    dispatch_async(dispatch_get_main_queue(), ^{
        [service handleCommand:command];
    });
}

static void DXClipboardCaptureCallback(CFNotificationCenterRef center, void *observer,
                                       CFStringRef name, const void *object,
                                       CFDictionaryRef userInfo) {
    (void)center; (void)name; (void)object; (void)userInfo;
    DXClipboardService *service = (__bridge DXClipboardService *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        [service consumePendingCaptures];
    });
}

#pragma mark - Pasteboard observation

- (void)startPollingForCrossProcessChanges {
    [self.pollTimer invalidate];
    __weak DXClipboardService *weakSelf = self;
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                     repeats:YES
                                                       block:^(NSTimer *timer) {
        (void)timer;
        [weakSelf pollCrossProcessPasteboardChange];
    }];
}

- (void)pollCrossProcessPasteboardChange {
    // changeCount 是系统级计数，任何进程写入都会递增，跨进程可靠。
    NSInteger changeCount = [UIPasteboard generalPasteboard].changeCount;
    if (changeCount == _lastChangeCount) return;
    _lastChangeCount = changeCount;

    // 该次变更已由 App 采集队列消费过，跳过避免重复入库。
    if (changeCount == self.lastQueueChangeCount) return;

    [self captureCurrentPasteboard];
}

- (void)generalPasteboardDidChange:(NSNotification *)notification {
    (void)notification;
    [self pollCrossProcessPasteboardChange];
}

- (BOOL)shouldIgnoreCurrentPasteboardChangeFromSourceBundleIdentifier:(NSString *)sourceBundleIdentifier {
    // 远程复制（iPhone/Mac 互通）：默认忽略，与 Kayoko 语义一致。
    if ([_pasteboard containsPasteboardTypes:@[ kDXRemoteClipboardPasteboardType ]]) {
        return YES;
    }
    // 黑名单 App。
    NSArray *blacklist = [self preferenceArrayForKey:kClipboardBlacklistKey];
    if ([blacklist containsObject:sourceBundleIdentifier]) {
        return YES;
    }
    // 系统图标等无关类型。
    if ([_pasteboard containsPasteboardTypes:@[ @"com.apple.icns" ]]) {
        return YES;
    }
    return NO;
}

#pragma mark - App capture queue

- (void)consumePendingCaptures {
    id pending = DXQuickActionSharedValue(kClipboardCaptureKey);
    if (!pending) return;
    // 取走即清除，避免重复消费。
    DXSetQuickActionSharedValue(nil, kClipboardCaptureKey);

    NSArray *captures = nil;
    if ([pending isKindOfClass:[NSArray class]]) {
        captures = pending;
    } else if ([pending isKindOfClass:[NSDictionary class]]) {
        captures = @[ pending ];
    } else {
        return;
    }

    BOOL saved = NO;
    for (NSDictionary *capture in captures) {
        if (![capture isKindOfClass:[NSDictionary class]]) continue;
        if ([self applyCapture:capture]) {
            saved = YES;
            // 队列中携带的 changeCount 是最新一次变更；后面到来的轮询
            // 跳过一次，避免 App 采集与 SB 轮询重复入库。
            NSInteger capturedChangeCount = [capture[@"changeCount"] integerValue];
            if (capturedChangeCount > 0) self.lastQueueChangeCount = capturedChangeCount;
        }
    }
    if (saved) {
        [self publishSnapshot];
        notify_post([kClipboardChangedIdentifier UTF8String]);
    }
}

- (BOOL)applyCapture:(NSDictionary *)capture {
    if (![self preferenceBoolForKey:kClipboardEnabledKey fallback:YES]) return NO;

    NSString *bundle = capture[@"bundle"];
    if (![bundle isKindOfClass:[NSString class]] || bundle.length == 0) bundle = @"unknown";

    NSArray *blacklist = [self preferenceArrayForKey:kClipboardBlacklistKey];
    if ([blacklist containsObject:bundle]) return NO;

    double capturedAt = [capture[@"at"] doubleValue];
    if (capturedAt <= 0) capturedAt = [[NSDate date] timeIntervalSince1970];

    BOOL saved = NO;
    id imageData = capture[@"image"];
    if ([imageData isKindOfClass:[NSData class]] && [self preferenceBoolForKey:kClipboardSaveImagesKey fallback:YES]) {
        NSString *extension = capture[@"imageExtension"] ?: @"png";
        NSString *imageName = [self.store saveImageData:imageData extension:extension];
        if (imageName) {
            CGSize pixelSize = [self pixelSizeForEncodedImageData:imageData];
            [self.store addItemWithHistoryKey:@"history"
                           bundleIdentifier:bundle
                                    content:imageName
                                  imageName:imageName
                                 imageWidth:(NSUInteger)llround(pixelSize.width)
                                imageHeight:(NSUInteger)llround(pixelSize.height)
                                    hasLink:NO
                                 capturedAt:capturedAt];
            saved = YES;
        }
    }

    id text = capture[@"text"];
    if (!saved && [text isKindOfClass:[NSString class]] && [text length] > 0 &&
        [self preferenceBoolForKey:kClipboardSaveTextKey fallback:YES]) {
        [self.store addItemWithHistoryKey:@"history"
                       bundleIdentifier:bundle
                                content:text
                              imageName:nil
                             imageWidth:0
                            imageHeight:0
                                hasLink:NO
                             capturedAt:capturedAt];
        saved = YES;
    }
    return saved;
}

- (NSString *)sourceApplicationBundleIdentifierForCurrentPasteboardChange {
    UIApplication *application = [UIApplication sharedApplication];
    id frontMost = [application respondsToSelector:@selector(_accessibilityFrontMostApplication)]
        ? [application _accessibilityFrontMostApplication]
        : nil;
    NSString *bundleIdentifier = [frontMost respondsToSelector:@selector(bundleIdentifier)]
        ? [frontMost bundleIdentifier] : nil;
    if (bundleIdentifier.length == 0) bundleIdentifier = @"com.apple.springboard";
    return bundleIdentifier;
}

#pragma mark - Capture

- (void)captureCurrentPasteboard {
    if (![self preferenceBoolForKey:kClipboardEnabledKey fallback:YES]) return;

    NSString *sourceBundleIdentifier = [self sourceApplicationBundleIdentifierForCurrentPasteboardChange];
    if ([self shouldIgnoreCurrentPasteboardChangeFromSourceBundleIdentifier:sourceBundleIdentifier]) return;

    BOOL saveText = [self preferenceBoolForKey:kClipboardSaveTextKey fallback:YES];
    BOOL saveImages = [self preferenceBoolForKey:kClipboardSaveImagesKey fallback:YES];

    for (NSDictionary *pasteboardItem in _pasteboard.items) {
        @autoreleasepool {
            if (![pasteboardItem isKindOfClass:[NSDictionary class]]) continue;

            // 1) 图片优先（与 Kayoko 相同：先尝试图片表示）。
            if (saveImages) {
                UIImage *image = [self imageFromPasteboardItemDictionary:pasteboardItem];
                if (image) {
                    NSData *imageData = [self encodedImageDataForImage:image];
                    if (imageData.length) {
                        NSString *extension = [self imageHasAlpha:image] ? @"png" : @"jpg";
                        NSString *imageName = [self.store saveImageData:imageData extension:extension];
                        if (imageName) {
                            CGSize pixelSize = [self pixelSizeForEncodedImageData:imageData];
                            [self.store addItemWithHistoryKey:@"history"
                                           bundleIdentifier:sourceBundleIdentifier
                                                    content:imageName
                                                  imageName:imageName
                                                 imageWidth:(NSUInteger)llround(pixelSize.width)
                                                imageHeight:(NSUInteger)llround(pixelSize.height)
                                                   hasLink:NO
                                                 capturedAt:[[NSDate date] timeIntervalSince1970]];
                        }
                    }
                    continue;
                }
            }

            // 2) 文本（含 URL / 富文本的纯文本表示）。
            if (!saveText) continue;
            NSString *plainText = [self plainTextFromPasteboardItemDictionary:pasteboardItem];
            if (plainText.length == 0) continue;

            BOOL hasLink = [self itemContainsURL:pasteboardItem];
            [self.store addItemWithHistoryKey:@"history"
                           bundleIdentifier:sourceBundleIdentifier
                                    content:plainText
                                  imageName:nil
                                 imageWidth:0
                                imageHeight:0
                                   hasLink:hasLink
                                 capturedAt:[[NSDate date] timeIntervalSince1970]];
        }
    }

    [self publishSnapshot];
    notify_post([kClipboardChangedIdentifier UTF8String]);
}

#pragma mark - Pasteboard representation helpers

- (UIImage *)imageFromPasteboardItemDictionary:(NSDictionary<NSString *, id> *)dictionary {
    NSArray<NSString *> *imageTypeIdentifiers = @[
        @"public.png",
        @"public.jpeg",
        @"public.jpeg-2000",
        @"public.tiff",
        @"public.image",
        @"com.apple.uikit.image",
    ];
    for (NSString *typeIdentifier in imageTypeIdentifiers) {
        id value = dictionary[typeIdentifier];
        if ([value isKindOfClass:[UIImage class]]) return value;
        if ([value isKindOfClass:[NSData class]]) {
            UIImage *image = [UIImage imageWithData:value];
            if (image) return image;
        }
    }
    // 兜底：遍历所有以 Data 表示的值尝试解码（保证截图/Safari 图片等命中）。
    for (NSString *typeIdentifier in dictionary) {
        id value = dictionary[typeIdentifier];
        if (![value isKindOfClass:[NSData class]]) continue;
        UIImage *image = [UIImage imageWithData:value];
        if (image) return image;
    }
    return nil;
}

- (NSString *)plainTextFromPasteboardItemDictionary:(NSDictionary<NSString *, id> *)dictionary {
    NSArray<NSString *> *textTypeIdentifiers = @[
        @"public.utf8-plain-text",
        @"public.plain-text",
        @"public.text",
        @"public.url",
        @"public.file-url",
    ];
    for (NSString *typeIdentifier in textTypeIdentifiers) {
        id value = dictionary[typeIdentifier];
        NSString *text = nil;
        if ([value isKindOfClass:[NSString class]]) {
            text = value;
        } else if ([value isKindOfClass:[NSURL class]]) {
            text = [value absoluteString];
        } else if ([value isKindOfClass:[NSAttributedString class]]) {
            text = [value string];
        } else if ([value isKindOfClass:[NSData class]]) {
            text = [[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding];
        }
        if (text.length > 0) return text;
    }
    // 富文本兜底：App 只提供 attributed string 时取其纯文本。
    for (NSString *typeIdentifier in dictionary) {
        id value = dictionary[typeIdentifier];
        if ([value isKindOfClass:[NSAttributedString class]]) {
            NSString *text = [value string];
            if (text.length > 0) return text;
            break;
        }
    }
    return nil;
}

- (BOOL)itemContainsURL:(NSDictionary<NSString *, id> *)dictionary {
    if ([dictionary[@"public.url"] isKindOfClass:[NSURL class]]) return YES;
    if ([dictionary[@"public.url"] isKindOfClass:[NSString class]]) return YES;
    if ([dictionary[@"public.file-url"] isKindOfClass:[NSURL class]]) return YES;
    return NO;
}

- (BOOL)imageHasAlpha:(UIImage *)image {
    CGImageAlphaInfo alpha = CGImageGetAlphaInfo([image CGImage]);
    return (alpha == kCGImageAlphaFirst || alpha == kCGImageAlphaLast ||
            alpha == kCGImageAlphaPremultipliedFirst || alpha == kCGImageAlphaPremultipliedLast);
}

- (NSData *)encodedImageDataForImage:(UIImage *)image {
    if ([self imageHasAlpha:image]) {
        NSData *png = UIImagePNGRepresentation(image);
        return png ?: UIImageJPEGRepresentation(image, 1);
    }
    return UIImageJPEGRepresentation(image, 1);
}

- (CGSize)pixelSizeForEncodedImageData:(NSData *)imageData {
    if (imageData.length == 0) return CGSizeZero;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)imageData, NULL);
    if (!source) return CGSizeZero;
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    CFRelease(source);
    CGFloat width = [properties[(NSString *)kCGImagePropertyPixelWidth] doubleValue];
    CGFloat height = [properties[(NSString *)kCGImagePropertyPixelHeight] doubleValue];
    if (!isfinite(width) || !isfinite(height) || width <= 0 || height <= 0) return CGSizeZero;
    return CGSizeMake(width, height);
}

#pragma mark - Snapshot (SpringBoard -> apps)

- (void)publishSnapshot {
    if (![self.store prepareDatabase]) return;

    NSUInteger limit = [self preferenceIntForKey:kClipboardMaxCountKey fallback:kClipboardMaxCountDefault];
    if (limit == 0) limit = kClipboardMaxCountDefault;

    NSArray *history = [self.store itemsForHistoryKey:@"history" searchText:nil limit:limit];
    NSArray *favorites = [self.store itemsForHistoryKey:@"favorites" searchText:nil limit:limit];

    NSDictionary *snapshot = @{
        @"format": @1,
        @"updated": @([[NSDate date] timeIntervalSince1970]),
        @"history": history,
        @"favorites": favorites,
        @"mirrorPath": kClipboardImagesMirrorPath,
    };
    DXSetQuickActionSharedValue(snapshot, kClipboardSnapshotKey);
}

#pragma mark - Preferences helpers

- (BOOL)preferenceBoolForKey:(NSString *)key fallback:(BOOL)fallback {
    id value = [DXPrefsManager.sharedInstance.prefs objectForKey:key];
    if ([value isKindOfClass:[NSNumber class]]) return [value boolValue];
    return fallback;
}

- (NSInteger)preferenceIntForKey:(NSString *)key fallback:(NSInteger)fallback {
    id value = [DXPrefsManager.sharedInstance.prefs objectForKey:key];
    if ([value isKindOfClass:[NSNumber class]]) return [value integerValue];
    return fallback;
}

- (NSArray *)preferenceArrayForKey:(NSString *)key {
    id value = [DXPrefsManager.sharedInstance.prefs objectForKey:key];
    return [value isKindOfClass:[NSArray class]] ? value : @[];
}

#pragma mark - Commands from panels (app processes)

- (void)handleCommand:(NSDictionary *)command {
    NSString *action = command[@"action"];
    DXClipboardCommandType type = DXClipboardCommandUnknown;
    if ([action isEqualToString:@"favorite"]) type = DXClipboardCommandFavorite;
    else if ([action isEqualToString:@"delete"]) type = DXClipboardCommandDelete;
    else if ([action isEqualToString:@"clear"]) type = DXClipboardCommandClear;
    else if ([action isEqualToString:@"import"]) type = DXClipboardCommandImport;

    switch (type) {
        case DXClipboardCommandFavorite: {
            BOOL favorite = [command[@"favorite"] boolValue];
            NSString *historyKey = command[@"historyKey"];
            NSString *content = command[@"content"];
            [self.store setFavorite:favorite historyKey:historyKey ?: @"history" content:content ?: @""];
            break;
        }
        case DXClipboardCommandDelete: {
            NSNumber *itemID = command[@"id"];
            if ([itemID isKindOfClass:[NSNumber class]]) {
                [self.store deleteItemWithID:[itemID integerValue]];
            }
            break;
        }
        case DXClipboardCommandClear: {
            NSString *historyKey = command[@"historyKey"];
            [self.store clearHistoryKey:historyKey ?: @"history"];
            break;
        }
        case DXClipboardCommandImport: {
            // 手动迁移：无视幂等标记强制重跑，保证设置页按钮始终有反馈。
            [self.store importKayokoHistoryForced:YES];
            break;
        }
        default:
            return;
    }

    [self publishSnapshot];
    notify_post([kClipboardChangedIdentifier UTF8String]);
}

@end