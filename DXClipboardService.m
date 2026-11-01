#import "DXClipboardService.h"
#import "DXClipboardStore.h"
#import "common.h"
#import <UIKit/UIKit.h>
#import <notify.h>
#import <ImageIO/ImageIO.h>
#import <objc/message.h>

// Kayoko 同款私有接口：_accessibilityFrontMostApplication 用于取当前前台 App
// 的 SBApplication（仅 SpringBoard 进程有效，字符串消息发送避免硬依赖）。
@interface UIApplication (DXClipboardPrivate)
- (id)_accessibilityFrontMostApplication;
@end

// Kayoko 同款：识别来自 iOS 跨设备（Continuity）的远程剪贴板类型，可跳过。
static NSString *const kDXRemoteClipboardPasteboardType = @"com.apple.is-remote-clipboard";
static NSString *const kDXContinuityBundleIdentifier = @"com.apple.Pasteboard";

@interface DXClipboardService () {
    UIPasteboard *_pasteboard;
    NSInteger _lastChangeCount;
}
@property(nonatomic, strong) DXClipboardStore *store;
@property(nonatomic, strong) NSFileManager *fileManager;
@property(nonatomic, assign) BOOL started;
@property(nonatomic, strong) dispatch_queue_t pasteboardQueue; // 粘贴板读取串行队列（Kayoko 同款，避免主线程 I/O）
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *lastConsumedSeqByBundle; // 命令 seq 去重（按来源 App）
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
        _lastConsumedSeqByBundle = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)start {
    if (self.started) return;
    self.started = YES;

    [self publishSnapshot];

    _pasteboard = [UIPasteboard generalPasteboard];
    _lastChangeCount = _pasteboard.changeCount;
    _pasteboardQueue = dispatch_queue_create("com.lindo.mubx.pasteboard",
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

    // 面板进程本地改动共享数据库后广播 kClipboardChangedIdentifier，
    // SpringBoard 收到后重新发布快照（供仍依赖快照的进程/兜底路径刷新）。
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    (__bridge const void *)self,
                                    &DXClipboardChangedCallback,
                                    (CFStringRef)kClipboardChangedIdentifier,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    // 1.0.6 面板操作命令通道：App 面板（Dopamine/RootHide 沙盒对 jbroot 只读）
    // 把删除/收藏/清空命令写入自己容器并广播，SB 收到后消费执行（见
    // consumeClipboardCommands，延迟等待 App 容器文件落盘）。
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    (__bridge const void *)self,
                                    &DXClipboardCommandCallback,
                                    (CFStringRef)kClipboardCommandIdentifier,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    NSLog(@"[MUBX][Clipboard] 剪贴板服务已启动");
    DXLogClipboard(@"[MUBX][Clipboard] 剪贴板服务已启动");
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

static void DXClipboardChangedCallback(CFNotificationCenterRef center, void *observer,
                                       CFStringRef name, const void *object,
                                       CFDictionaryRef userInfo) {
    (void)center; (void)name; (void)object; (void)userInfo;
    DXClipboardService *service = (__bridge DXClipboardService *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        [service publishSnapshot];
    });
}

// 面板命令通知：延迟等待 App 把命令文件原子写盘完成后消费。
static void DXClipboardCommandCallback(CFNotificationCenterRef center, void *observer,
                                       CFStringRef name, const void *object,
                                       CFDictionaryRef userInfo) {
    (void)center; (void)name; (void)object; (void)userInfo;
    DXClipboardService *service = (__bridge DXClipboardService *)observer;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [service consumeClipboardCommands];
    });
}

#pragma mark - App command channel (1.0.6)

