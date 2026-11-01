#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// MUBX 内置剪贴板服务——仅在 SpringBoard 进程运行（与 DXStartGlobalPanel 等
// SB-only 服务同级，从 MUBX 的 %ctor 启动）。职责：
// 1. 监听系统级 Darwin 通知 com.apple.pasteboard.notify.changed（Kayoko 同款：
//    粘贴板守护进程在任何 App 写入时跨进程广播），延迟 0.1s 后在后台串行队列
//    读取 UIPasteboard，提取文本/图片写入 DXClipboardStore；
// 2. 维护剪贴板快照（cfprefsd 域 kClipboardSnapshotKey + jbroot 共享文件
//    MUBXClipboardSnapshotPath 双写）供面板（宿主 App 进程）读取；
// 3. 监听面板操作命令通道 kClipboardCommandIdentifier（1.0.6）：Dopamine/
//    RootHide 沙盒 App 对 jbroot 全域只读，App 面板删除/收藏/清空改为把
//    命令 dict 写入自己容器 Documents/mubx-clipboard-command.plist 并广播
//    通知；SB 经 LSApplicationProxy 取前台 App 容器执行（写共享 SQLite），
//    App 侧诊断行随命令 log 字段由 SB 统一落 clipboard.log 文件。
@interface DXClipboardService : NSObject

+ (instancetype)sharedService;
/// SpringBoard 启动入口。
- (void)start;
/// 发布剪贴板快照（SB 写，app 读；面板本地改动后也触发）。
- (void)publishSnapshot;
/// 消费 App 面板命令（删除/收藏/清空），执行后重发快照并广播刷新。
- (void)consumeClipboardCommands;

@end

NS_ASSUME_NONNULL_END