#import <Preferences/PSViewController.h>

@interface DXPSystemActionPickerController : PSViewController
@property (nonatomic, copy) NSString *selectedIdentifier;
@property (nonatomic, copy) void (^completion)(NSDictionary *action);
@end
