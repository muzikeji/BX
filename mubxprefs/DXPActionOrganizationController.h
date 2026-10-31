#import <UIKit/UIKit.h>

// Shared searchable group chooser and group manager. Draft choices never
// persist; the manager explicitly writes only group metadata/membership.
@interface DXPActionOrganizationController : UITableViewController <UISearchResultsUpdating>
@property(nonatomic, copy) NSArray<NSString *> *groups;
@property(nonatomic, copy) NSString *selectedGroup;
@property(nonatomic) BOOL managesGroups;
@property(nonatomic, copy) void (^completion)(NSString *group, BOOL created);
@end

void DXPPresentActionGroupChooser(UIViewController *controller, NSArray<NSString *> *groups,
    NSString *selected, void (^completion)(NSString *group, BOOL created));
void DXPPresentActionTypeFilter(UIViewController *controller, NSString *current,
    void (^completion)(NSString *type));
