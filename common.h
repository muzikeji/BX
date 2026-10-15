#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#if defined(THEOS_PACKAGE_SCHEME_ROOTHIDE)
#import <roothide.h>
#define DX_ROOT_PATH_NS(path) jbroot(path)
#else
#import <rootless.h>
#define DX_ROOT_PATH_NS(path) ROOT_PATH_NS(path)
#endif
#import <spawn.h>

@class CPDistributedMessagingCenter;

#import "DXPrefsManager.h"

#define bundlePath DX_ROOT_PATH_NS(@"/Library/PreferenceBundles/TypeXPrefs.bundle")
//#define typexBundlePath @"/Library/Application Support/TypeX.bundle"
#define LOCALIZED(str) [tweakBundle localizedStringForKey:str value:@"" table:nil]

#define kIdentifier @"com.lindo.typex"
#define kIPCCenterPrefsManager @"com.lindo.typex.prefsmanager"
#define kIPCCenterTypeX @"com.lindo.typex"
#define kPrefsChangedIdentifier @"com.lindo.typex/prefschanged"
#define kPrefsPath @"/var/mobile/Library/Preferences/com.lindo.typex.plist"

#define kEnabledkey @"enabledBOOL"
#define kEnabledHaptickey @"hapticBOOL"
#define kShortcutskey @"shortcuts"
#define kTopShortcutskey @"topshortcuts"
#define kColorEnabledkey @"colorBOOL"
#define kToggledOnkey @"toggledOnBOOL"
#define kDedicatedGestureButtonkey @"gesturebutton"
#define kGestureTypekey @"gesturetype"
#define kCustomActionskey @"customactions"
#define kTopCustomActionskey @"topcustomactions"
#define kTapCustomActionskey @"tapactions"
#define kSwipeUpCustomActionskey @"swipeupactions"
#define kSwipeDownCustomActionskey @"swipedownactions"
#define kSwipeLeftCustomActionskey @"swipeleftactions"
#define kSwipeRightCustomActionskey @"swiperightactions"
// User-defined actions shown above the built-in actions in every gesture
// picker. Definitions are global so the same ordered list is available to the
// top and bottom toolbar configurations.
#define kLinkActionskey @"linkactions"
#define kLinkActionSelectorPrefix @"__typex_link_action_"
// 自定义动作分组：条目上的可选组名 + 有序分组注册表（管理与选择页展示专用，
// 执行路径不读取）。
#define kLinkActionGroupsKey @"linkactiongroups"
#define kCustomActionGroupKey @"group"
#define kLinkActionCollapsedGroupsKey @"linkactioncollapsedgroups"

// Custom action types, stored on each linkactions entry under "type".  An
// entry without a type is a legacy definition and keeps the old behavior of
// auto-detecting web URL / URL scheme / bundle identifier from its link.
// "url" additionally stores the APP内打开 choice under "inapp" (default YES).
// Entries whose payload supports @@@ (legacy / url / urlscheme) store the
// 剪切替换 choice under "cutreplace": ON clears the input field after its
// text is passed in (cut), OFF keeps the field's content (copy, default).
#define kCustomActionTypeKey @"type"
#define kCustomActionInAppKey @"inapp"
#define kCustomActionUsePullOverKey @"pullover"
#define kCustomActionFloatingKey @"floating"
#define kCustomActionCutReplaceKey @"cutreplace"
#define kCustomActionTypeURLScheme @"urlscheme"
#define kCustomActionTypeText @"text"
// Ordered literal text records; text actions never read the old link payload.
#define kCustomActionTextRecordsKey @"textrecords"
#define kCustomActionTypeURL @"url"
#define kCustomActionTypeOpenApp @"openapp"
#define kCustomActionTypeShortcut @"shortcut"
#define kCustomActionTypeJavaScript @"javascript"
#define kCustomActionTypeSystem @"system"
#define kCustomActionSystemIdentifierKey @"systemaction"
// Quick actions persist the owning bundle in "link" and the stable item type.
#define kCustomActionShortcutTypeKey @"shortcuttype"
#define kCustomActionShortcutTitleKey @"shortcuttitle"
// Legacy tap-mode flag, read only to preserve configurations from older builds.
#define kTapSubActionsEntryKey @"tapsubactions"

