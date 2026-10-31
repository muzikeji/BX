#import <UIKit/UIKit.h>

// MUBX 自带 AI 问答面板（键盘工具栏 AI 按钮入口）。两种承载：
// 1) 系统键盘（宿主 app / SpringBoard 进程，工具栏长在 UIKeyboardImpl 上）：
//    openFromKeyboardWithSeedText: 进程内独立 UIWindow（level 1e6），锚定键盘
//    上方，ShellX 同款——打开即让面板窗口成为 key、光标落进面板输入框；卡片
//    hitTest 之外的触摸仍穿透回宿主；X 关闭即销毁会话。
// 2) 第三方键盘扩展（进程内窗口逃不出键盘宿主区域）：工具栏写 cfprefsd+Darwin
//    通道，MUBX.xm 的 SB 端回调解析并桌面门控后调 presentInSpringBoard...，
//    SB 内 plain-init UIWindow（makeKeyAndVisible）承载。
@interface DXAIPanel : NSObject
+ (void)openFromKeyboardWithSeedText:(NSString *)seedText;
+ (void)presentInSpringBoardWithSeedText:(NSString *)seedText clipboardImage:(BOOL)clipboardImage;
// 面板输入框正持有键盘（第一响应者）时为 YES。用于 iOS16+ 粘贴授权弹窗的
// 自动放行判断：从面板里点"粘贴"不该被系统弹窗打断。
+ (BOOL)isPanelInputActive;
@end
