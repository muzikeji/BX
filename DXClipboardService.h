#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// TypeX 内置剪贴板服务——仅在 SpringBoard 进程运行（与 DXStartGlobalPanel 等
// SB-only 服务同级，从 TypeX 的 %ctor 启动）。职责：
// 1. 监听 UIPasteboardChangedNotification，提取文本/图片，写入 DXClipboardStore；
// 2. 维护 cfprefsd 快照（kClipboardSnapshotKey）供 app 进程面板读取；
// 3. 处理 app 进程经 Darwin 通知发来的命令（kClipboardCommandIdentifier）：
//    收藏/取消收藏/删除/清空/迁移 Kayoko 历史；
// 4. 首启时自动迁移 Kayoko history-v4.sqlite（一次性，成功即标记）。
@interface DXClipboardService : NSObject

+ (instancetype)sharedService;
/// SpringBoard 启动入口。
- (void)start;
/// 发布剪贴板快照（SB 写，app 读）。
- (void)publishSnapshot;
/// 处理面板命令（在 SB 进程执行）。
- (void)handleCommand:(NSDictionary *)command;

@end

NS_ASSUME_NONNULL_END