// 取 App 数据容器路径（/var/mobile/Containers/Data/Application/<UUID>），
// 经 LSApplicationProxy 动态派发（文档中已有该类方法的动态调用先例），
// 避免静态链接 MobileCoreServices。dataContainerURL 缺失时回落 containerURL。
- (NSString *)dataContainerPathForBundleID:(NSString *)bundleID {
    if (bundleID.length == 0) return nil;
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    if (!proxyClass) return nil;
    id (*lookup)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
    id proxy = lookup(proxyClass, NSSelectorFromString(@"applicationProxyForIdentifier:"), bundleID);
    if (!proxy) return nil;
    if ([proxy respondsToSelector:@selector(dataContainerURL)]) {
        id url = ((id (*)(id, SEL))objc_msgSend)(proxy, @selector(dataContainerURL));
        if ([url isKindOfClass:[NSURL class]] && [url path].length > 0) return [url path];
    }
    if ([proxy respondsToSelector:@selector(containerURL)]) {
        id url = ((id (*)(id, SEL))objc_msgSend)(proxy, @selector(containerURL));
        if ([url isKindOfClass:[NSURL class]] && [url path].length > 0) return [url path];
    }
    return nil;
}

- (void)consumeClipboardCommands {
    NSString *bundleID = [self sourceApplicationBundleIdentifierForCurrentPasteboardChange];
    if (bundleID.length == 0) bundleID = @"com.apple.springboard";
    NSString *containerPath = [self dataContainerPathForBundleID:bundleID];
    if (containerPath.length == 0) {
        DXLogClipboard(@"[MUBX][Clipboard][cmd] consume: 容器路径获取失败 bundle=%@", bundleID);
        return;
    }

    NSString *commandPath = [containerPath stringByAppendingPathComponent:
                             [@"Documents" stringByAppendingPathComponent:kClipboardCommandFilename]];
    // 先把命令文件改名（原子），再读改名后的文件：处理期间 App 的新命令
    // 总是写到原路径，不会被下面的删除/清理误伤；rename 后 App 原子写
    // （writeToFile:atomically: 是临时文件+rename）也不会与本次消费交错。
    NSString *consumingPath = [commandPath stringByAppendingString:@".consuming"];
    BOOL moved = NO;
    for (int attempt = 0; attempt < 3; attempt++) {
        if ([self.fileManager moveItemAtPath:commandPath toPath:consumingPath error:nil]) {
            moved = YES;
            break;
        }
        // App 原子写（临时文件+rename）瞬间原路径短暂缺失，稍候重试。
        [NSThread sleepForTimeInterval:0.05];
    }
    if (!moved) {
        DXLogClipboard(@"[MUBX][Clipboard][cmd] consume: 命令文件移动失败（可能无命令）");
        return; // 无未处理命令
    }
    NSArray *queue = [NSArray arrayWithContentsOfFile:consumingPath];
    if (![queue isKindOfClass:[NSArray class]] || queue.count == 0) {
        [self.fileManager removeItemAtPath:consumingPath error:nil];
        return;
    }

    NSUInteger lastSeq = [self.lastConsumedSeqByBundle[bundleID] unsignedIntegerValue];
    DXLogClipboard(@"[MUBX][Clipboard][cmd] consume: bundle=%@ count=%lu lastSeq=%lu",
                   bundleID, (unsigned long)queue.count, (unsigned long)lastSeq);
    BOOL changed = NO;
    for (NSDictionary *entry in queue) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSNumber *seq = entry[kClipboardCommandSeqKey];
        if (![seq isKindOfClass:[NSNumber class]]) continue;
        if ([seq unsignedIntegerValue] <= lastSeq) continue; // 已消费，防重放/重复广播
        NSString *logLine = entry[kClipboardCommandLogKey];
        if ([logLine isKindOfClass:[NSString class]] && logLine.length > 0) {
            DXLogClipboard(@"[MUBX][Clipboard][cmd] app: %@", logLine); // App 侧诊断行由 SB 落盘
        }
        BOOL executed = [self executeClipboardCommand:entry];
        if (executed) changed = YES;
        lastSeq = [seq unsignedIntegerValue];
        self.lastConsumedSeqByBundle[bundleID] = @(lastSeq);
    }

    // 清理已消费的命令文件（rename 后的 .consuming 副本）。
    [self.fileManager removeItemAtPath:consumingPath error:nil];

    if (changed) {
        [self publishSnapshot];
        notify_post([kClipboardChangedIdentifier UTF8String]);
    }
}

