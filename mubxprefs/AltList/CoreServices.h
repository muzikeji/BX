// MUBX vendor shim for AltList (com.opa334.altlist, MIT, © Lars Fröder).
// Upstream imports <MobileCoreServices/LSApplicationProxy.h> and
// <MobileCoreServices/LSApplicationWorkspace.h>, but the theos SDKs used by
// this project do not ship those private headers (MUBX declares these classes
// by hand everywhere else, e.g. DXPAppInfo.m). This shim is self-contained:
// declarations only, the real implementations come from the framework at
// runtime. Merge upstream changes into the declarations below if AltList is
// ever re-synced.

#import <Foundation/Foundation.h>

@interface LSApplicationRecord : NSObject
@property (nonatomic, readonly) NSArray *appTags; // e.g. 'hidden'
@property (getter=isLaunchProhibited, readonly) BOOL launchProhibited;
@end

@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly, copy) NSString *localizedName;
@property (nonatomic, readonly, copy) NSString *applicationType; // "User" / "System"
@property (nonatomic, readonly) NSArray *appTags;                // e.g. 'hidden'
@property (nonatomic, readonly) NSURL *bundleURL;
// iOS 8-14 exposes bundleIdentifier, iOS 7 only applicationIdentifier.
@property (nonatomic, readonly, copy) NSString *bundleIdentifier;
@property (nonatomic, readonly, copy) NSString *applicationIdentifier;
@property (getter=isLaunchProhibited, nonatomic, readonly) BOOL launchProhibited;
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
- (LSApplicationRecord *)correspondingApplicationRecord;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allApplications;
- (NSArray *)allInstalledApplications;
- (void)enumerateApplicationsOfType:(NSUInteger)type block:(void (^)(LSApplicationProxy *))block;
- (void)addObserver:(id)observer;
- (void)removeObserver:(id)observer;
@end
