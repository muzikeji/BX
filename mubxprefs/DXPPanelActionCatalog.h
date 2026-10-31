#pragma once
#import "../common.h"
#import "../DXHelper.h"
#import "../DXShortcutsGenerator.h"
#import "../DXPanelRegistry.h"

static inline NSArray<NSDictionary *> *DXPPanelBuiltInActions(void) {
    DXShortcutsGenerator *generator = DXShortcutsGenerator.sharedInstance;
    NSArray *selectors = generator.selectorNames, *icons = [generator imageNameArrayForiOS:1];
    NSMutableArray *actions = [NSMutableArray array];
    for (NSUInteger i = 0; i < selectors.count; i++) {
        NSString *selector = selectors[i];
        if (![DXShortcutsGenerator isVisibleShortcutSelector:selector]) continue;
        if ([selector isEqual:@"shellxScreenshotAction:"] && ![DXShortcutsGenerator isShellXScreenshotAvailable]) continue;
        // MUBX 已内置剪贴板历史（DXClipboardPanel），剪贴板按钮始终可用。
        if ([selector isEqual:@"pulloverWakeAction:"] && ![DXShortcutsGenerator isPullOverXInstalled]) continue;
        NSString *name = [DXHelper localizedStringForActionNamed:selector shortName:NO bundle:[NSBundle bundleWithPath:bundlePath]];
        NSString *icon = i < icons.count ? icons[i] : @"square.grid.2x2";
        [actions addObject:@{@"selector": selector, @"label": name ?: selector, @"name": name ?: selector, @"icon": icon, @"images12": icon, @"images13": icon}];
    }
    return actions;
}
static inline NSDictionary *DXPPanelDisplayDefinition(NSDictionary *preferences, NSString *selector) {
    NSDictionary *entry = DXPanelDisplayDefinition(preferences, selector) ?: DXPanelActionDefinition(preferences, selector);
    if (entry) return entry;
    for (NSDictionary *action in DXPPanelBuiltInActions()) if ([action[@"selector"] isEqual:selector]) return action;
    return nil;
}
