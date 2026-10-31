#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// MUBX 内置剪贴板面板——参考 Kayoko 的呈现模型：
// 面板窗口与控制器在进程内常驻（首次 present 创建一次），之后每次都只做
// hidden 切换，绝不销毁重建——保证重复呼出始终有效。
// 打开时先主动收起宿主键盘（记下输入 responder，粘贴时再恢复），面板从
// 屏幕底部贴底弹出，不依赖键盘 frame 探测、不被键盘遮挡；搜索框聚焦时
// 键盘重新弹出，面板自动上移到键盘上方避让。
// 数据源为 SpringBoard 发布的 cfprefsd 快照（kClipboardSnapshotKey），
// 收到 kClipboardChangedIdentifier Darwin 通知后自动刷新。
//
// 功能对齐 Kayoko：历史/收藏分段、关键字搜索、点击粘贴（文本/图片）、
// 长按操作（复制/收藏/删除）、清空历史、空状态。
@interface DXClipboardPanel : NSObject

/// 进程内呼出剪贴板面板（键盘工具栏剪贴板按钮入口）。
/// 打开时自动收起宿主键盘并让面板贴底弹出；面板已可见时仅刷新数据与位置。
 + (void)present;

/// 隐藏面板（窗口常驻，不销毁）。
+ (void)dismiss;

/// 面板当前是否可见。
+ (BOOL)isVisible;

@end

NS_ASSUME_NONNULL_END