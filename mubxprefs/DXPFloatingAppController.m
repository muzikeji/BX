#import "DXPFloatingAppController.h"
#import "DXPPanelSliderCell.h"
#import "DXPPanelSegmentCell.h"
#import "../DXHelper.h"
#import "../common.h"
#import <Preferences/PSSpecifier.h>

static NSString *DXFloatingLocalized(NSString *key) {
    return [[NSBundle bundleWithPath:bundlePath] localizedStringForKey:key value:key table:nil];
}

// 悬浮打开应用小窗的全局设置。比例与位置键由 DXFloatingCardMaxScaleFromPreferences /
// DXFloatingCardPositionFromPreferences 消费（SpringBoard 托管卡片读取同一份快照）。
@implementation DXPFloatingAppController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = DXFloatingLocalized(@"FLOATING_APP_SETTINGS");
}
- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;
    PSSpecifier *group = [PSSpecifier groupSpecifierWithName:DXFloatingLocalized(@"FLOATING_APP_SIZE_GROUP")];
    [group setProperty:DXFloatingLocalized(@"FLOATING_APP_SCALE_FOOTER") forKey:@"footerText"];
    PSSpecifier *scale = [PSSpecifier preferenceSpecifierNamed:DXFloatingLocalized(@"FLOATING_APP_MAX_SCALE") target:self
        set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:PSStaticTextCell edit:nil];
    [scale setProperty:kFloatingCardMaxScaleKey forKey:@"key"];
    [scale setProperty:@72 forKey:@"default"];
    [scale setProperty:DXPPanelSliderCell.class forKey:@"cellClass"];
    [scale setProperty:@30 forKey:@"min"];
    [scale setProperty:@100 forKey:@"max"];
    [scale setProperty:@YES forKey:@"showValue"];
    PSSpecifier *positionGroup = [PSSpecifier groupSpecifierWithName:DXFloatingLocalized(@"FLOATING_APP_POSITION_GROUP")];
    [positionGroup setProperty:DXFloatingLocalized(@"FLOATING_APP_POSITION_FOOTER") forKey:@"footerText"];
    PSSpecifier *position = [PSSpecifier preferenceSpecifierNamed:DXFloatingLocalized(@"FLOATING_APP_POSITION") target:self
        set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:PSStaticTextCell edit:nil];
    [position setProperty:kFloatingCardPositionKey forKey:@"key"];
    [position setProperty:@1 forKey:@"default"];
    [position setProperty:DXPPanelSegmentCell.class forKey:@"cellClass"];
    [position setProperty:@[DXFloatingLocalized(@"FLOATING_APP_POSITION_LEFT"), DXFloatingLocalized(@"FLOATING_APP_POSITION_CENTER"),
        DXFloatingLocalized(@"FLOATING_APP_POSITION_RIGHT")] forKey:@"titles"];
    PSSpecifier *shelfGroup = [PSSpecifier groupSpecifierWithName:DXFloatingLocalized(@"FLOATING_SHELF_GROUP")];
    [shelfGroup setProperty:DXFloatingLocalized(@"FLOATING_SHELF_FOOTER") forKey:@"footerText"];
    PSSpecifier *shelf = [PSSpecifier preferenceSpecifierNamed:DXFloatingLocalized(@"FLOATING_SHELF_SWITCH") target:self
        set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:) detail:nil cell:PSSwitchCell edit:nil];
    [shelf setProperty:kFloatingShelfEnabledKey forKey:@"key"]; [shelf setProperty:@NO forKey:@"default"];
    _specifiers = [@[shelfGroup, shelf, group, scale, positionGroup, position] mutableCopy];
    return _specifiers;
}
- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSDictionary *preferences = [DXPrefsManager.sharedInstance readPrefs];
    id value = preferences[[specifier propertyForKey:@"key"]];
    return [value respondsToSelector:@selector(floatValue)] ? value : [specifier propertyForKey:@"default"];
}
// 与 DXPKeyboardPanelController 相同：滑杆与分段单元都是自绘 80pt 行高。
- (CGFloat)tableView:(UITableView *)table heightForRowAtIndexPath:(NSIndexPath *)path {
    Class cellClass = [[self specifierAtIndexPath:path] propertyForKey:@"cellClass"];
    if (cellClass == DXPPanelSliderCell.class || cellClass == DXPPanelSegmentCell.class) return 80;
    return [super tableView:table heightForRowAtIndexPath:path];
}
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    if (![value isKindOfClass:NSNumber.class]) return;
    NSString *key = [specifier propertyForKey:@"key"];
    if ([key isEqual:kFloatingShelfEnabledKey]) {
        [DXPrefsManager.sharedInstance setValue:@([value boolValue]) forKey:key]; return;
    }
    NSInteger stored;
    if ([key isEqual:kFloatingCardPositionKey]) {
        stored = MIN(2, MAX(0, lround([value doubleValue])));
    } else {
        // 与滑杆 5% 步进一致；越界值夹回，避免写进快照后触发读取侧缺省回退。
        stored = MIN(100, MAX(30, lround([value doubleValue] / 5) * 5));
    }
    [DXPrefsManager.sharedInstance setValue:@(stored) forKey:key];
}
@end
