#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// MUBX 内置剪贴板服务——仅在 SpringBoard 进程运行（与 DXStartGlobalPanel 等
// SB-only 服务同级，从 MUBX 的 %ctor 启动）。职责：
// 1. 监听系统级 Darwin 通知 com.apple.pasteboard.notify.changed（Kayoko 同款：
//    粘贴板守护进程在任何 App 写入时跨进程广播），延迟 0.1s 后在后台串行队列
//    读取 UIPasteboard，提取文本/图片写入 DXClipboardStore；
// 2. 维护剪贴板快照（cfprefsd 域 kClipboardSnapshotKey + jbroot 共享文件
//    MUBXClipboardSnapshotPath 双写）供 app 进程面板读取；
// 3. 处理面板经三通道（命名 UIPasteboard / jbroot 共享命令文件 / cfprefsd 域）
//    发来的命令（Darwin 通知 kClipboardCommandIdentifier 触发）：收藏/取消
//    收藏/删除/清空历史。按 seq 去重保证幂等。
@interface DXClipboardService : NSObject

+ (instancetype)sharedService;
/// SpringBoard 启动入口。
- (void)start;
/// 发布剪贴板快照（SB 写，app 读）。
- (void)publishSnapshot;
/// 处理面板命令（在 SB 进程执行）。
- (void)handleCommand:(NSDictionary *)command;
/// 从三通道消费所有未处理面板命令（取走即清各通道，按 seq 去重升序），
/// 无新命令返回空数组。
- (NSArray<NSDictionary *> *)consumePendingCommands;

@end

NS_ASSUME_NONNULL_END