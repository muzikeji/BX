#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// MUBX 内置剪贴板服务——仅在 SpringBoard 进程运行（与 DXStartGlobalPanel 等
// SB-only 服务同级，从 MUBX 的 %ctor 启动）。职责：
// 1. 监听系统级 Darwin 通知 com.apple.pasteboard.notify.changed（Kayoko 同款：
//    粘贴板守护进程在任何 App 写入时跨进程广播），延迟 0.1s 后在后台串行队列
//    读取 UIPasteboard，提取文本/图片写入 DXClipboardStore；
// 2. 维护剪贴板快照（cfprefsd 域 kClipboardSnapshotKey + jbroot 共享文件
//    MUBXClipboardSnapshotPath 双写）供旧有进程/兜底路径读取；面板（宿主
//    App 进程）已改为直接读写 jbroot 共享 SQLite，删除/收藏/清空本地完成
//    无需命令通道，SB 收到 kClipboardChangedIdentifier 后重新发布快照。
@interface DXClipboardService : NSObject

+ (instancetype)sharedService;
/// SpringBoard 启动入口。
- (void)start;
/// 发布剪贴板快照（SB 写，app 读；面板本地改动后也触发）。
- (void)publishSnapshot;

@end

NS_ASSUME_NONNULL_END