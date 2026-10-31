#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

@interface DXPCustomActionViewController : PSViewController <UITableViewDelegate, UITableViewDataSource>
@property (strong, nonatomic) UITableView *tableView;
@property (nonatomic,readwrite) NSString *identifier;
@property (nonatomic,readwrite) NSString *keyID;
@property (nonatomic, strong) NSArray *fullOrder;
// Defaults to keyboard; gesture context filters input-only action types.
@property (nonatomic, copy) NSString *actionContextKind;
@property (nonatomic, strong) NSIndexPath *selectedIndexPath;
// Sub-action rows reuse this exact picker UI. In external mode selection is
// returned through completion instead of being stored as a gesture override.
@property (nonatomic, copy) NSString *selectedSelector;
@property (nonatomic, copy) void (^completion)(NSString *selector);
@property (nonatomic, assign) BOOL selectionManagedExternally;
// Multi-select mode (batch sub-action add): rows toggle checkmarks, nothing
// is persisted here, and the whole pick is reported through
// multiSelectionCompletion when the Done button taps out.
@property (nonatomic, assign) BOOL allowsMultipleSelection;
@property (nonatomic, copy) void (^multiSelectionCompletion)(NSArray<NSString *> *selectors);
// Standalone management mode hides built-ins and opens a row's editor on tap.
// Picker extensions opt into in-place creation/deletion separately.
@property (nonatomic, assign) BOOL customActionsOnly;
// Delete custom definitions and their saved references from an opted-in picker.
// This does not enable edit mode, dragging, or deletion of built-in/add rows.
@property (nonatomic, assign) BOOL allowsDeletingCustomActions;
// Picker-mode extension for sub-action picking: the custom-action group stays
// visible even with zero actions and grows a trailing "添加" row, so a missing
// definition can be created in place instead of detouring through the
// custom-actions management page. Gesture-slot pickers keep the read-only
// layout (flag stays NO).
@property (nonatomic, assign) BOOL allowsCreatingCustomActions;
@property (nonatomic, strong) NSMutableDictionary *prefs;
// Ordered user-defined action definitions (kLinkActionskey). Public so the
// standalone management page can render its grouped layout on top of
// the shared storage helpers.
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *linkActions;
@property (nonatomic, copy) NSString *actionQuery;
@property (nonatomic, copy) NSString *actionTypeFilter;
@property (nonatomic, copy) NSString *defaultActionGroup;
@property (nonatomic, strong) UISearchController *actionSearchController;
- (void)configureActionSearch;
- (void)actionFilterDidChange;
- (void)showActionTypeFilter;
- (void)toggleActionGroup:(NSString *)group;

// Shared storage helpers for the management page.
// Configure cells before attaching the data source or publishing the table.
// Derived layouts use the same table throughout the controller's lifecycle.
- (void)configureActionTableView:(UITableView *)tableView;
- (void)reloadPreferences;
- (void)persistLinkActions;
- (void)writePreferences;
- (void)removeReferencesToSelector:(NSString *)selector fromPreferences:(NSMutableDictionary *)preferences;
- (void)pushEditorForCustomRow:(NSInteger)row;
// No-op here; pickers that enable allowsCreatingCustomActions override it to
// fold the just-saved selector into their pending selection.
- (void)customActionWasCreated:(NSString *)selector;
// Batch-mode checkmark for one selector without exposing the live pick set.
- (void)markSelectorPicked:(NSString *)selector;
// 添加 flow on a fixed type: creates a PENDING entry and pushes the editor;
// the store is only touched when the editor reports the saved entry.
- (void)startAddFlowForType:(NSString *)type;
// Editor-save refresh hooks rebuild derived groups/search rows before reload.
- (void)linkActionListDidChange;
- (void)linkActionRowDidUpdate:(NSInteger)row;
// 分区布局助手（子类可覆写 shows* 关分区）：隐藏分区返回 -1。
- (BOOL)showsBuiltInActionsSection;
- (NSInteger)builtInSection;
@property(nonatomic, retain) UIBarButtonItem *defaultBtn;
@property (nonatomic, copy) NSString *configuration;
@end
