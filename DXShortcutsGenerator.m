#import "common.h"
#import "DXShortcutsGenerator.h"
#import "DXPixPinIntegration.h"

static const NSBundle *tweakBundle;

@implementation DXShortcutsGenerator

+(BOOL)isAvailableShortcutSelector:(NSString *)selector {
    if (![selector isKindOfClass:[NSString class]]) return NO;
    static NSSet *selectors;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        selectors = [NSSet setWithArray:[[self sharedInstance] selectorNames]];
    });
    return [selectors containsObject:selector];
}

+(BOOL)isVisibleShortcutSelector:(NSString *)selector {
    if (![self isAvailableShortcutSelector:selector]) return NO;
    if ([selector isEqualToString:@"pixpinScreenshotAction:"] && ![self isPixPinScreenshotAvailable]) return NO;

    // These actions remain executable for existing preferences, but stay out of
    // the shortcut/action picker for new configurations.
    static NSSet *legacyHiddenSelectors;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        legacyHiddenSelectors = [NSSet setWithArray:@[@"runCommandAction:", @"spongebobAction:"]];
    });
    return ![legacyHiddenSelectors containsObject:selector];
}

// ShellX 截图相关入口仅在插件文件实际安装时出现。不要用偏好域判断：
// 卸载后偏好可能残留，而且用户要求即使 ShellX 总开关关闭也按“已安装”显示。
+(BOOL)isShellXScreenshotAvailable{
    NSString *dylibPath = DX_ROOT_PATH_NS(@"/Library/MobileSubstrate/DynamicLibraries/ScreenshotShell.dylib");
    return dylibPath.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:dylibPath];
}

+(BOOL)isPixPinScreenshotAvailable{
    return DXPixPinInstalledAtPath(DX_ROOT_PATH_NS(DXPixPinDylibPath));
}

// Kayoko / KayokoX（剪贴板管理器）安装探测，惯例同上不用偏好域（卸载可能残留）。
// 不逐名硬编码：枚举注入目录，文件名大小写不敏感地以 kayoko 开头即算已安装，
// 一并覆盖 Kayoko.dylib / KayokoCore.dylib / KayokoHelper.dylib / KayokoX.dylib。
+(BOOL)isKayokoInstalled{
    NSString *dir = DX_ROOT_PATH_NS(@"/Library/MobileSubstrate/DynamicLibraries");
    if (dir.length == 0) return NO;
    NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    for (NSString *name in names) {
        if (name.length >= 6 && [[name lowercaseString] hasPrefix:@"kayoko"]) return YES;
    }
    return NO;
}

// PullOver X (com.mlgm.pulloverx) 安装探测，惯例同上：认 dylib 文件不认偏好域。
+(BOOL)isPullOverXInstalled{
    NSString *dylibPath = DX_ROOT_PATH_NS(@"/Library/MobileSubstrate/DynamicLibraries/PullOverX.dylib");
    return dylibPath.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:dylibPath];
}

+(void)load{
    @autoreleasepool {
        NSArray *args = [[NSClassFromString(@"NSProcessInfo") processInfo] arguments];
        
        if (args.count != 0) {
            NSString *executablePath = args[0];
            
            if (executablePath) {
                NSString *processName = [executablePath lastPathComponent];
                
                BOOL isSpringBoard = [processName isEqualToString:@"SpringBoard"];
                BOOL isApplication = [executablePath rangeOfString:@"/Application"].location != NSNotFound;
                
                if (isSpringBoard || isApplication) {
                    tweakBundle = [NSBundle bundleWithPath:bundlePath];
                    [tweakBundle load];
                    [DXShortcutsGenerator sharedInstance];
                    
                }
            }
        }
    }
}

+(instancetype)sharedInstance{
    static dispatch_once_t predicate;
    static DXShortcutsGenerator *generator;
    dispatch_once(&predicate, ^{ generator = [[self alloc] init]; });
    return generator;
}

-(instancetype)init{
    self = [super init];
    if (self) {
        // MUBX only exposes its built-in keyboard actions.
    }
    return self;
}

