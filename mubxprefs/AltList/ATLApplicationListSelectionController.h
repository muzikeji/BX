#import "ATLApplicationListControllerBase.h"

@interface ATLApplicationListSelectionController : ATLApplicationListControllerBase
{
	NSString* _selectedApplicationID;
}

// MUBX vendor addition: programmatic hosts (DXPOpenAppPickerController) need
// to seed and read the selection; upstream only ever touches the ivar
// internally.
@property (nonatomic, copy) NSString *selectedApplicationID;
@end