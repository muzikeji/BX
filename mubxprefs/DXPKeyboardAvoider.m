#import "DXPKeyboardAvoider.h"

// The focused text control inside |root|'s subtree, or nil. All text controls
// live in table cells, so the walk stays small and only runs on focus /
// keyboard events.
static UIView *DXPFirstResponderIn(UIView *root) {
    if (([root isKindOfClass:[UITextField class]] || [root isKindOfClass:[UITextView class]]) &&
        root.isFirstResponder) return root;
    for (UIView *subview in root.subviews) {
        UIView *found = DXPFirstResponderIn(subview);
        if (found) return found;
    }
    return nil;
}

@implementation DXPKeyboardAvoider {
    UITableView *_tableView;
    // Gates the frame-change / will-hide handlers so a keyboard summoned by
    // an alert (no focus in this table) never pads the inset.
    BOOL _keyboardActive;
}

- (instancetype)initWithTableView:(UITableView *)tableView {
    if ((self = [super init])) {
        _tableView = tableView;
    }
    return self;
}

- (void)start {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(handleKeyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [center addObserver:self selector:@selector(handleKeyboardFrameWillChange:) name:UIKeyboardWillChangeFrameNotification object:nil];
    [center addObserver:self selector:@selector(handleKeyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
    [center addObserver:self selector:@selector(handleTextDidBeginEditing:) name:UITextFieldTextDidBeginEditingNotification object:nil];
    [center addObserver:self selector:@selector(handleTextDidBeginEditing:) name:UITextViewTextDidBeginEditingNotification object:nil];
}

- (void)stop {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Notifications

- (void)handleKeyboardWillShow:(NSNotification *)notification {
    if (!DXPFirstResponderIn(_tableView)) return;
    _keyboardActive = YES;
    [self applyKeyboardInfo:notification.userInfo scrollResponder:YES];
}

// Interactive dismissal drags fire repeated frame changes: track the keyboard
// with the inset but never re-scroll mid-drag.
- (void)handleKeyboardFrameWillChange:(NSNotification *)notification {
    if (!_keyboardActive) return;
    [self applyKeyboardInfo:notification.userInfo scrollResponder:NO];
}

- (void)handleKeyboardWillHide:(NSNotification *)notification {
    if (!_keyboardActive) return;
    _keyboardActive = NO;
    CGFloat duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] floatValue];
    UIViewAnimationOptions options = [notification.userInfo[UIKeyboardAnimationCurveUserInfoKey] unsignedIntegerValue] << 16;
    [UIView animateWithDuration:duration delay:0 options:options | UIViewAnimationOptionBeginFromCurrentState animations:^{
        UIEdgeInsets inset = _tableView.contentInset;
        inset.bottom = 0;
        _tableView.contentInset = inset;
        _tableView.scrollIndicatorInsets = inset;
    } completion:nil];
}

// Switching focus while the keyboard is up does not fire the will-show
// notification, so begin-editing is the only hook that can reposition there.
// Deferred one runloop so a hidden keyboard's will-show (which follows
// begin-editing) applies the inset first and this scroll sees it; when the
// keyboard is already up, the inset is already in place.
- (void)handleTextDidBeginEditing:(NSNotification *)notification {
    if (![notification.object isKindOfClass:[UIView class]]) return;
    UIView *control = notification.object;
    if (![control isDescendantOfView:_tableView]) return;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (control.window == nil) return;
        [weakSelf scrollFirstResponderAboveKeyboard];
    });
}

#pragma mark - Inset & scroll

- (void)applyKeyboardInfo:(NSDictionary *)info scrollResponder:(BOOL)scroll {
    CGRect endFrame = [info[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    if (CGRectIsNull(endFrame) || CGRectGetHeight(endFrame) <= 0) return;

    CGFloat duration = [info[UIKeyboardAnimationDurationUserInfoKey] floatValue];
    UIViewAnimationOptions options = [info[UIKeyboardAnimationCurveUserInfoKey] unsignedIntegerValue] << 16;
    CGRect localFrame = [_tableView convertRect:endFrame fromView:nil];
    CGFloat overlap = MAX(0, CGRectGetMaxY(_tableView.bounds) - CGRectGetMinY(localFrame));

    [UIView animateWithDuration:duration delay:0 options:options | UIViewAnimationOptionBeginFromCurrentState animations:^{
        UIEdgeInsets inset = _tableView.contentInset;
        inset.bottom = overlap;
        _tableView.contentInset = inset;
        _tableView.scrollIndicatorInsets = inset;
        if (scroll) [self scrollFirstResponderAboveKeyboard];
    } completion:nil];
}

// Minimal scroll so the focused control's bottom clears the keyboard (the
// currently applied inset.bottom is exactly the overlap), plus 8pt breathing
// room. Clamped to the scrollable range; inside an animation block the
// non-animated offset change joins the keyboard animation.
- (void)scrollFirstResponderAboveKeyboard {
    UIView *responder = DXPFirstResponderIn(_tableView);
    if (!responder) return;

    CGRect rect = [_tableView convertRect:responder.bounds fromView:responder];
    CGFloat visibleBottom = CGRectGetHeight(_tableView.bounds)
        - _tableView.adjustedContentInset.bottom - 8.0;
    CGFloat delta = CGRectGetMaxY(rect) - visibleBottom;
    if (delta <= 0) return;

    CGFloat minOffset = -_tableView.adjustedContentInset.top;
    CGFloat maxOffset = MAX(minOffset, _tableView.contentSize.height
        + _tableView.adjustedContentInset.bottom - CGRectGetHeight(_tableView.bounds));
    CGFloat target = MIN(MAX(_tableView.contentOffset.y + delta, minOffset), maxOffset);
    [_tableView setContentOffset:CGPointMake(_tableView.contentOffset.x, target) animated:NO];
}

@end
