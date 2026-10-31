#pragma once
#import "../common.h"

// Batch construction for 批量添加应用: converts picked app dictionaries
// ({"bundleID", "name"}) into openapp custom-action entries in pick order,
// mirroring the single-add defaults (icon = bundle ID, floating = YES).
// Apps that already have an openapp action — manual entries included, link
// compared trimmed — and duplicates within the batch itself are skipped and
// reported through skippedCount, so re-running a selection never piles up.
// Entries come back mutable: the management page list keeps editing them in
// place. Foundation-only so the test runner can compile it directly.
static inline NSArray<NSMutableDictionary *> *DXBatchOpenAppEntries(
    NSArray *existingActions, NSArray *apps, NSUInteger *skippedCount) {
    NSMutableSet<NSString *> *existing = [NSMutableSet set];
    for (id entry in existingActions) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        if (![entry[kCustomActionTypeKey] isEqual:kCustomActionTypeOpenApp]) continue;
        NSString *link = [entry[@"link"] isKindOfClass:NSString.class] ? entry[@"link"] : @"";
        NSString *trimmed = [link stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length) [existing addObject:trimmed];
    }
    if (skippedCount) *skippedCount = 0;
    NSMutableArray<NSMutableDictionary *> *entries = [NSMutableArray array];
    NSMutableSet<NSString *> *picked = [NSMutableSet set];
    for (id app in apps) {
        NSString *bundleID = [app isKindOfClass:NSDictionary.class] && [app[@"bundleID"] isKindOfClass:NSString.class]
            ? app[@"bundleID"] : @"";
        NSString *name = [app isKindOfClass:NSDictionary.class] && [app[@"name"] isKindOfClass:NSString.class]
            ? app[@"name"] : @"";
        if (!bundleID.length || [existing containsObject:bundleID] || [picked containsObject:bundleID]) {
            if (skippedCount) (*skippedCount)++;
            continue;
        }
        [picked addObject:bundleID];
        [entries addObject:[@{
            @"selector": [kLinkActionSelectorPrefix stringByAppendingString:NSUUID.UUID.UUIDString],
            @"name": name.length ? name : bundleID,
            @"icon": bundleID,
            @"link": bundleID,
            kCustomActionTypeKey: kCustomActionTypeOpenApp,
            kCustomActionFloatingKey: @YES,
        } mutableCopy]];
    }
    return entries;
}