#define kSubActionskey @"subactions"
#define kTopSubActionskey @"topsubactions"
#define kShortcutsTintEnabled @"shortcutstintBOOL"
#define kShortcutsBackgroundTintEnabled @"shortcutsbackgroundtintBOOL"
#define kPasteAndGoEnabledkey @"pasteandgo"
#define kHeightOffsetkey @"heightoffset"
#define kEnabledSmartDeleteForwardkey @"smartdeleteforwardBOOL"
#define kShortLabelEnabledKey @"shortLabelBOOL"
#define kCellHeightkey @"shortcutheight"
#define kCellRadiuskey @"shortcutradius"
#define kCellSpacingkey @"shortcutspacing"
#define kBottomSpacingKey @"bottomspacing"
#define kCellBorderEnabledkey @"shortcutborderBOOL"
#define kCellBorderWidthkey @"shortcutborderwidth"
#define kButtonWidthScalekey @"shortcutwidthscale"
#define kSubActionPanelScaleKey @"subactionpanelscale"
// 悬浮打开应用小窗的默认最大占屏比例（百分比存储，如 72 = 72%）。
#define kFloatingCardMaxScaleKey @"floatingcardmaxscale"
// 悬浮打开应用小窗的默认水平停靠位置（0=居左 1=居中 2=居右，缺省居中）。
#define kFloatingCardPositionKey @"floatingcardposition"
// One mode switch: shelf replaces only the keyboard bottom action toolbar.
#define kFloatingShelfEnabledKey @"floatingappshelfBOOL"
// 顶部工具栏固定按"每行个数"换行，第一行紧贴键盘、第二行向上堆叠。
// 行距只作用于两行之间；旧的多行开关不再参与布局或容量计算。
#define kButtonsPerRowKey @"buttonsperrow"
#define kMultiRowSpacingKey @"multirowspacing"
#define buttonsPerRowDefault 6.0f
#define multiRowSpacingDefault 4.0f
#define maxMultiRowRows 2
// A toolbar stores any number of records; its active capacity is one surface.
// The top surface contains one or two rows of the configured column count.
#define maxEnabledTopButtons 16
#define maxMultiRowButtons maxEnabledTopButtons
#define kSpongebobEntropyKey @"spongebobEntropy"
// Clipboard image quick paste: floating thumbnail above the keyboard +
// auto-answering of the iOS 16+ paste-permission alert, one switch for both.
#define kPasteImageChipKey @"pasteimagechipBOOL"
// BundleID -> @YES map of apps where the paste chip may appear. A missing key
// or an entry without the host bundle ID means off: the per-app switches in
// Settings all default to off.
#define kPasteImageChipAppsKey @"pasteimagechipapps"
#define kbuttonsImages12 0
#define kbuttonsImages13 1
#define kselectors 2
#define kshortLabel 4

#define tweakVersion @"1.3.1"
#define maxdefaultshortcuts 6
// The fixed bottom toolbar has one surface with up to eight active buttons.
#define maxEnabledBottomButtons 8


#define heightOffsetDefault 60.0f
// Bottom dock geometry shared by the live toolbar and its Settings preview.
#define DXBottomToolbarLeadingInset 69.0f
#define DXBottomToolbarTrailingInset 60.0f
#define DXBottomToolbarBottomInset 22.0f
#define DXBottomToolbarCellTopInset 22.0f

#define searchedCountEaster 100

#define spacingBetweenCellsDefault 3
#define topBottomSpacingDefault 0.0f
#define cellsHeightDefault 30
#define cellsRadiusDefault 5

