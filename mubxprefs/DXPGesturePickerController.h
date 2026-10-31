#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

@interface DXPGesturePickerController : PSListController{
    UILabel *_label;
}
@property (nonatomic,readwrite) NSString *identifier;
@property (nonatomic, strong) NSArray *fullOrder;
@property (nonatomic, copy) NSString *configuration;
// YES when pushed from the "+" button: nothing is persisted until the user
// taps Save; name/icon input and gesture choices are held until then.
@property (nonatomic, assign) BOOL pendingNewEntry;
// Pending (unsaved) name/icon typed on the new-button page.
@property (nonatomic, copy) NSString *pendingName;
@property (nonatomic, copy) NSString *pendingIcon;
@end

@interface PSSpecifier (DXPGesturePickerController)
-(void)setValues:(id)arg1 titles:(id)arg2;
@end
