#import "DXPKeyboardPanelPreviewView.h"
#import "../DXKeyboardPanelPreferences.h"
#import "../DXKeyboardPanelLayout.h"
#import "../DXPanelPagedGridView.h"
#import "../DXGlobalPanelGeometry.h"
#import "../DXPanelSystemControlsView.h"
#import "../DXHelper.h"
#import "../common.h"
#import "DXPPanelActionCatalog.h"

@interface DXPKeyboardPanelPreviewView ()
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UIScrollView *scroll;
@property(nonatomic, strong) DXPanelPagedGridView *grid;
@property(nonatomic, strong) DXPanelSystemControlsView *systemControls;
@property(nonatomic, copy) NSArray<UIView *> *items;
@property(nonatomic) NSInteger columns;
@property(nonatomic) CGFloat scale;
@property(nonatomic) BOOL gesturePanel;
@end
@implementation DXPKeyboardPanelPreviewView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.layer.cornerRadius = 22;
        self.clipsToBounds = YES;
        self.titleLabel = [UILabel new];
        self.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        [self addSubview:self.titleLabel];
        self.systemControls = [DXPanelSystemControlsView new];
        self.scroll = [UIScrollView new];
        self.scroll.showsVerticalScrollIndicator = YES;
        self.scroll.directionalLockEnabled = YES;
        [self addSubview:self.scroll];
        [self.scroll addSubview:self.systemControls];
        self.grid = [DXPanelPagedGridView new];
        [self.scroll addSubview:self.grid];
    }
    return self;
}
- (void)configureWithPreferences:(NSDictionary *)preferences panelSelector:(NSString *)selector {
    if (!NSThread.isMainThread) return;
    NSDictionary *panel = DXPanelDefinition(preferences, selector);
    self.gesturePanel = [panel[@"kind"] isEqual:DXPanelGestureKind];
    preferences = DXPanelPreferences(preferences, selector);
    self.titleLabel.text = DXPanelString(panel[@"name"]);
    BOOL dark = DXKeyboardPanelBool(preferences, kDXPanelDark, YES);
    UIColor *textColor = dark ? UIColor.whiteColor : UIColor.labelColor;
    self.backgroundColor = dark ? [UIColor colorWithWhite:0.10 alpha:1] : UIColor.systemBackgroundColor;
    [self.systemControls configureWithPreferences:preferences preview:YES];
    self.titleLabel.textColor = textColor;
    self.columns = (NSInteger)DXKeyboardPanelNumber(preferences, kDXPanelColumns, 4, 3, 5);
    self.scale = DXKeyboardPanelNumber(preferences, kDXPanelScale, 100, 70, 120) / 100;
    for (UIView *item in self.items) [item removeFromSuperview];
    NSArray *entries = DXPanelItems(preferences, selector);
    NSMutableArray *items = [NSMutableArray array];
    for (NSDictionary *entry in entries) {
        NSDictionary *definition = DXPPanelDisplayDefinition(preferences, entry[@"selector"]);
        UIView *item = [UIView new];
        UIView *circle = [UIView new];
        circle.tag = 1;
        circle.backgroundColor = dark ? [UIColor colorWithWhite:0 alpha:0.45] : [UIColor colorWithWhite:1 alpha:0.65];
        [item addSubview:circle];
        UIImageView *icon = [UIImageView new];
        icon.tag = 2;
        icon.contentMode = UIViewContentModeScaleAspectFit;
        icon.tintColor = textColor;
        id iconConfig = definition[@"icon"];
        if (![iconConfig isKindOfClass:NSString.class]) iconConfig = @"link";
        icon.image = [DXHelper imageForIconConfig:iconConfig defaultSymbolName:@"link"];
        [item addSubview:icon];
        UILabel *label = [UILabel new];
        label.tag = 3;
        id name = [entry[@"name"] length] ? entry[@"name"] : definition[@"name"];
        label.text = [name isKindOfClass:NSString.class] ? name : @"自定义动作";
        label.textColor = textColor;
        label.font = [UIFont systemFontOfSize:12 * self.scale];
        label.numberOfLines = 2;
        label.textAlignment = NSTextAlignmentCenter;
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = 0.8;
        [item addSubview:label];
        item.isAccessibilityElement = YES;
        item.accessibilityLabel = label.text;
        [items addObject:item];
    }
    self.items = items;
    [self.grid configureWithItems:items columns:self.columns scale:self.scale];
    self.scroll.contentOffset = CGPointZero;
    [self setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width;
    self.titleLabel.frame = CGRectMake(16, 10, MAX(0, width - 32), 28);
    CGFloat controlsHeight = [self.systemControls preferredHeightForWidth:MAX(0, width - 16)];
    self.scroll.frame = CGRectMake(8, 46, MAX(0, width - 16), MAX(0, self.bounds.size.height - 54));
    self.systemControls.frame = CGRectMake(0, 0, self.scroll.bounds.size.width, controlsHeight);
    CGFloat contentWidth = self.scroll.bounds.size.width;
    CGFloat gridHeight = [self.grid preferredHeightForWidth:contentWidth];
    self.grid.frame = CGRectMake(0, controlsHeight, contentWidth, gridHeight);
    // setFrame 只标记父视图需要布局；栅格若已在更早的零宽轮次消费掉 needsLayout，
    // 这里不强制置脏就会跳过 item 定位，图标错位且标签宽度归零。
    [self.grid setNeedsLayout];
    [self.grid layoutIfNeeded];
    CGFloat circleSize = DXKeyboardPanelCircle(contentWidth, self.columns, self.scale);
    [self.items enumerateObjectsUsingBlock:^(UIView *item, NSUInteger index, BOOL *stop) {
        (void)index;
        (void)stop;
        CGFloat itemWidth = contentWidth / MAX(1, self.columns);
        UIView *circle = [item viewWithTag:1];
        circle.frame = CGRectMake((itemWidth - circleSize) / 2, 4, circleSize, circleSize);
        circle.layer.cornerRadius = circleSize / 2;
        CGFloat iconSize = circleSize * 0.52;
        [item viewWithTag:2].frame = CGRectMake((itemWidth - iconSize) / 2, 4 + (circleSize - iconSize) / 2, iconSize, iconSize);
        UILabel *label = (UILabel *)[item viewWithTag:3];
        CGSize labelSize = [label sizeThatFits:CGSizeMake(MAX(0, itemWidth - 6), 30 * self.scale)];
        label.frame = self.gesturePanel ? DXGlobalPanelLabelFrame(itemWidth, circleSize, self.scale, labelSize.height)
            : CGRectMake(3, circleSize + 9, MAX(0, itemWidth - 6), 30 * self.scale);
    }];
    self.scroll.contentSize = CGSizeMake(contentWidth, MAX(self.scroll.bounds.size.height, controlsHeight + gridHeight));
}
@end