#define buttonBorderWidthDefault 1.0f
#define buttonWidthScaleDefault 100.0f
#define subActionPanelScaleDefault 100.0f

// The shared snapshot must live where sandboxed app hosts can read it.  The
// jailbreak root (/var/jb on rootless, resolved by DX_ROOT_PATH_NS) is readable
// from inside app sandboxes -- this tweak already loads its bundle resources
// from /var/jb/Library -- while /var/mobile/Library/** is not.  The package
// stages the directory world-writable (no sticky bit: mobile writers must be
// able to atomically replace the root-owned seed file) so mobile processes
// (Settings, SpringBoard) can refresh the snapshot without a helper daemon.
#define TypeXCachePath DX_ROOT_PATH_NS(@"/Library/TypeX")
#define TypeXSharedPrefsPath DX_ROOT_PATH_NS(@"/Library/TypeX/shared.plist")

// Settings and SpringBoard exchange quick-action data through an isolated
// CFPreferences domain. On RootHide iOS 16, SpringBoard can read shared files
// but its sandbox rejects direct writes under /Library/TypeX; cfprefsd provides
// the supported cross-process persistence path. Requests carry
// {format: 3, requestID, bundles}; responses replace one complete generation.
#define TypeXQuickActionDomain @"com.lindo.typex.quickactions"
#define TypeXQuickActionRequestKey @"request-v3"
#define TypeXQuickActionStatusKey @"status-v3"
#define TypeXQuickActionSnapshotKey @"snapshot-v3"
#define kShortcutRefreshRequestIdentifier @"com.lindo.typex/shortcutrefresh"
#define kShortcutSnapshotChangedIdentifier @"com.lindo.typex/shortcutschanged"

// TypeX 自带 AI 面板通道：工具栏进程只写请求（{format:2, requestID, created,
// mode: text|image|empty, origin: sb|app, text?}），SpringBoard 端收到 Darwin
// 通知后整包读取并在 SB 进程内创建 DXAIPanel 悬浮窗。面板不能在键盘进程承载：
// 窗口会被限制在键盘宿主区域内（第三方键盘扩展里完全无法悬浮）。与快捷方式
// 目录共用隔离域，避免再开共享面。
#define TypeXAIChatRequestKey @"ai-chat-request"
#define kAIChatRequestIdentifier @"com.lindo.typex/aichat"

// Complete SpringBoard-authored snapshot of each app's current static and
// dynamic UIApplicationShortcutItems. The value is replaced as one generation,
// so removed apps and actions cannot survive an incremental merge:
//   {format: 3, generation: requestID, updated: time,
//    apps: {bundleID: {name, items: [{type, title, subtitle, source}]}}}

static inline id DXQuickActionSharedValue(NSString *key) {
    CFStringRef domain = (__bridge CFStringRef)TypeXQuickActionDomain;
    CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    return CFBridgingRelease(CFPreferencesCopyValue((__bridge CFStringRef)key,
                                                    domain,
                                                    kCFPreferencesCurrentUser,
                                                    kCFPreferencesAnyHost));
}

static inline BOOL DXSetQuickActionSharedValue(id value, NSString *key) {
    CFStringRef domain = (__bridge CFStringRef)TypeXQuickActionDomain;
    CFPreferencesSetValue((__bridge CFStringRef)key,
                          (__bridge CFPropertyListRef)value,
                          domain,
                          kCFPreferencesCurrentUser,
                          kCFPreferencesAnyHost);
    return CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
}

// Reverse-DNS shape test shared with the SpringBoard-side request handler so
// the channel can never be coerced into acting on a non-identifier payload.
static inline BOOL DXIsValidBundleIdentifier(NSString *value) {
    if (![value isKindOfClass:[NSString class]] || value.length == 0) return NO;
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:@"^[A-Za-z0-9_](?:[A-Za-z0-9_-]*[A-Za-z0-9_])?(?:\\.[A-Za-z0-9_](?:[A-Za-z0-9_-]*[A-Za-z0-9_])?)+$"
                                                                                options:0
                                                                                  error:nil];
    return [expression firstMatchInString:value options:0 range:NSMakeRange(0, value.length)] != nil;
}

