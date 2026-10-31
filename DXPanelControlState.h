#import <Foundation/Foundation.h>
#include <math.h>

// Fixed panel controls are separate from the user-configured action directory.
static inline NSArray<NSString *> *DXPanelToggleIdentifiers(void) {
    return @[@"do-not-disturb", @"wifi", @"silent", @"bluetooth", @"orientation-lock"];
}
static inline BOOL DXPanelControlRequestValid(id request) {
    if (![request isKindOfClass:NSDictionary.class]) return NO;
    NSString *action = request[@"action"], *token = request[@"token"], *source = request[@"source"];
    if (![action isKindOfClass:NSString.class] || ![token isKindOfClass:NSString.class] ||
        ![[NSUUID alloc] initWithUUIDString:token] || token.length != 36 ||
        !([source isEqual:@"top"] || [source isEqual:@"bottom"] || [source isEqual:@"global"])) return NO;
    if ([action isEqual:@"brightness"] || [action isEqual:@"volume"]) {
        id value = request[@"value"];
        return [value isKindOfClass:NSNumber.class] && isfinite([value doubleValue]) &&
            [value doubleValue] >= 0 && [value doubleValue] <= 1;
    }
    return !request[@"value"] && ([action isEqual:@"state"] || [DXPanelToggleIdentifiers() containsObject:action]);
}
static inline NSString *DXPanelControlStateSlot(NSString *token) {
    return [@"com.lindo.mubx.panel-control.state." stringByAppendingString:token];
}
static const uint64_t DXPanelControlPendingWord = 0x5459000000000000ULL;

// One request-owned notify word carries five known/state bits and two 16-bit
// levels. Unknown/unreadable controls are absent, never fabricated as OFF.
static inline uint64_t DXPanelControlEncodeState(NSDictionary *state) {
    uint64_t word = 0x5458000000000000ULL;
    NSArray *toggles = DXPanelToggleIdentifiers();
    for (NSUInteger index = 0; index < toggles.count; index++) {
        id value = state[toggles[index]];
        if ([value isKindOfClass:NSNumber.class]) {
            word |= 1ULL << (index + 8);
            if ([value boolValue]) word |= 1ULL << index;
        }
    }
    for (NSUInteger index = 0; index < 2; index++) {
        id value = state[index ? @"volume" : @"brightness"];
        if ([value isKindOfClass:NSNumber.class] && isfinite([value doubleValue]) && [value doubleValue] >= 0 && [value doubleValue] <= 1) {
            word |= 1ULL << (13 + index);
            word |= (uint64_t)llround([value doubleValue] * 65535) << (16 + 16 * index);
        }
    }
    return word;
}
static inline NSDictionary *DXPanelControlDecodeState(uint64_t word) {
    if ((word >> 48) != 0x5458) return nil;
    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    NSArray *toggles = DXPanelToggleIdentifiers();
    for (NSUInteger index = 0; index < toggles.count; index++)
        if (word & (1ULL << (index + 8))) state[toggles[index]] = @((word & (1ULL << index)) != 0);
    for (NSUInteger index = 0; index < 2; index++)
        if (word & (1ULL << (13 + index))) state[index ? @"volume" : @"brightness"] = @((double)((word >> (16 + 16 * index)) & 0xffff) / 65535);
    return state;
}
