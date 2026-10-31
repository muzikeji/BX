#import <Preferences/PSViewController.h>

// SF Symbols 分类选择器：仅解析本机系统资源和分类，过滤本机可渲染的条目，
// 进入分类后按名称搜索；选中回传 SF Symbol 名并返回原编辑页。
@interface DXPSFSymbolPickerController : PSViewController
@property (nonatomic, copy) NSString *selectedSymbolName;
@property (nonatomic, copy) void (^completion)(NSString *symbolName);
@end
