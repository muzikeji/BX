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
};

@interface DXClipboardService () {
    UIPasteboard *_pasteboard;
    NSInteger _lastChangeCount;
}
@property(nonatomic, strong) DXClipboardStore *store;
@property(nonatomic, strong) NSFileManager *fileManager;
@property(nonatomic, assign) BOOL started;
@property(nonatomic, strong) dispatch_queue_t pasteboardQueue; // 粘贴板读取串行队列（Kayoko 同款，避免主线程 I/O）
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

    [self publishSnapshot];

    _pasteboard = [UIPasteboard generalPasteboard];
    _lastChangeCount = _pasteboard.changeCount;
    _pasteboardQueue = dispatch_queue_create("com.lindo.typex.pasteboard",
                                             dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                                                    QOS_CLASS_UTILITY, 0));

    // Kayoko 同款跨进程采集：粘贴板守护进程在任何 App 写入时都跨进程广播
    // com.apple.pasteboard.notify.changed，SpringBoard 侧延迟 0.1s 后在后台
    // 队列读取内容落库。无 hook、无 cfprefsd 中转、无主线程 I/O。
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    (__bridge const void *)self,
                                    &DXClipboardPasteboardChangedCallback,
                                    (CFStringRef)kClipboardPasteboardChangedName,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    // app 进程命令入口（copy/delete/favorite/clear）。
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    (__bridge const void *)self,
                                    &DXClipboardCommandCallback,
                                    (CFStringRef)kClipboardCommandIdentifier,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    NSLog(@"[TypeX][Clipboard] 剪贴板服务已启动");
}

static void DXClipboardPasteboardChangedCallback(CFNotificationCenterRef center, void *observer,
                                                 CFStringRef name, const void *object,
                                                 CFDictionaryRef userInfo) {
    (void)center; (void)name; (void)object; (void)userInfo;
    DXClipboardService *service = (__bridge DXClipboardService *)observer;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [service capturePasteboardChangeNow];
    });
}

- (void)capturePasteboardChangeNow {
    if ([self preferenceBoolForKey:kClipboardEnabledKey fallback:YES] == NO) return;

    NSString *sourceBundleIdentifier = [self sourceApplicationBundleIdentifierForCurrentPasteboardChange];
    __weak DXClipboardService *weakSelf = self;
    dispatch_async(self.pasteboardQueue, ^{
        [weakSelf pullPasteboardChangesWithSourceBundleIdentifier:sourceBundleIdentifier];
    });
}

- (void)pullPasteboardChangesWithSourceBundleIdentifier:(NSString *)sourceBundleIdentifier {
    NSInteger changeCount = _pasteboard.changeCount;
    if (changeCount == _lastChangeCount) return;
    _lastChangeCount = changeCount;

    if ([self shouldIgnoreCurrentPasteboardChangeFromSourceBundleIdentifier:sourceBundleIdentifier]) return;

    [self captureCurrentPasteboardWithSourceBundleIdentifier:sourceBundleIdentifier];
}

static void DXClipboardCommandCallback(CFNotificationCenterRef center, void *observer,
                                       CFStringRef name, const void *object,
                                       CFDictionaryRef userInfo) {
    (void)center; (void)name; (void)object; (void)userInfo;
    DXClipboardService *service = (__bridge DXClipboardService *)observer;
    // 命令通道：共享命令文件（沙盒 App 面板写入）优先，cfprefsd 域兜底
    // （未沙盒进程，如设置页，直接写域）。
    NSDictionary *command = DXReadSharedPlistFile(TypeXClipboardCommandPath);
    if (![command isKindOfClass:[NSDictionary class]]) {
        command = DXQuickActionSharedValue(kClipboardCommandKey);
    }
    if (![command isKindOfClass:[NSDictionary class]]) return;
    // 命令是一次性的：取走即删（文件与域同时清），避免迟到通知被重复消费。
    [[NSFileManager defaultManager] removeItemAtPath:TypeXClipboardCommandPath error:nil];
    DXSetQuickActionSharedValue(nil, kClipboardCommandKey);
    dispatch_async(dispatch_get_main_queue(), ^{
        [service handleCommand:command];
    });
}

#pragma mark - Pasteboard observation

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

#pragma mark - Capture

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

- (void)captureCurrentPasteboardWithSourceBundleIdentifier:(NSString *)sourceBundleIdentifier {
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
    // 共享快照文件：位于 jbroot 下 app 沙盒可读目录，普通 App 面板经此读取
    // （沙盒进程读不到 cfprefsd 隔离域，只能经文件交换，机制同 shared.plist）。
    DXWriteSharedPlistFile(snapshot, TypeXClipboardSnapshotPath);
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
        default:
            return;
    }

    [self publishSnapshot];
    notify_post([kClipboardChangedIdentifier UTF8String]);
}

@end