static inline BOOL DXIsValidAppShortcutType(NSString *value) {
    return [value isKindOfClass:NSString.class] && value.length > 0 && value.length <= 512 &&
        ![value hasPrefix:@"com.apple.springboard."] &&
        [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}

// Shared URL-shape test for the openurl channel action (and the scheme
// classification of custom-action links): a scheme-shaped URL of bounded
// length whose scheme is not an executable/document one (javascript:, data:,
// file:, about:), so the channel can never be coerced beyond "open this URL".
static inline BOOL DXIsOpenableSchemeURLString(NSString *value) {
    if (![value isKindOfClass:[NSString class]] || value.length == 0 || value.length > 2048) return NO;
    NSRange schemeRange = [value rangeOfString:@"^[A-Za-z][A-Za-z0-9+.-]*:" options:NSRegularExpressionSearch];
    if (schemeRange.location != 0) return NO;
    NSURL *url = [NSURL URLWithString:value];
    if (!url || url.scheme.length == 0) return NO;
    NSString *lowercaseScheme = url.scheme.lowercaseString;
    return ![lowercaseScheme isEqualToString:@"javascript"] &&
        ![lowercaseScheme isEqualToString:@"data"] &&
        ![lowercaseScheme isEqualToString:@"file"] &&
        ![lowercaseScheme isEqualToString:@"about"];
}

static inline NSString *DXScopedPreferenceKey(NSString *baseKey, NSString *configuration) {
    if ([configuration isEqualToString:@"top"]) {
        return [@"top" stringByAppendingString:baseKey];
    }
    return baseKey;
}

static inline NSInteger DXMultiRowButtonsPerRowFromPreferences(NSDictionary *preferences) {
    id value = [preferences isKindOfClass:[NSDictionary class]]
        ? preferences[DXScopedPreferenceKey(kButtonsPerRowKey, @"top")] : nil;
    NSInteger perRow = [value respondsToSelector:@selector(integerValue)]
        ? [value integerValue] : (NSInteger)buttonsPerRowDefault;
    return MIN(8, MAX(1, perRow));
}

// Two rows are the hard layout limit. The configured per-row count can lower
// the active capacity, while eight columns keep the absolute ceiling at 16.
static inline NSInteger DXMultiRowCapacityForPreferences(NSDictionary *preferences) {
    return MIN(maxMultiRowButtons,
               DXMultiRowButtonsPerRowFromPreferences(preferences) * maxMultiRowRows);
}

// 悬浮小窗布局把自动适配比例封顶在这个配置值上（0.30–1.00，缺省 0.72）。
// 非法值（含 NaN）一律回退缺省，读配置失败不产生危险布局。
static inline CGFloat DXFloatingCardMaxScaleFromPreferences(NSDictionary *preferences) {
    id value = [preferences isKindOfClass:[NSDictionary class]] ? preferences[kFloatingCardMaxScaleKey] : nil;
    CGFloat scale = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] / 100.0 : 0.72;
    if (!(scale >= 0.30) || scale > 1.0) scale = 0.72;
    return scale;
}

