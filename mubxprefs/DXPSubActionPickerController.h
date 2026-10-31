#import "DXPCustomActionViewController.h"

// Action picker for sub-actions. Default mode edits one row: a single pick is
// reported through `completion`. With allowsMultipleSelection the picker
// toggles checkmarks instead and reports the whole batch through
// `multiSelectionCompletion` when Done is tapped.
@interface DXPSubActionPickerController : DXPCustomActionViewController
@end
