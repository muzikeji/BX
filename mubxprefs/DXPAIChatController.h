#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

// AI 问答设置主页（Root.plist 入口）：AI 引擎入口、当前引擎配置（API Key /
// 模型 / 抓取 / 获取网址）、AI 人设 / 流式输出。
@interface DXPAIChatController : PSViewController <UITableViewDelegate, UITableViewDataSource>
@property (strong, nonatomic) UITableView *tableView;
@end

// AI 引擎页：内置引擎单选（勾选即切换）+ 自定义引擎列表（点行编辑、左滑删除），
// 右上角「添加」进自定义引擎编辑器。
@interface DXPAIEnginePickerController : PSViewController <UITableViewDelegate, UITableViewDataSource>
@property (strong, nonatomic) UITableView *tableView;
@end

// 自定义引擎编辑器：接口地址 / 显示名称 / API Key / 模型 / 模型抓取，右上角保存。
// engineID 传 nil 表示新增。
@interface DXPAICustomEngineEditorController : PSViewController <UITableViewDelegate, UITableViewDataSource>
@property (strong, nonatomic) UITableView *tableView;
- (instancetype)initWithEngineID:(NSString *)engineID;
@end

// 人设页：人设列表（点行编辑、左滑删除、长按拖动排序，第一项为默认人设），
// 右上角「+」添加。
@interface DXPAIPersonaController : PSViewController <UITableViewDelegate, UITableViewDataSource, UITableViewDragDelegate, UITableViewDropDelegate>
@property (strong, nonatomic) UITableView *tableView;
@end

// 编辑人设：是否直接发送开关 / 名称 / 人设内容，右上角保存。
@interface DXPAIPersonaEditorController : PSViewController <UITableViewDelegate, UITableViewDataSource>
@property (strong, nonatomic) UITableView *tableView;
- (instancetype)initWithPersonaID:(NSString *)personaID;
@end
