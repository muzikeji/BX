#import <Preferences/PSListController.h>

// Edits one user-defined custom action. Entries carry a "type" field (see
// common.h): the editor renders type-specific configuration below the shared
// 名称/图标 rows. Entries without a type keep the legacy auto-detecting
// 动作链接 layout. The caller owns persistence and receives a normalized
// entry when Save is tapped.
@interface DXPLinkActionEditorController : PSViewController <UITableViewDelegate, UITableViewDataSource, UITextFieldDelegate, UITextViewDelegate>
@property (nonatomic, strong) NSMutableDictionary *entry;
@property (nonatomic, copy) void (^completion)(NSDictionary *entry);
@property (nonatomic, copy) NSArray<NSString *> *pendingGroupNames;

// Type chooser shared with the custom-actions management page: an alert
// listing every action type. Sub-action-only types are annotated; the order
// places URL Scheme first because it is the default for new actions.
+ (void)presentTypeChooserFromController:(UIViewController *)controller
                             currentType:(NSString *)currentType
                              completion:(void (^)(NSString *type))completion;
+ (NSString *)displayNameForType:(NSString *)type;
+ (NSString *)defaultIconForType:(NSString *)type;
@end
