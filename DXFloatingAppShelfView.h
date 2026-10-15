#import <UIKit/UIKit.h>

@interface DXFloatingAppShelfView : UIView
@property(nonatomic, copy) void (^contentChanged)(void);
@property(nonatomic, readonly) BOOL hasApps;
- (void)refresh;
@end
