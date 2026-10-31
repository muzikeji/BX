// MUBX vendor: the theos SDK does not ship the private MobileCoreServices
// headers upstream imports, so the class declarations live in the shim.
#import "CoreServices.h"

@interface LSApplicationProxy (AltList)
- (BOOL)atl_isSystemApplication;
- (BOOL)atl_isUserApplication;
- (BOOL)atl_isHidden;
- (NSString*)atl_fastDisplayName;
- (NSString*)atl_nameToDisplay;
@property (nonatomic,readonly) NSString* atl_bundleIdentifier;
@end

@interface LSApplicationWorkspace (AltList)
- (NSArray*)atl_allInstalledApplications;
@end