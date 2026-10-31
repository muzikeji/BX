#import "DXPPanelSliderCell.h"
#import <Preferences/PSSpecifier.h>
#import "../DXKeyboardPanelPreferences.h"

@interface DXPPanelSliderCell ()
@property(nonatomic, strong) UILabel *settingTitle;
@property(nonatomic, strong) UILabel *settingValue;
@property(nonatomic, strong) UISlider *slider;
@end
@implementation DXPPanelSliderCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier specifier:(PSSpecifier *)specifier {
    if ((self = [super initWithStyle:style reuseIdentifier:identifier specifier:specifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.textLabel.hidden = YES;
        self.settingTitle = [UILabel new];
        self.settingTitle.font = [UIFont systemFontOfSize:16];
        self.settingTitle.textColor = UIColor.labelColor;
        self.settingValue = [UILabel new];
        self.settingValue.textAlignment = NSTextAlignmentRight;
        self.settingValue.textColor = UIColor.secondaryLabelColor;
        self.settingValue.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightRegular];
        self.slider = [UISlider new];
        [self.slider addTarget:self action:@selector(changed:) forControlEvents:UIControlEventValueChanged];
        for (UIView *view in @[self.settingTitle, self.settingValue, self.slider]) [self.contentView addSubview:view];
        [self refreshCellContentsWithSpecifier:specifier];
    }
    return self;
}
- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    self.settingTitle.text = specifier.name;
    self.slider.minimumValue = [[specifier propertyForKey:@"min"] floatValue];
    self.slider.maximumValue = [[specifier propertyForKey:@"max"] floatValue];
    self.slider.value = [[specifier performGetter] floatValue];
    [self updateValueLabel];
}
- (void)updateValueLabel {
    BOOL columns = [self isColumnsSpecifier];
    self.settingValue.text = [NSString stringWithFormat:columns ? @"%ld 个" : @"%ld%%", (long)lroundf(self.slider.value)];
}
// Per-side pages store the profile key in "key" and the shared base key in
// "legacyKey" (DXPKeyboardPanelController -setting:key:...); match on the base.
- (BOOL)isColumnsSpecifier {
    NSString *baseKey = [self.specifier propertyForKey:@"legacyKey"] ?: [self.specifier propertyForKey:@"key"];
    return [baseKey isEqual:kDXPanelColumns];
}
- (void)changed:(UISlider *)sender {
    BOOL columns = [self isColumnsSpecifier];
    sender.value = columns ? lroundf(sender.value) : lroundf(sender.value / 5) * 5;
    [self updateValueLabel];
    [self.specifier performSetterWithValue:@(sender.value)];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.contentView.bounds.size.width;
    self.settingTitle.frame = CGRectMake(16, 8, MAX(0, width - 116), 24);
    self.settingValue.frame = CGRectMake(width - 96, 8, 80, 24);
    self.slider.frame = CGRectMake(16, 36, MAX(0, width - 32), 32);
}
@end
