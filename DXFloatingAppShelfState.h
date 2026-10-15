#import <Foundation/Foundation.h>

enum { DXFloatingShelfCapacity = 8, DXFloatingShelfPageSize = 4 };
FOUNDATION_EXPORT BOOL DXFloatingShelfIdentifierValid(id identifier);
FOUNDATION_EXPORT BOOL DXFloatingShelfSnapshotValid(id snapshot);

// Main-queue registry; it owns metadata only, never a process, Scene or lease.
@interface DXFloatingAppShelfState : NSObject
@property(nonatomic, copy, readonly) NSArray<NSDictionary *> *items;
@property(nonatomic, copy, readonly) NSString *activeIdentifier;
- (BOOL)contains:(NSString *)identifier;
- (BOOL)activate:(NSString *)identifier title:(NSString *)title;
- (BOOL)park:(NSString *)identifier;
- (void)releaseActive;
- (void)remove:(NSString *)identifier;
- (NSDictionary *)snapshot;
@end