// 悬浮小窗打开时的默认水平位置：0=居左、1=居中、2=居右。非法值一律回退居中。
static inline NSInteger DXFloatingCardPositionFromPreferences(NSDictionary *preferences) {
    id value = [preferences isKindOfClass:[NSDictionary class]] ? preferences[kFloatingCardPositionKey] : nil;
    NSInteger position = [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 1;
    return (position >= 0 && position <= 2) ? position : 1;
}

// With paging removed, every enabled button must fit the current toolbar surface.
static inline NSInteger DXToolbarCapacityForPreferences(NSDictionary *preferences, NSString *configuration) {
    if (![configuration isEqualToString:@"top"]) return maxEnabledBottomButtons;
    return DXMultiRowCapacityForPreferences(preferences);
}

static inline NSArray *DXToolbarOrderFittingCapacity(NSArray *order, NSDictionary *preferences, NSString *configuration) {
    if (![order isKindOfClass:NSArray.class] || order.count < 2 ||
        ![order[0] isKindOfClass:NSArray.class] || ![order[1] isKindOfClass:NSArray.class]) return order;
    NSInteger remaining = DXToolbarCapacityForPreferences(preferences, configuration);
    NSMutableArray *buttons = [NSMutableArray array];
    for (id item in order[0]) {
        if (![item isKindOfClass:NSDictionary.class] || [item[@"disabled"] boolValue]) {
            [buttons addObject:item];
            continue;
        }
        if (remaining-- > 0) [buttons addObject:item];
        else {
            NSMutableDictionary *disabled = [item mutableCopy];
            disabled[@"disabled"] = @YES;
            [buttons addObject:disabled];
        }
    }
    return @[[buttons copy], order[1]];
}

// Fields whose text was set programmatically start editing with the caret at
// the leading edge; park it past the existing text so a tap continues typing
// where the text ends. Works for UITextField and UITextView alike.
static inline void DXPlaceCaretAtEnd(id<UITextInput> field) {
    if (![field conformsToProtocol:@protocol(UITextInput)]) return;
    UITextPosition *end = field.endOfDocument;
    field.selectedTextRange = [field textRangeFromPosition:end toPosition:end];
}

// Each gesture has an independent ordered action list. Long press retains
// the historical "customactions" key; tap and each swipe use their own keys.
typedef NS_ENUM(NSInteger, DXShortcutGestureType) {
    DXShortcutGestureLongPress = 0,
    DXShortcutGestureSwipeUp = 1,
    DXShortcutGestureSwipeDown = 2,
    DXShortcutGestureSwipeLeft = 3,
    DXShortcutGestureSwipeRight = 4,
    DXShortcutGestureTap = 5,
};

// Temporary identifier used by the "add button" flow: the entry written into
// the tap store before the new button's action (and therefore its real
// identifier) exists. Rewritten to the real selector once the user picks one.
#define kNewButtonPendingIdentifier @"__typex_pending_new_button__"

// Buttons saved without a tap action get a synthetic identifier so gesture
// stores never collide between them. They render on the toolbar but stay
// inert until a tap action is configured for them.
#define kDraftActionPrefix @"__typexdraft_"

static inline BOOL DXIsDraftActionSelector(NSString *selector) {
    return [selector isKindOfClass:[NSString class]] && [selector hasPrefix:kDraftActionPrefix];
}

static inline BOOL DXIsLinkActionSelector(NSString *selector) {
    return [selector isKindOfClass:[NSString class]] && [selector hasPrefix:kLinkActionSelectorPrefix];
}

static inline NSString *DXCustomActionsKeyForGesture(int gestureType, NSString *configuration) {
    NSString *baseKey;
    switch (gestureType) {
        case DXShortcutGestureTap: baseKey = kTapCustomActionskey; break;
        case DXShortcutGestureSwipeUp: baseKey = kSwipeUpCustomActionskey; break;
        case DXShortcutGestureSwipeDown: baseKey = kSwipeDownCustomActionskey; break;
        case DXShortcutGestureSwipeLeft: baseKey = kSwipeLeftCustomActionskey; break;
        case DXShortcutGestureSwipeRight: baseKey = kSwipeRightCustomActionskey; break;
        default: baseKey = kCustomActionskey; break;
    }
    return DXScopedPreferenceKey(baseKey, configuration);
}

// Shared by Settings and toolbar hosts. New gesture entries store an ordered
// selectors array; an explicit empty array disables the gesture and must never
// resurrect a legacy/default action. Legacy preferences are read without writes.
static inline NSArray<NSString *> *DXGestureActionSelectors(NSDictionary *preferences, NSString *identifier,
                                                          int gestureType, NSString *configuration) {
    if (![preferences isKindOfClass:[NSDictionary class]] ||
        ![identifier isKindOfClass:[NSString class]] || identifier.length == 0) return @[];
    id stored = preferences[DXCustomActionsKeyForGesture(gestureType, configuration)];
    NSDictionary *legacyEntry = nil;
    if ([stored isKindOfClass:[NSArray class]]) {
        for (NSDictionary *entry in stored) {
            if (![entry isKindOfClass:[NSDictionary class]] || ![entry[@"identifier"] isEqual:identifier]) continue;
            if (entry[@"selectors"] != nil) {
                NSMutableArray *selectors = [NSMutableArray array];
                id values = entry[@"selectors"];
                if ([values isKindOfClass:[NSArray class]]) {
                    for (id value in values) {
                        if ([value isKindOfClass:[NSString class]] && [value length] > 0) [selectors addObject:value];
                    }
                }
                return selectors;
            }
            if (!legacyEntry) legacyEntry = entry;
        }
    }

    BOOL usesLegacySubActions = gestureType == DXShortcutGestureLongPress;
    if (gestureType == DXShortcutGestureTap) {
        id sections = preferences[DXScopedPreferenceKey(kShortcutskey, configuration)];
        if ([sections isKindOfClass:[NSArray class]]) {
            for (id section in sections) {
                if (![section isKindOfClass:[NSArray class]]) continue;
                for (NSDictionary *entry in section) {
                    if (![entry isKindOfClass:[NSDictionary class]] || ![entry[@"selector"] isEqual:identifier]) continue;
                    id flag = entry[kTapSubActionsEntryKey];
                    usesLegacySubActions = [flag respondsToSelector:@selector(boolValue)] && [flag boolValue];
                }
            }
        }
    }
    if (usesLegacySubActions) {
        NSMutableArray *selectors = [NSMutableArray array];
        id entries = preferences[DXScopedPreferenceKey(kSubActionskey, configuration)];
        if ([entries isKindOfClass:[NSArray class]]) {
            for (NSDictionary *entry in entries) {
                if (![entry isKindOfClass:[NSDictionary class]] || ![entry[@"identifier"] isEqual:identifier]) continue;
                id selector = entry[@"selector"];
                if ([selector isKindOfClass:[NSString class]] && [selector length] > 0) [selectors addObject:selector];
            }
        }
        // The previous runtime ignored the old long-press single-action store.
        return selectors;
    }

    id selector = legacyEntry[@"selector2"] ?: legacyEntry[@"selector"];
    if ([selector isKindOfClass:[NSString class]] && [selector length] > 0) return @[selector];
    if (gestureType == DXShortcutGestureTap && !DXIsDraftActionSelector(identifier) &&
        ![identifier isEqualToString:kNewButtonPendingIdentifier]) return @[identifier];
    return @[];
}

static inline UIColor *DXColorFromHex(NSString *value, NSString *fallback) {
    NSString *hex = [value isKindOfClass:[NSString class]] ? value : fallback;
    hex = [hex stringByReplacingOccurrencesOfString:@"#" withString:@""];
    unsigned int color = 0;
    NSScanner *scanner = [NSScanner scannerWithString:hex];
    if (![scanner scanHexInt:&color]) hex = [fallback stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (hex.length == 6) {
        scanner = [NSScanner scannerWithString:hex];
        [scanner scanHexInt:&color];
        return [UIColor colorWithRed:((color >> 16) & 0xff) / 255.0
                               green:((color >> 8) & 0xff) / 255.0
                                blue:(color & 0xff) / 255.0
                               alpha:1.0];
    }
    if (hex.length == 8) {
        scanner = [NSScanner scannerWithString:hex];
        [scanner scanHexInt:&color];
        return [UIColor colorWithRed:((color >> 16) & 0xff) / 255.0
                               green:((color >> 8) & 0xff) / 255.0
                                blue:(color & 0xff) / 255.0
                               alpha:((color >> 24) & 0xff) / 255.0];
    }
    return [UIColor redColor];
}

static inline void DXRunShellCommand(NSString *command) {
    if (command.length == 0) return;

    const char *shell = "/bin/bash";
    const char *arguments[] = {shell, "-c", command.UTF8String, NULL};
    pid_t pid = 0;
    extern char **environ;
    posix_spawn(&pid, shell, NULL, NULL, (char *const *)arguments, environ);
}

static inline UIInterfaceOrientation DXCurrentInterfaceOrientation(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIInterfaceOrientation orientation = ((UIWindowScene *)scene).interfaceOrientation;
                if (orientation != UIInterfaceOrientationUnknown) return orientation;
            }
        }
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return UIApplication.sharedApplication.statusBarOrientation;
#pragma clang diagnostic pop
}

