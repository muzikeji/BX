#import "DXDarwinOpenChannel.h"

FOUNDATION_EXPORT BOOL DXIsSensitiveOpenScheme(NSString *scheme);
FOUNDATION_EXPORT void DXOpenSystemApplication(NSString *bundleIdentifier, DXSystemOpenReply reply);
FOUNDATION_EXPORT void DXOpenFloatingApplication(NSString *bundleIdentifier, DXSystemOpenReply reply);
FOUNDATION_EXPORT void DXOpenFloatingURL(NSURL *url, DXSystemOpenReply reply);
FOUNDATION_EXPORT void DXOpenSensitiveSystemURL(NSURL *url, DXSystemOpenReply reply);
FOUNDATION_EXPORT void DXOpenSystemShortcut(NSString *bundleIdentifier, NSString *shortcutType, DXSystemOpenReply reply);
FOUNDATION_EXPORT BOOL DXStartSystemOpenBroker(void);
FOUNDATION_EXPORT void DXRunSystemAction(NSString *identifier, DXSystemOpenReply reply);
FOUNDATION_EXPORT void DXRequestStatusBarGesture(NSString *slot, NSString *expectedSelector, BOOL landscape, DXSystemOpenReply reply);
typedef void (^DXPanelSystemControlReply)(DXSystemOpenResult result, NSDictionary *state);
FOUNDATION_EXPORT NSProgress *DXRequestPanelSystemControl(NSString *action, NSNumber *value, NSString *source, DXPanelSystemControlReply reply);

FOUNDATION_EXPORT void DXRestoreFloatingApplication(NSString *identifier, uint64_t revision, DXSystemOpenReply reply);
