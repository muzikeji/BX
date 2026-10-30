#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// App 进程侧剪贴板采集器（文本冗余通道）。
// UIPasteboardChangedNotification 只在执行写入的进程内广播，SpringBoard 永远
// 收不到其它 App 的复制事件；SpringBoard 侧已用 changeCount 轮询兜底（见
// DXClipboardService startPollingForCrossProcessChanges）。此采集器在 hook 到
// UIPasteboard 写入方法后，于同一进程读取刚写入的文本并入队 cfprefsd 隔离域，
// 再广播 Darwin 通知让 SpringBoard 消费落库。只在写入进程内读自己刚写入的
// 内容，不会触发 iOS 16+ 的粘贴权限弹窗。
@interface DXClipboardCapture : NSObject

+ (instancetype)sharedCapture;
/// 进程启动入口：App 进程 %ctor 调用，记录 bundle id 并启用采集。
- (void)start;
/// 本进程 UIPasteboard 写入完成后调用：采样刚写入的文本并入队。
/// 在 SpringBoard 进程内调用时直接忽略（SB 自身写入已由通知/轮询路径处理）。
- (void)capturePasteboardAfterWrite;

@end

NS_ASSUME_NONNULL_END