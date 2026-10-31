#import "DXPSubActionPickerController.h"

@interface DXPSubActionPickerController ()
// Set when a brand-new custom action was created from the 添加 row in
// single-row mode: the completion fires only after the editor has popped back
// to this picker, so the auto-pick waits for viewDidAppear.
@property (nonatomic, copy) NSString *pendingAutoPickSelector;
@end

@implementation DXPSubActionPickerController

- (void)viewDidLoad {
    self.selectionManagedExternally = YES;
    // 任意动作都能成为子动作候选：自定义动作可在此就地创建，无需先绕道
    // 自定义动作管理页；内置动作目录由 fullOrder 原样提供。
    self.allowsCreatingCustomActions = YES;
    [super viewDidLoad];
}

// A just-created custom action joins the pending pick immediately: batch mode
// checks it so 完成 includes it; single-row mode records the selector here and
// fires the completion after the pop (the editor is still on top when the
// save callback runs, so popping this picker right away would race it).
- (void)customActionWasCreated:(NSString *)selector {
    if (!selector.length) return;
    if (self.allowsMultipleSelection) {
        [self markSelectorPicked:selector];
        return;
    }
    self.selectedSelector = selector;
    self.pendingAutoPickSelector = selector;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.pendingAutoPickSelector.length == 0) return;
    NSString *selector = self.pendingAutoPickSelector;
    self.pendingAutoPickSelector = nil;
    if (self.completion) self.completion(selector);
    [self.navigationController popViewControllerAnimated:YES];
}

@end
