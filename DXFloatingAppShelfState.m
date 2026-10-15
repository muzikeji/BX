#import "DXFloatingAppShelfState.h"

BOOL DXFloatingShelfIdentifierValid(id identifier) {
    if (![identifier isKindOfClass:NSString.class] || [identifier length] < 3 || [identifier length] > 256) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"];
    return [identifier rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound &&
        [identifier rangeOfString:@"."].location != NSNotFound && ![identifier isEqual:@"com.apple.springboard"];
}
BOOL DXFloatingShelfSnapshotValid(id snapshot) {
    if (![snapshot isKindOfClass:NSDictionary.class] || ![snapshot[@"items"] isKindOfClass:NSArray.class] ||
        [snapshot[@"items"] count] > DXFloatingShelfCapacity || ![snapshot[@"active"] isKindOfClass:NSString.class]) return NO;
    if (snapshot[@"unlocked"] && ![snapshot[@"unlocked"] isKindOfClass:NSNumber.class]) return NO;
    if (snapshot[@"foreground"] && (![snapshot[@"foreground"] isKindOfClass:NSString.class] || [snapshot[@"foreground"] length] > 256)) return NO;
    NSMutableSet *identifiers = [NSMutableSet set];
    for (id item in snapshot[@"items"]) {
        if (![item isKindOfClass:NSDictionary.class] || !DXFloatingShelfIdentifierValid(item[@"bundleID"]) ||
            ![item[@"title"] isKindOfClass:NSString.class] || [item[@"title"] length] > 256 ||
            [identifiers containsObject:item[@"bundleID"]]) return NO;
        [identifiers addObject:item[@"bundleID"]];
    }
    NSString *active = snapshot[@"active"];
    return !active.length || [identifiers containsObject:active];
}
@interface DXFloatingAppShelfState ()
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *records;
@property(nonatomic, copy, readwrite) NSString *activeIdentifier;
@end
@implementation DXFloatingAppShelfState
- (instancetype)init { if ((self = [super init])) _records = [NSMutableArray array]; return self; }
- (NSArray *)items { return [self.records copy]; }
- (BOOL)contains:(NSString *)identifier {
    for (NSDictionary *record in self.records) if ([record[@"bundleID"] isEqual:identifier]) return YES;
    return NO;
}
- (BOOL)activate:(NSString *)identifier title:(NSString *)title {
    if (!DXFloatingShelfIdentifierValid(identifier)) return NO;
    if (![self contains:identifier]) {
        // Capacity limits recovery entries only; eviction never touches the old app/process.
        if (self.records.count >= DXFloatingShelfCapacity) [self.records removeLastObject];
        NSUInteger length = [title isKindOfClass:NSString.class] ? MIN(title.length, (NSUInteger)256) : 0;
        // 截断点不落在代理对中间，避免产生非法字符串进入跨进程快照。
        if ([title isKindOfClass:NSString.class]) {
            while (length > 0) {
                unichar last = [title characterAtIndex:length - 1];
                if (last < 0xD800 || last > 0xDBFF) break;
                length--;
            }
        }
        [self.records addObject:@{@"bundleID": identifier,
            @"title": [title isKindOfClass:NSString.class] ? [title substringToIndex:length] : identifier}];
    }
    self.activeIdentifier = identifier;
    return YES;
}
- (BOOL)park:(NSString *)identifier {
    NSUInteger index = [self.records indexOfObjectPassingTest:^BOOL(NSDictionary *item, __unused NSUInteger idx, __unused BOOL *stop) {
        return [item[@"bundleID"] isEqual:identifier];
    }];
    if (index == NSNotFound) return NO;
    NSDictionary *record = self.records[index];
    [self.records removeObjectAtIndex:index];
    [self.records insertObject:record atIndex:0];
    if ([self.activeIdentifier isEqual:identifier]) self.activeIdentifier = nil;
    return YES;
}
- (void)releaseActive { self.activeIdentifier = nil; }
- (void)remove:(NSString *)identifier {
    NSIndexSet *indices = [self.records indexesOfObjectsPassingTest:^BOOL(NSDictionary *item, __unused NSUInteger idx, __unused BOOL *stop) {
        return [item[@"bundleID"] isEqual:identifier];
    }];
    [self.records removeObjectsAtIndexes:indices];
    if ([self.activeIdentifier isEqual:identifier]) self.activeIdentifier = nil;
}
- (NSDictionary *)snapshot { return @{@"items": self.items, @"active": self.activeIdentifier ?: @""}; }
@end
