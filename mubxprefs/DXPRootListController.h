#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/Preferences.h>


@interface PSListController (MUBX)
-(void)setPreferenceValue:(id)value forSpecifier:(PSSpecifier*)specifier;
- (void)setCellForRowAtIndexPath:(NSIndexPath *)indexPath enabled:(BOOL)enabled;
@end

@interface DXPRootListController : PSListController <UISearchBarDelegate>
 @property (nonatomic, retain) NSMutableDictionary *dynamicSpecifiers;
@property(nonatomic, retain) UIBarButtonItem *respringBtn;

// 生效应用（pasteimagechipapps）AltList 多选页的 get/set（Root.plist 引用）：
// 读取把历史 bundleID→@YES 字典规整成数组；写入走标准域写入并补发
// prefschanged。
- (id)dxp_pasteChipAppsRead:(PSSpecifier *)specifier;
- (void)dxp_pasteChipAppsWrite:(id)value specifier:(PSSpecifier *)specifier;
@end
