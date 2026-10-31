#import <Preferences/PSViewController.h>

@class DXPAppInfo;

// Single-app picker for the openapp custom action, in the shape of PullOver-X
// QSFavoritesPickerController: a plain table controller that never touches
// PSListController internals (programmatic ATLApplicationListSelectionController
// use without a specifier crashed in Preferences — see 3.5.2 regression).
// Acquisition follows the same method: one background `allApplications` pass
// with a loading spinner and generation guard, each proxy classified through
// the vendored AltList categories (atl_isUserApplication /
// atl_isSystemApplication read the applicationType string). The editor owns
// persistence and receives the pick through `completion`. In batch mode the
// same table toggles an ordered multi-select and reports the whole pick
// through `multiSelectionCompletion` — the 自定义动作 management page is the
// host there and owns persistence.
@interface DXPOpenAppPickerController : PSViewController
// Pre-selected app (checkmark anchor); set before pushing. Single-select only.
@property (nonatomic, copy) NSString *selectedBundleIdentifier;
// Fired once per row tap, before the controller pops itself.
@property (nonatomic, copy) void (^completion)(DXPAppInfo *app);
// Batch mode: rows toggle checkmarks instead of popping, and 完成 hands the
// picks (DXPAppInfo, in tap order) to the host.
@property (nonatomic, assign) BOOL allowsMultipleSelection;
@property (nonatomic, copy) void (^multiSelectionCompletion)(NSArray<DXPAppInfo *> *apps);
@end
