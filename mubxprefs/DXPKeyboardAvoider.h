#import <UIKit/UIKit.h>

// Keyboard avoidance for plain UITableViews owned by a PSViewController:
// PSListController pages get it from Preferences, but controllers that build
// their own UITableView (custom action editor, AI settings pages) have no
// automatic avoidance, so the focused text control ends up under the keyboard.
// Pads the table's bottom content inset by the keyboard overlap and scrolls
// the focused control above the keyboard. Same technique as
// DXPManageShortcutsController's inline keyboard handling, generalized to
// "whatever text control is focused".
@interface DXPKeyboardAvoider : NSObject

- (instancetype)initWithTableView:(UITableView *)tableView;

// Registers the keyboard / begin-editing observers; call from viewDidLoad.
- (void)start;

// Removes the observers; dealloc removes them as well.
- (void)stop;

// Scrolls the table's focused text control above the keyboard inset. Also
// invoked internally: switching focus while the keyboard is up fires only the
// begin-editing notifications, not the will-show notification.
- (void)scrollFirstResponderAboveKeyboard;

@end
