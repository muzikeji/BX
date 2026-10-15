#import "DXDarwinOpenChannel.h"

// The client APIs live in DXSystemOpenBroker. These entry points execute only
// in SpringBoard on the main queue; they never call another tweak's API.
FOUNDATION_EXPORT void DXStartFloatingAppHost(void);
FOUNDATION_EXPORT void DXPresentFloatingApplication(NSString *bundleIdentifier, NSURL *url,
                                                   NSDate *deadline, DXSystemOpenReply reply);
FOUNDATION_EXPORT NSString *DXFloatingBundleIdentifierForURL(NSURL *url);

FOUNDATION_EXPORT void DXRestoreFloatingAppFromShelf(NSString *identifier, uint64_t revision, NSDate *deadline, DXSystemOpenReply reply);
