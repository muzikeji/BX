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
@property(nonatomic, assign) BOOL pendingWrite; // 面板粘贴写入时的自身写入抑制标记
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

    // 首启：建库 + 一次性迁移 Kayoko 历史。
    if ([self.store prepareDatabase]) {
        [self.store importKayokoHistory];
    }

    _pasteboard = [UIPasteboard generalPasteboard];
    _lastChangeCount = _pasteboard.changeCount;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(generalPasteboardDidChange:)
                                                 name:UIPasteboardChangedNotification
                                               object:_pasteboard];

    // app 进程命令入口（copy/delete/favorite/clear/import）。
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    (__bridge const void *)self,
                                    &DXClipboardCommandCallback,
                                    (CFStringRef)kClipboardCommandIdentifier,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    [self publishSnapshot];
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

#pragma mark - Pasteboard observation

- (void)generalPasteboardDidChange:(NSNotification *)notification {
    (void)notification;
    NSInteger changeCount = _pasteboard.changeCount;
    if (changeCount == _lastChangeCount) return;
    _lastChangeCount = changeCount;

    // 面板自己发起的粘贴写入：内容已存在于历史，无需重复入库（会在面板侧
    // 触发一次 writePasteboardForItem，这里抑制避免自我复制）。
    if (self.pendingWrite) {
        self.pendingWrite = NO;
        return;
    }

    [self captureCurrentPasteboard];
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
            [self.store importKayokoHistory];
            break;
        }
        default:
            return;
    }

    [self publishSnapshot];
    notify_post([kClipboardChangedIdentifier UTF8String]);
}

@end