-(NSArray *)imageNameArrayForiOS:(NSInteger)iosVersion{
    // 0 = iOS 12
    // 1 = iOS 13+
    NSArray *array;
    if (iosVersion == 0){
        array = @[@"UIButtonBarListIcon",@"UIButtonBarKeyboardCopy",@"UIButtonBarKeyboardPaste",@"UIButtonBarKeyboardCut",@"UIButtonBarKeyboardUndo",@"UIButtonBarKeyboardRedo", @"UIButtonBarKeyboardItalic", @"UIButtonBarArrowLeft", @"UIButtonBarArrowRight", @"delete_portrait", @"bold_dismiss_landscape", @"Black_BreadcrumbArrowLeft", @"Black_BreadcrumbArrowRight", @"KeyGlyph-upArrow-large", @"KeyGlyph-downArrow-large", @"UITabBarSearchTemplate", @"KeyGlyph-command-large", @"UICalloutBarPreviousArrow", @"UICalloutBarNextArrow", @"KeyGlyph-rtlTab-large", @"KeyGlyph-tab-large", @"KeyGlyph-return-large", @"KeyGlyph-rtlReturn-large", @"UIMovieScrubberEditingGlassLeft", @"UIMovieScrubberEditingGlassRight", @"UIRemoveControlMinusStroke", @"UITableGrabber", @"UIButtonBarListIcon", @"delete_portrait", @"delete_portrait", @"bold_emoji_activity", @"delete_portrait", @"UIButtonBarListIcon", @"UIButtonBarListIcon", @"KeyGlyph-command-large", @"UIButtonBarListIcon", @"UITableGrabber"];
    }else{
        array = @[@"doc.text",@"doc.on.doc",@"doc.on.clipboard",@"scissors",@"arrow.uturn.left.circle",@"arrow.uturn.right.circle", @"text.cursor", @"chevron.left.circle", @"chevron.right.circle", @"delete.left", @"keyboard.chevron.compact.down", @"arrowtriangle.left.circle.fill", @"arrowtriangle.right.circle.fill", @"arrowtriangle.up.circle.fill", @"arrowtriangle.down.circle.fill", @"doc.text.magnifyingglass", @"command", @"arrow.left.circle.fill", @"arrow.right.circle.fill", @"arrow.left.to.line", @"arrow.right.to.line", @"text.insert", @"text.append", @"decrease.quotelevel", @"increase.quotelevel", @"line.horizontal.3", @"paragraph", @"list.bullet", @"delete.right", @"clear", @"circle.grid.3x3", @"delete.left", @"camera.viewfinder", @"crop", @"sparkles", @"clipboard", @"rectangle.bottomthird.inset.filled"];
    }
    return array;
}

-(NSArray *)selectorNames{
    return @[@"selectAllAction:",@"copyAction:",@"pasteAction:",@"cutAction:",@"undoAction:",@"redoAction:", @"selectAction:", @"beginningAction:", @"endingAction:", @"deleteAction:", @"dismissKeyboardAction:", @"moveCursorLeftAction:", @"moveCursorRightAction:", @"moveCursorUpAction:", @"moveCursorDownAction:", @"defineAction:", @"runCommandAction:", @"moveCursorPreviousWordAction:", @"moveCursorNextWordAction:", @"moveCursorStartOfLineAction:", @"moveCursorEndOfLineAction:", @"moveCursorStartOfParagraphAction:", @"moveCursorEndOfParagraphAction:", @"moveCursorStartOfSentenceAction:", @"moveCursorEndOfSentenceAction:", @"selectLineAction:", @"selectParagraphAction:", @"selectSentenceAction:", @"deleteForwardAction:", @"deleteWordAction:", @"spongebobAction:", @"deleteAllAction:", @"shellxScreenshotAction:", @"pixpinScreenshotAction:", @"aiChatAction:", @"clipboardAction:", @"pulloverWakeAction:"];
}

-(NSArray *)labelName{
    NSArray *array = @[LOCALIZED(@"LONG_SELECT_ALL"), LOCALIZED(@"LONG_COPY"), LOCALIZED(@"LONG_PASTE"), LOCALIZED(@"LONG_CUT"), LOCALIZED(@"LONG_UNDO"), LOCALIZED(@"LONG_REDO"), LOCALIZED(@"LONG_SELECT"), LOCALIZED(@"LONG_BEGINNING"), LOCALIZED(@"LONG_ENDING"), LOCALIZED(@"LONG_DELETE"), LOCALIZED(@"LONG_DISMISS_KEYBOARD"), LOCALIZED(@"LONG_MOVE_CURSOR_LEFT"), LOCALIZED(@"LONG_MOVE_CURSOR_RIGHT"), LOCALIZED(@"LONG_MOVE_CURSOR_UP"), LOCALIZED(@"LONG_MOVE_CURSOR_DOWN"), LOCALIZED(@"LONG_DEFINE"), LOCALIZED(@"LONG_RUN_COMMAND"), LOCALIZED(@"LONG_MOVE_CURSOR_PREVIOUS_WORD"), LOCALIZED(@"LONG_MOVE_CURSOR_NEXT_WORD"), LOCALIZED(@"LONG_MOVE_CURSOR_START_OF_LINE"), LOCALIZED(@"LONG_MOVE_CURSOR_END_OF_LINE"), LOCALIZED(@"LONG_MOVE_CURSOR_START_OF_PARAGRAPH"), LOCALIZED(@"LONG_MOVE_CURSOR_END_OF_PARAGRAPH"), LOCALIZED(@"LONG_MOVE_CURSOR_START_OF_SENTENCE"), LOCALIZED(@"LONG_MOVE_CURSOR_END_OF_SENTENCE"), LOCALIZED(@"LONG_SELECT_LINE"), LOCALIZED(@"LONG_SELECT_PARAGRAPH"),LOCALIZED(@"LONG_SELECT_SENTENCE"), LOCALIZED(@"LONG_DELETE_FORWARD"), LOCALIZED(@"LONG_DELETE_WORD"), LOCALIZED(@"LONG_SPONGEBOB"), LOCALIZED(@"LONG_DELETE_ALL"), LOCALIZED(@"LONG_SHELLX_SCREENSHOT"), LOCALIZED(@"LONG_PIXPIN_SCREENSHOT"), LOCALIZED(@"LONG_AI_CHAT"), LOCALIZED(@"LONG_CLIPBOARD"), LOCALIZED(@"LONG_PULLOVER_WAKE")];
    return array;
}

