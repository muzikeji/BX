#pragma once
#import "DXKeyboardPanelPreferences.h"

#define kDXPanels @"panels"
#define kDXToolbarBindings @"toolbarpanelbindings"
#define DXPanelLinkSelectorPrefix @"__mubx_link_action_"
#define DXPanelSelectorPrefix @"__mubx_panel_"
#define DXPanelKeyboardKind @"keyboard"
#define DXPanelGestureKind @"gesture"

static inline NSString *DXPanelString(id value) { return [value isKindOfClass:NSString.class] ? value : @""; }
static inline BOOL DXPanelKindValid(id kind) { return [@[DXPanelKeyboardKind, DXPanelGestureKind] containsObject:kind ?: NSNull.null]; }
static inline NSString *DXPanelDefaultIconName(id kind) {
    return [kind isEqual:DXPanelKeyboardKind] ? @"keyboard" : @"hand.draw";
}
static inline NSString *DXPanelSelector(NSString *identifier) {
    return DXPanelString(identifier).length ? [DXPanelSelectorPrefix stringByAppendingString:identifier] : nil;
}
static inline BOOL DXIsPanelSelector(id selector) {
    return [selector isKindOfClass:NSString.class] && [selector hasPrefix:DXPanelSelectorPrefix] && [selector length] > DXPanelSelectorPrefix.length;
}
static inline NSArray<NSDictionary *> *DXPanelDefinitions(NSDictionary *preferences, NSString *kind) {
    id stored = preferences[kDXPanels];
    if (![stored isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *panels = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (id entry in stored) {
        if (![entry isKindOfClass:NSDictionary.class] || !DXPanelKindValid(entry[@"kind"])) continue;
        NSString *identifier = DXPanelString(entry[@"id"]);
        if (!identifier.length || identifier.length > 128 || [seen containsObject:identifier]) continue;
        [seen addObject:identifier];
        if (!kind || [entry[@"kind"] isEqual:kind]) [panels addObject:entry];
    }
    return panels;
}
static inline NSDictionary *DXPanelDefinition(NSDictionary *preferences, NSString *selector) {
    if (!DXIsPanelSelector(selector)) return nil;
    for (NSDictionary *panel in DXPanelDefinitions(preferences, nil))
        if ([DXPanelSelector(panel[@"id"]) isEqual:selector]) return panel;
    return nil;
}
// Display uses the type's icon; keep the stored definition intact for updates
// and deletion, including configurations with a legacy custom icon.
static inline NSDictionary *DXPanelDisplayDefinition(NSDictionary *preferences, NSString *selector) {
    NSDictionary *panel = DXPanelDefinition(preferences, selector);
    if (!panel) return nil;
    NSMutableDictionary *display = [panel mutableCopy];
    display[@"icon"] = DXPanelDefaultIconName(panel[@"kind"]);
    return display;
}
static inline BOOL DXPanelAllowed(NSDictionary *preferences, NSString *selector, NSString *kind) {
    return [DXPanelDefinition(preferences, selector)[@"kind"] isEqual:kind];
}
static inline NSDictionary *DXPanelActionDefinition(NSDictionary *preferences, NSString *selector) {
    if (![DXPanelString(selector) hasPrefix:DXPanelLinkSelectorPrefix] || DXPanelString(selector).length <= DXPanelLinkSelectorPrefix.length) return nil;
    id stored = preferences[@"linkactions"];
    if (![stored isKindOfClass:NSArray.class]) return nil;
    for (id entry in stored) if ([entry isKindOfClass:NSDictionary.class] && [entry[@"selector"] isEqual:selector]) return entry;
    return nil;
}
// Input-dependent custom actions remain selectable in gesture panels; execution
// must reject them with an error, never substitute text from another process.
static inline BOOL DXPanelCustomActionSelectable(NSDictionary *entry, NSString *kind) {
    if (![entry isKindOfClass:NSDictionary.class]) return NO;
    if ([kind isEqual:DXPanelKeyboardKind]) return YES;
    NSString *type = DXPanelString(entry[@"type"]);
    return !type.length || [@[@"url", @"urlscheme", @"openapp", @"shortcut", @"system"] containsObject:type];
}
static inline BOOL DXPanelItemAllowed(NSDictionary *preferences, NSString *selector, NSString *kind) {
    if (DXIsPanelSelector(selector)) return DXPanelAllowed(preferences, selector, kind);
    NSDictionary *entry = DXPanelActionDefinition(preferences, selector);
    if (entry) return DXPanelCustomActionSelectable(entry, kind);
    // Runtime additionally resolves built-in selectors against the action catalog.
    return [kind isEqual:DXPanelKeyboardKind] && [DXPanelString(selector) hasSuffix:@":"] && ![selector hasPrefix:@"__"];
}
static inline NSArray<NSDictionary *> *DXPanelItems(NSDictionary *preferences, NSString *selector) {
    NSDictionary *panel = DXPanelDefinition(preferences, selector);
    id stored = panel[@"items"];
    if (![stored isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *items = [NSMutableArray array];
    for (id item in stored) {
        if (![item isKindOfClass:NSDictionary.class] || !DXPanelItemAllowed(preferences, item[@"selector"], panel[@"kind"])) continue;
        NSMutableDictionary *sanitized = [NSMutableDictionary dictionary];
        // Item icons always follow the referenced action or panel definition.
        for (NSString *field in @[@"selector", @"id", @"name"])
            if ([item[field] isKindOfClass:NSString.class]) sanitized[field] = item[field];
        [items addObject:sanitized];
    }
    return items;
}
static inline NSDictionary *DXPanelPreferences(NSDictionary *preferences, NSString *selector) {
    NSMutableDictionary *result = [preferences mutableCopy] ?: [NSMutableDictionary dictionary];
    id values = DXPanelDefinition(preferences, selector)[@"preferences"];
    if ([values isKindOfClass:NSDictionary.class])
        for (NSString *key in @[kDXPanelColumns, kDXPanelScale, kDXPanelDark, kDXPanelSystemTogglesVisible, kDXPanelSystemSlidersVisible])
            if (values[key]) result[key] = values[key];
    return result;
}
static inline void DXPanelUpdate(NSMutableDictionary *preferences, NSString *selector, NSDictionary *changes) {
    NSDictionary *original = DXPanelDefinition(preferences, selector);
    if (!original || !changes) return; // A stale editor cannot resurrect a deleted panel.
    NSMutableArray *panels = [preferences[kDXPanels] mutableCopy];
    NSUInteger index = [panels indexOfObject:original];
    if (index == NSNotFound) return;
    NSMutableDictionary *panel = [original mutableCopy];
    [panel addEntriesFromDictionary:changes];
    panels[index] = panel;
    preferences[kDXPanels] = panels;
}
static inline NSString *DXToolbarBindingSlot(NSString *configuration, NSString *direction) {
    if (![@[@"top", @"bottom"] containsObject:configuration] || ![@[@"left", @"right"] containsObject:direction]) return nil;
    return [configuration stringByAppendingFormat:@".%@", direction];
}
static inline NSString *DXToolbarAction(NSDictionary *preferences, NSString *configuration, NSString *direction) {
    id stored = preferences[kDXToolbarBindings];
    NSString *slot = DXToolbarBindingSlot(configuration, direction);
    NSString *selector = [stored isKindOfClass:NSDictionary.class] && slot ? DXPanelString(stored[slot]) : @"";
    return DXPanelItemAllowed(preferences, selector, DXPanelKeyboardKind) ? selector : nil;
}
static inline void DXPanelRemoveReferences(NSMutableDictionary *preferences, NSString *selector) {
    id stored = preferences[kDXToolbarBindings];
    if ([stored isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *bindings = [stored mutableCopy];
        for (NSString *slot in bindings.allKeys) if ([bindings[slot] isEqual:selector]) bindings[slot] = @"";
        preferences[kDXToolbarBindings] = bindings;
    }
    NSMutableArray *panels = [NSMutableArray array];
    for (NSDictionary *original in DXPanelDefinitions(preferences, nil)) {
        NSMutableDictionary *panel = [original mutableCopy];
        NSMutableArray *items = [NSMutableArray array];
        id storedItems = panel[@"items"];
        for (id item in [storedItems isKindOfClass:NSArray.class] ? storedItems : @[])
            if (![item isKindOfClass:NSDictionary.class] || ![item[@"selector"] isEqual:selector]) [items addObject:item];
        panel[@"items"] = items;
        [panels addObject:panel];
    }
    preferences[kDXPanels] = panels;
}
// Deterministic IDs make read-time migration consistent in Settings, apps and
// SpringBoard. Presence (even an empty/invalid registry) is the migration marker.
static inline NSDictionary *DXPanelMigratePreferences(NSDictionary *preferences) {
    if (![preferences isKindOfClass:NSDictionary.class] || preferences.count == 0 || preferences[kDXPanels]) return preferences;
    NSMutableDictionary *result = [preferences mutableCopy];
    NSMutableArray *panels = [NSMutableArray array];
    BOOL hasLegacy = NO;
    for (NSString *key in preferences) if ([key hasPrefix:@"keyboardpanel"] && ![key isEqual:kDXPanelTopEnabled] &&
        ![key isEqual:kDXPanelBottomEnabled] && ![key isEqual:kDXPanelDockSwipeEnabled] && ![key isEqual:kDXPanelGlobalEnabled]) hasLegacy = YES;
    NSDictionary *dock = [preferences[@"dockgesturebindings"] isKindOfClass:NSDictionary.class] ? preferences[@"dockgesturebindings"] : @{};
    NSDictionary *status = [preferences[@"statusbargesturebindings"] isKindOfClass:NSDictionary.class] ? preferences[@"statusbargesturebindings"] : @{};
    for (id selector in dock.allValues) if ([DXPanelString(selector) hasPrefix:@"__mubx_dock_panel_"]) hasLegacy = YES;
    for (id binding in status.allValues) if ([binding isKindOfClass:NSDictionary.class] && [DXPanelString(binding[@"selector"]) hasPrefix:@"__mubx_statusbar_panel_"]) hasLegacy = YES;
    if (hasLegacy) {
        NSUInteger number = 0;
        for (NSString *side in @[@"left", @"right", @"common"]) {
            number++;
            NSDictionary *profile = DXKeyboardPanelProfilePreferences(preferences, side);
            NSMutableDictionary *options = [NSMutableDictionary dictionary];
            for (NSString *key in @[kDXPanelColumns, kDXPanelScale, kDXPanelDark, kDXPanelSystemTogglesVisible, kDXPanelSystemSlidersVisible])
                if (profile[key]) options[key] = profile[key];
            for (NSString *kind in @[DXPanelKeyboardKind, DXPanelGestureKind]) {
                NSString *identifier = [NSString stringWithFormat:@"legacy-%@-%@", kind, side];
                [panels addObject:@{@"id": identifier, @"kind": kind,
                    @"name": [NSString stringWithFormat:@"%@ %lu", [kind isEqual:DXPanelKeyboardKind] ? @"键盘面板" : @"手势面板", (unsigned long)number],
                    @"icon": DXPanelDefaultIconName(kind), @"items": DXKeyboardPanelItems(preferences, side), @"preferences": options}];
            }
        }
        NSMutableDictionary *bindings = [dock mutableCopy];
        for (NSString *direction in @[@"up", @"left", @"right"]) {
            NSString *old = DXPanelString(bindings[direction]);
            if (!bindings[direction] && [direction isEqual:@"up"]) old = @"__mubx_dock_panel_common";
            for (NSString *side in @[@"left", @"right", @"common"])
                if ([old isEqual:[@"__mubx_dock_panel_" stringByAppendingString:side]]) bindings[direction] = DXPanelSelector([@"legacy-gesture-" stringByAppendingString:side]);
        }
        result[@"dockgesturebindings"] = bindings;
        bindings = [status mutableCopy];
        for (NSString *slot in bindings.allKeys) {
            if (![bindings[slot] isKindOfClass:NSDictionary.class]) continue;
            NSMutableDictionary *binding = [bindings[slot] mutableCopy];
            for (NSString *side in @[@"left", @"right", @"common"])
                if ([binding[@"selector"] isEqual:[@"__mubx_statusbar_panel_" stringByAppendingString:side]]) binding[@"selector"] = DXPanelSelector([@"legacy-gesture-" stringByAppendingString:side]);
            bindings[slot] = binding;
        }
        result[@"statusbargesturebindings"] = bindings;
    }
    result[kDXPanels] = panels;
    // No implicit toolbar actions: a new binding must be explicitly selected.
    if (!result[kDXToolbarBindings]) result[kDXToolbarBindings] = @{};
    return result;
}