- (BOOL)executeClipboardCommand:(NSDictionary *)entry {
    NSString *action = entry[kClipboardCommandActionKey];
    if ([action isEqualToString:@"delete"]) {
        NSNumber *itemID = entry[kClipboardCommandItemIDKey];
        if (![itemID isKindOfClass:[NSNumber class]]) return NO;
        BOOL ok = [self.store deleteItemWithID:[itemID integerValue]];
        DXLogClipboard(@"[MUBX][Clipboard][cmd] delete itemID=%lld -> %d",
                       (long long)[itemID longLongValue], ok);
        return ok;
    }
    if ([action isEqualToString:@"setFavorite"]) {
        BOOL favorite = [entry[kClipboardCommandFavoriteKey] respondsToSelector:@selector(boolValue)]
            && [entry[kClipboardCommandFavoriteKey] boolValue];
        NSString *historyKey = entry[kClipboardCommandHistoryKeyKey];
        NSString *content = entry[kClipboardCommandContentKey];
        if (![historyKey isKindOfClass:[NSString class]]) historyKey = @"history";
        if (![content isKindOfClass:[NSString class]]) content = @"";
        BOOL ok = [self.store setFavorite:favorite historyKey:historyKey content:content];
        DXLogClipboard(@"[MUBX][Clipboard][cmd] setFavorite=%d historyKey=%@ contentLen=%lu -> %d",
                       favorite, historyKey, (unsigned long)content.length, ok);
        return ok;
    }
    if ([action isEqualToString:@"clear"]) {
        NSString *historyKey = entry[kClipboardCommandHistoryKeyKey];
        if (![historyKey isKindOfClass:[NSString class]]) historyKey = @"history";
        BOOL ok = [self.store clearHistoryKey:historyKey];
        DXLogClipboard(@"[MUBX][Clipboard][cmd] clear %@ -> %d", historyKey, ok);
        return ok;
    }
    DXLogClipboard(@"[MUBX][Clipboard][cmd] 未知命令 action=%@", action);
    return NO;
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
    if (![self.store prepareDatabase]) {
        NSLog(@"[MUBX][Clipboard][diag] publishSnapshot skipped: prepareDatabase failed");
        DXLogClipboard(@"[MUBX][Clipboard][diag] publishSnapshot skipped: prepareDatabase failed");
        return;
    }

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
    BOOL domainOK = DXSetQuickActionSharedValue(snapshot, kClipboardSnapshotKey);
    // 共享快照文件：位于 jbroot 下 app 沙盒可读目录，普通 App 面板经此读取
    // （沙盒进程读不到 cfprefsd 隔离域，只能经文件交换，机制同 shared.plist）。
    DXWriteSharedPlistFile(snapshot, MUBXClipboardSnapshotPath);
    NSDictionary *written = DXReadSharedPlistFile(MUBXClipboardSnapshotPath);
    BOOL fileOK = [written[@"updated"] isEqual:snapshot[@"updated"]];
    NSLog(@"[MUBX][Clipboard][diag] publishSnapshot domain=%d file=%d (%lu history, %lu favorites) -> %@",
          domainOK, fileOK, (unsigned long)history.count, (unsigned long)favorites.count,
          MUBXClipboardSnapshotPath);
    DXLogClipboard(@"[MUBX][Clipboard][diag] publishSnapshot domain=%d file=%d (%lu history, %lu favorites) -> %@",
                   domainOK, fileOK, (unsigned long)history.count, (unsigned long)favorites.count,
                   MUBXClipboardSnapshotPath);
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

@end