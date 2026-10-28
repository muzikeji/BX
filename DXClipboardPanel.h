#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// TypeX 内置剪贴板面板——参考 DXAIPanel 的独立 UIWindow 承载模式：
// 进程内窗口（level 1e6）锚定键盘上方，只显示不抢键盘焦点，宿主输入会话
// 原样保留。数据源为 SpringBoard 发布的 cfprefsd 快照（kClipboardSnapshotKey），
// 收到 kClipboardChangedIdentifier Darwin 通知后自动刷新。
//
// 功能对齐 Kayoko：历史/收藏分段、关键字搜索、点击粘贴（文本/图片）、
// 长按操作（复制/收藏/删除）、清空历史、空状态。
@interface DXClipboardPanel : NSObject

/// 进程内打开面板（键盘工具栏剪贴板按钮入口），锚定当前键盘上方。
+ (void)present;

/// 关闭面板。
+ (void)dismiss;

/// 面板当前是否可见。
+ (BOOL)isVisible;

@end

NS_ASSUME_NONNULL_END