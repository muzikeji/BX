#pragma once
#import "../common.h"

// 自定义动作分组 helpers shared by management and selection pages. Groups are
// display-only metadata: each entry carries an optional kCustomActionGroupKey
// string and the ordered registry lives in kLinkActionGroupsKey. Nothing here
// feeds an execution path — the flat array stays the order every consumer
// sees, and all existing references (panels, toolbar, gestures, sub-actions)
// keep working. Foundation-only so the test runner compiles the slice
// directly.

static inline NSString *DXActionGroupNormalizedName(NSString *name) {
    NSString *trimmed = [name isKindOfClass:NSString.class]
        ? [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
    return trimmed.length <= 32 ? trimmed : [trimmed substringToIndex:32];
}

// Validated registry: non-empty unique names, stored order preserved.
static inline NSArray<NSString *> *DXActionStoredGroups(NSDictionary *preferences) {
    id stored = preferences[kLinkActionGroupsKey];
    if (![stored isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSString *> *groups = [NSMutableArray array];
    for (id name in stored) {
        NSString *normalized = DXActionGroupNormalizedName(name);
        if (!normalized.length || [groups containsObject:normalized]) continue;
        [groups addObject:normalized];
    }
    return groups;
}

// Members of one group in flat-array order; a nil/empty group collects
// entries without a usable kCustomActionGroupKey (the trailing 未分组 set).
static inline NSArray<NSDictionary *> *DXActionsInGroup(NSArray *actions, NSString *group) {
    NSString *target = DXActionGroupNormalizedName(group);
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    for (NSDictionary *entry in actions) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSString *member = DXActionGroupNormalizedName(entry[kCustomActionGroupKey]);
        if (target.length ? [member isEqualToString:target] : !member.length) [result addObject:entry];
    }
    return result;
}

// Section names: registry order first, then groups referenced by entries but
// missing from the registry, in first-appearance order. The trailing 未分组
// section is the caller's concern.
static inline NSArray<NSString *> *DXActionGroupNames(NSDictionary *preferences, NSArray *actions) {
    NSMutableArray<NSString *> *groups = [DXActionStoredGroups(preferences) mutableCopy];
    for (NSDictionary *entry in actions) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSString *name = DXActionGroupNormalizedName(entry[kCustomActionGroupKey]);
        if (name.length && ![groups containsObject:name]) [groups addObject:name];
    }
    return groups;
}

// Section index map for the management page: one bucket per group plus the
// trailing 未分组 bucket, each listing the action's flat-array position in
// display order. Global row indices stay the single source of truth — row
// gestures resolve through this map instead of addressing sections directly.
static inline NSArray<NSArray<NSNumber *> *> *DXActionGroupSectionIndexes(NSArray *actions, NSArray<NSString *> *groupNames) {
    NSMutableArray<NSMutableArray<NSNumber *> *> *buckets = [NSMutableArray array];
    for (NSUInteger index = 0; index <= groupNames.count; index++) [buckets addObject:[NSMutableArray array]];
    [actions enumerateObjectsUsingBlock:^(NSDictionary *entry, NSUInteger index, __unused BOOL *stop) {
        if (![entry isKindOfClass:NSDictionary.class]) return;
        NSString *name = DXActionGroupNormalizedName(entry[kCustomActionGroupKey]);
        // NSNotFound is NSIntegerMax on 64-bit — a positive value, so an
        // `>= 0` guard never catches it. Compare against NSNotFound directly.
        NSInteger slot = name.length ? (NSInteger)[groupNames indexOfObject:name] : NSNotFound;
        [buckets[slot == NSNotFound ? (NSInteger)groupNames.count : slot] addObject:@(index)];
    }];
    return buckets;
}

// Assign or clear one action's group by selector (empty group clears the key;
// entries fall back to 未分组). Every matching entry updates — the registry has
// never enforced selector uniqueness. Returns whether anything changed.
static inline BOOL DXActionAssignGroup(NSMutableArray *actions, NSString *selector, NSString *group) {
    NSString *normalized = DXActionGroupNormalizedName(group);
    BOOL changed = NO;
    for (NSUInteger index = 0; index < actions.count; index++) {
        NSMutableDictionary *entry = actions[index];
        if (![entry isKindOfClass:NSDictionary.class] || ![entry[@"selector"] isEqual:selector]) continue;
        if (normalized.length) {
            if (![entry[kCustomActionGroupKey] isEqual:normalized]) { entry[kCustomActionGroupKey] = normalized; changed = YES; }
        } else if (entry[kCustomActionGroupKey]) {
            [entry removeObjectForKey:kCustomActionGroupKey];
            changed = YES;
        }
    }
    return changed;
}

// Entries follow a registry rename; call after updating the stored array.
static inline void DXActionRenameGroup(NSMutableArray *actions, NSString *oldName, NSString *newName) {
    NSString *from = DXActionGroupNormalizedName(oldName), *to = DXActionGroupNormalizedName(newName);
    if (!from.length || !to.length || [from isEqualToString:to]) return;
    for (NSUInteger index = 0; index < actions.count; index++) {
        NSMutableDictionary *entry = actions[index];
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        if ([DXActionGroupNormalizedName(entry[kCustomActionGroupKey]) isEqualToString:from]) entry[kCustomActionGroupKey] = to;
    }
}

// A deleted group's members fall back to 未分组 (the key is simply removed).
static inline void DXActionUngroupMembers(NSMutableArray *actions, NSString *group) {
    NSString *name = DXActionGroupNormalizedName(group);
    if (!name.length) return;
    for (NSUInteger index = 0; index < actions.count; index++) {
        NSMutableDictionary *entry = actions[index];
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        if ([DXActionGroupNormalizedName(entry[kCustomActionGroupKey]) isEqualToString:name]) [entry removeObjectForKey:kCustomActionGroupKey];
    }
}

// Shared search: matches name, link, group and the caller-provided type
// display name, case-insensitive. An empty query returns everything (the
// controller gates search mode on non-empty text).
static inline NSArray<NSDictionary *> *DXActionsMatchingQuery(NSArray *actions, NSString *query,
                                                              NSString *(^typeName)(NSDictionary *entry)) {
    NSString *needle = [query isKindOfClass:NSString.class]
        ? [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
    if (!needle.length) return [actions copy];
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    for (NSDictionary *entry in actions) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSString *name = [entry[@"name"] isKindOfClass:NSString.class] ? entry[@"name"] : @"";
        NSString *link = [entry[@"link"] isKindOfClass:NSString.class] ? entry[@"link"] : @"";
        NSString *group = DXActionGroupNormalizedName(entry[kCustomActionGroupKey]);
        NSString *type = typeName ? (typeName(entry) ?: @"") : @"";
        if ([name localizedCaseInsensitiveContainsString:needle] ||
            [link localizedCaseInsensitiveContainsString:needle] ||
            [group localizedCaseInsensitiveContainsString:needle] ||
            ([type isKindOfClass:NSString.class] && [type localizedCaseInsensitiveContainsString:needle]))
            [result addObject:entry];
    }
    return result;
}

static inline NSString *DXActionDisplayType(NSDictionary *entry) {
    NSString *type = [entry[@"type"] isKindOfClass:NSString.class] ? entry[@"type"] : @"";
    if (type.length) return type;
    NSString *link = [entry[@"link"] isKindOfClass:NSString.class] ? entry[@"link"] : @"";
    NSString *lower = link.lowercaseString;
    if ([lower hasPrefix:@"https://"] || [lower hasPrefix:@"http://"]) return @"url";
    if (link.length && [link rangeOfString:@":"].location == NSNotFound &&
        [link rangeOfString:@"."].location != NSNotFound) return @"openapp";
    return @"urlscheme";
}

static inline NSArray<NSNumber *> *DXActionFilteredIndexes(NSArray *actions, NSString *query, NSString *type,
                                                           NSString *(^typeName)(NSDictionary *)) {
    NSSet *hits = [NSSet setWithArray:DXActionsMatchingQuery(actions, query, typeName)];
    NSMutableArray *indexes = [NSMutableArray array];
    [actions enumerateObjectsUsingBlock:^(id entry, NSUInteger index, __unused BOOL *stop) {
        if ([entry isKindOfClass:NSDictionary.class] && [hits containsObject:entry] &&
            (!type.length || [DXActionDisplayType(entry) isEqual:type])) [indexes addObject:@(index)];
    }];
    return indexes;
}

static inline NSSet<NSString *> *DXActionCollapsedGroups(NSDictionary *prefs) {
    id stored = prefs[kLinkActionCollapsedGroupsKey];
    NSMutableSet *names = [NSMutableSet set];
    for (id name in [stored isKindOfClass:NSArray.class] ? stored : @[])
        if ([name isKindOfClass:NSString.class]) [names addObject:DXActionGroupNormalizedName(name)];
    return names;
}

// Picker rows keep one custom-actions section, so existing built-in/panel
// section identities stay stable. Group headers carry no action selector.
static inline NSArray<NSDictionary *> *DXActionPickerRows(NSArray *actions, NSDictionary *prefs,
    NSString *query, NSString *type, NSString *(^typeName)(NSDictionary *), BOOL allowsAdding) {
    NSArray *indexes = DXActionFilteredIndexes(actions, query, type, typeName);
    NSMutableArray *rows = [NSMutableArray array];
    BOOL filtered = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length || type.length;
    if (filtered) {
        for (NSNumber *index in indexes) [rows addObject:@{@"kind": @"action", @"index": index}];
    } else {
        NSArray<NSString *> *names = [DXActionGroupNames(prefs, actions) arrayByAddingObject:@""];
        NSArray *buckets = DXActionGroupSectionIndexes(actions, [names subarrayWithRange:NSMakeRange(0, names.count - 1)]);
        NSSet *collapsed = DXActionCollapsedGroups(prefs);
        for (NSUInteger section = 0; section < names.count; section++) {
            NSArray *bucket = buckets[section];
            if (!bucket.count && !names[section].length) continue;
            [rows addObject:@{@"kind": @"group", @"group": names[section], @"count": @(bucket.count),
                             @"collapsed": @([collapsed containsObject:names[section]])}];
            if (![collapsed containsObject:names[section]])
                for (NSNumber *index in bucket) [rows addObject:@{@"kind": @"action", @"index": index}];
        }
    }
    if (!rows.count) [rows addObject:@{@"kind": @"empty"}];
    if (allowsAdding) [rows addObject:@{@"kind": @"add"}];
    return rows;
}

static inline NSMutableArray *DXActionMutableDefinitions(NSDictionary *prefs) {
    NSMutableArray *definitions = [NSMutableArray array];
    id stored = prefs[@"linkactions"];
    for (id entry in [stored isKindOfClass:NSArray.class] ? stored : @[])
        [definitions addObject:[entry isKindOfClass:NSDictionary.class] ? [entry mutableCopy] : entry];
    return definitions;
}

// Apply to current definitions by stable selector. Never reorder the store.
static inline NSUInteger DXActionMoveSelectors(NSMutableDictionary *prefs, NSSet *selectors, NSString *group) {
    NSString *name = DXActionGroupNormalizedName(group);
    if (name.length && ![DXActionGroupNames(prefs, DXActionMutableDefinitions(prefs)) containsObject:name]) return 0;
    NSMutableArray *definitions = DXActionMutableDefinitions(prefs);
    NSUInteger changed = 0;
    for (id entry in definitions) {
        if (![entry isKindOfClass:NSDictionary.class] || ![selectors containsObject:entry[@"selector"] ?: @""]) continue;
        if (name.length) entry[kCustomActionGroupKey] = name;
        else [entry removeObjectForKey:kCustomActionGroupKey];
        changed++;
    }
    prefs[@"linkactions"] = definitions;
    return changed;
}

// Renames/deletions also maintain collapse state; an empty replacement
// removes only the group and sends its members to the ungrouped section.
static inline BOOL DXActionChangeGroup(NSMutableDictionary *prefs, NSString *old, NSString *replacement) {
    NSMutableArray *definitions = DXActionMutableDefinitions(prefs);
    NSMutableArray *names = [DXActionGroupNames(prefs, definitions) mutableCopy];
    NSString *name = DXActionGroupNormalizedName(replacement);
    NSUInteger index = [names indexOfObject:old];
    if (index == NSNotFound || (name.length && [names containsObject:name])) return NO;
    if (name.length) { names[index] = name; DXActionRenameGroup(definitions, old, name); }
    else { [names removeObjectAtIndex:index]; DXActionUngroupMembers(definitions, old); }
    NSMutableSet *collapsed = [DXActionCollapsedGroups(prefs) mutableCopy];
    BOOL wasCollapsed = [collapsed containsObject:old];
    [collapsed removeObject:old];
    if (name.length && wasCollapsed) [collapsed addObject:name];
    prefs[kLinkActionCollapsedGroupsKey] = collapsed.allObjects;
    prefs[kLinkActionGroupsKey] = names;
    prefs[@"linkactions"] = definitions;
    return YES;
}

static inline NSString *DXActionValidatedDraftGroup(NSDictionary *prefs, NSString *group, NSArray *pending) {
    NSString *name = DXActionGroupNormalizedName(group);
    return name.length && ([DXActionGroupNames(prefs, DXActionMutableDefinitions(prefs)) containsObject:name] ||
                           [pending containsObject:name]) ? name : @"";
}
