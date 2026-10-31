#import <UIKit/UIKit.h>

// 图标输入行的共享组件：左侧实时预览缩略图 + 右侧名称输入框 + 图标库入口。
// 预览渲染与 DXHelper imageForIconConfig 一致（SF Symbol 名或 App Bundle ID），
// 每次键入即时刷新，所见即条目最终渲染效果。
@interface DXPIconInputView : UIView
@property (nonatomic, readonly, strong) UITextField *textField;
@property (nonatomic, readonly, strong) UIImageView *previewImageView;
@property (nonatomic, copy) void (^textChanged)(NSString *text);
@property (nonatomic, copy) void (^browseTapped)(void);
- (void)refreshPreview;
@end
