#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DXPSFSymbolCategory : NSObject
@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy, readonly, nullable) NSString *iconName;
@property (nonatomic, copy, readonly, nullable) NSString *title;
@property (nonatomic, copy, readonly) NSArray<NSString *> *symbolNames;
@end

// Reads symbol names from local system resources only; callers must check
// UIImage availability before presenting a name for selection.
@interface DXPSFSymbolCatalog : NSObject
+ (NSArray<NSString *> *)systemResourceDirectories;
+ (NSArray<NSString *> *)namesFromResourceDirectories:(NSArray<NSString *> *)directories
                                         sourcePaths:(NSArray<NSString *> * _Nullable * _Nullable)sourcePaths;
// Category membership is intersected with the already validated names. The
// synthetic "all" group contains those names even when category files fail.
+ (NSArray<DXPSFSymbolCategory *> *)categoriesFromResourceDirectories:(NSArray<NSString *> *)directories
                                                    availableNames:(NSArray<NSString *> *)availableNames
                                                       sourcePaths:(NSArray<NSString *> * _Nullable * _Nullable)sourcePaths;
@end

NS_ASSUME_NONNULL_END