static inline UIWindow *DXKeyWindow(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.isKeyWindow) return window;
            }
        }
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window.isKeyWindow) return window;
    }
#pragma clang diagnostic pop
    return nil;
}

typedef NS_ENUM(NSInteger, DXPhonemesType){
    DXPhonemesTypeVowel,
    DXPhonemesTypeConsonent
};

typedef NS_ENUM(NSInteger, DXStudlyCapsType){
    DXStudlyCapsTypeRandom,
    DXStudlyCapsTypeAlternate,
    DXStudlyCapsTypeVowel,
    DXStudlyCapsTypeConsonent
};

@interface CPDistributedMessagingCenter : NSObject
+ (id)centerNamed:(id)arg1;
- (void)runServerOnCurrentThread;
- (void)registerForMessageName:(id)arg1 target:(id)arg2 selector:(SEL)arg3;
- (BOOL)sendMessageName:(id)arg1 userInfo:(id)arg2;
- (NSDictionary *)sendMessageAndReceiveReplyName:(id)arg1 userInfo:(id)arg2;
@end

@interface UIKeyboardEmojiCollectionInputView : NSObject {
    unsigned long long  _currentSection;
    double  _frameInset;
    bool  _hasShownAnimojiCell;
    bool  _hasShownAnimojiFirstTimeExperience;
    bool  _inputDelegateCanSupportAnimoji;
    bool  _isDraggingInputView;
    bool  _shouldRetryFetchingAnimojiRecents;
    NSIndexPath * _tappedSkinToneEmoji;
    bool  _useWideAnimojiCell;
}
@end