-(NSArray *)shortenedlabelName{
    NSArray *array = @[LOCALIZED(@"SHORT_SELECT_ALL"), LOCALIZED(@"SHORT_COPY"), LOCALIZED(@"SHORT_PASTE"), LOCALIZED(@"SHORT_CUT"), LOCALIZED(@"SHORT_UNDO"), LOCALIZED(@"SHORT_REDO"), LOCALIZED(@"SHORT_SELECT"), LOCALIZED(@"SHORT_BEGINNING"), LOCALIZED(@"SHORT_ENDING"), LOCALIZED(@"SHORT_DELETE"), LOCALIZED(@"SHORT_DISMISS_KEYBOARD"), LOCALIZED(@"SHORT_MOVE_CURSOR_LEFT"), LOCALIZED(@"SHORT_MOVE_CURSOR_RIGHT"), LOCALIZED(@"SHORT_MOVE_CURSOR_UP"), LOCALIZED(@"SHORT_MOVE_CURSOR_DOWN"), LOCALIZED(@"SHORT_DEFINE"), LOCALIZED(@"SHORT_RUN_COMMAND"), LOCALIZED(@"SHORT_MOVE_CURSOR_PREVIOUS_WORD"), LOCALIZED(@"SHORT_MOVE_CURSOR_NEXT_WORD"), LOCALIZED(@"SHORT_MOVE_CURSOR_START_OF_LINE"), LOCALIZED(@"SHORT_MOVE_CURSOR_END_OF_LINE"), LOCALIZED(@"SHORT_MOVE_CURSOR_START_OF_PARAGRAPH"), LOCALIZED(@"SHORT_MOVE_CURSOR_END_OF_PARAGRAPH"), LOCALIZED(@"SHORT_MOVE_CURSOR_START_OF_SENTENCE"), LOCALIZED(@"SHORT_MOVE_CURSOR_END_OF_SENTENCE"), LOCALIZED(@"SHORT_SELECT_LINE"), LOCALIZED(@"SHORT_SELECT_PARAGRAPH"), LOCALIZED(@"SHORT_SELECT_SENTENCE"), LOCALIZED(@"SHORT_DELETE_FORWARD"), LOCALIZED(@"SHORT_DELETE_WORD"), LOCALIZED(@"SHORT_SPONGEBOB"), LOCALIZED(@"SHORT_DELETE_ALL"), LOCALIZED(@"SHORT_SHELLX_SCREENSHOT"), LOCALIZED(@"SHORT_PIXPIN_SCREENSHOT"), LOCALIZED(@"SHORT_AI_CHAT"), LOCALIZED(@"SHORT_CLIPBOARD"), LOCALIZED(@"SHORT_PULLOVER_WAKE")];
    return array;
}

+(NSArray<NSString *> *)builtInActionGroupOrder{
    return @[@"edit", @"delete", @"select", @"cursor", @"tools"];
}

+(NSString *)builtInActionGroupForSelector:(NSString *)selector{
    static NSDictionary<NSString *, NSArray<NSString *> *> *groups;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        groups = @{
            @"edit": @[@"copyAction:", @"pasteAction:", @"cutAction:", @"undoAction:", @"redoAction:"],
            @"delete": @[@"deleteAction:", @"deleteForwardAction:", @"deleteWordAction:", @"deleteAllAction:"],
            @"select": @[@"selectAllAction:", @"selectAction:", @"selectLineAction:", @"selectParagraphAction:", @"selectSentenceAction:"],
            @"cursor": @[@"beginningAction:", @"endingAction:", @"moveCursorLeftAction:", @"moveCursorRightAction:",
                         @"moveCursorUpAction:", @"moveCursorDownAction:", @"moveCursorPreviousWordAction:", @"moveCursorNextWordAction:",
                         @"moveCursorStartOfLineAction:", @"moveCursorEndOfLineAction:", @"moveCursorStartOfParagraphAction:",
                         @"moveCursorEndOfParagraphAction:", @"moveCursorStartOfSentenceAction:", @"moveCursorEndOfSentenceAction:"],
            @"tools": @[@"dismissKeyboardAction:", @"defineAction:", @"runCommandAction:", @"spongebobAction:",
                         @"shellxScreenshotAction:", @"pixpinScreenshotAction:", @"aiChatAction:", @"clipboardAction:", @"pulloverWakeAction:"],
        };
    });
    for (NSString *group in groups) if ([groups[group] containsObject:selector]) return group;
    return @"tools";
}


@end
