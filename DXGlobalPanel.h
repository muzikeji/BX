#import <UIKit/UIKit.h>

@interface DXGlobalPanel : NSObject
+ (instancetype)sharedInstance;
+ (BOOL)deviceUnlocked;
- (BOOL)isVisible;
- (void)presentPanelSelector:(NSString *)selector fromWindow:(UIWindow *)window origin:(NSString *)origin;
// System transitions may cancel pending gestures, but do not own Dock panel dismissal.
- (void)systemTransitionBegan;
- (void)dismiss;
@end

// Call once from MUBX's existing SpringBoard initialization path.
FOUNDATION_EXPORT void DXStartGlobalPanel(void);