@interface SBSRelaunchAction : NSObject
@property (nonatomic, readonly) unsigned long long options;
@property (nonatomic, readonly, copy) NSString *reason;
@property (nonatomic, readonly, retain) NSURL *targetURL;
+ (id)actionWithReason:(id)arg1 options:(unsigned long long)arg2 targetURL:(id)arg3;
- (id)initWithReason:(id)arg1 options:(unsigned long long)arg2 targetURL:(id)arg3;
- (unsigned long long)options;
- (id)reason;
- (id)targetURL;

@end

@interface FBSSystemService : NSObject
+ (id)sharedService;
- (void)sendActions:(id)arg1 withResult:(/*^block*/id)arg2;
- (void)openApplication:(NSString *)bundleIdentifier
                options:(NSDictionary *)options
             withResult:(void (^)(NSError *error))result;
@end

// FrontBoard open path that accepts an FBSOpenApplicationRequest; the raw
// bundle-identifier string form on FBSSystemService is rejected on current iOS.
@interface FBSOpenApplicationOptions : NSDictionary
+ (id)optionsWithDictionary:(NSDictionary *)dictionary;
@end

@interface FBSOpenApplicationRequest : NSObject
+ (id)requestWithBundleIdentifier:(NSString *)bundleIdentifier;
@end

@interface FBSOpenApplicationService : NSObject
+ (id)sharedService;
- (void)openApplication:(id)request
                options:(id)options
      withResultHandler:(void (^)(NSError *error))resultHandler;
@end
