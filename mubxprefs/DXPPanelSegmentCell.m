#import "DXPPanelSegmentCell.h"
#import <Preferences/PSSpecifier.h>

// 分段选择行：段标题来自 specifier 的 "titles" 数组，选中下标即写入值
// （经 performGetter/performSetterWithValue: 走控制器的读写回调）。
@interface DXPPanelSegmentCell ()
@property(nonatomic, strong) UILabel *settingTitle;
@property(nonatomic, strong) UISegmentedControl *segment;
@end

@implementation DXPPanelSegmentCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier specifier:(PSSpecifier *)specifier {
    if ((self = [super initWithStyle:style reuseIdentifier:identifier specifier:specifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.textLabel.hidden = YES;
        self.settingTitle = [UILabel new];
        self.settingTitle.font = [UIFont systemFontOfSize:16];
        self.settingTitle.textColor = UIColor.labelColor;
        self.segment = [[UISegmentedControl alloc] init];
        [self.segment addTarget:self action:@selector(changed:) forControlEvents:UIControlEventValueChanged];
        [self.contentView addSubview:self.settingTitle];
        [self.contentView addSubview:self.segment];
        [self refreshCellContentsWithSpecifier:specifier];
    }
    return self;
}
- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    self.settingTitle.text = specifier.name;
    [self.segment removeAllSegments];
    for (NSString *title in [specifier propertyForKey:@"titles"]) {
        [self.segment insertSegmentWithTitle:title atIndex:self.segment.numberOfSegments animated:NO];
    }
    NSInteger value = lroundf([[specifier performGetter] floatValue]);
    self.segment.selectedSegmentIndex = MAX(0, MIN(self.segment.numberOfSegments - 1, value));
}
- (void)changed:(UISegmentedControl *)sender {
    [self.specifier performSetterWithValue:@(sender.selectedSegmentIndex)];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.contentView.bounds.size.width;
    self.settingTitle.frame = CGRectMake(16, 8, MAX(0, width - 32), 24);
    self.segment.frame = CGRectMake(16, 36, MAX(0, width - 32), 32);
}
@end
