#import "DXPKeyboardPanelPreviewHeader.h"
#import "DXPKeyboardPanelPreviewView.h"
#import "../common.h"

@interface DXPKeyboardPanelPreviewHeader ()
@property(nonatomic, copy) NSString *panelSelector;
@property(nonatomic, strong) UILabel *caption;
@property(nonatomic, strong) DXPKeyboardPanelPreviewView *preview;
@end
@implementation DXPKeyboardPanelPreviewHeader
- (instancetype)initWithPanelSelector:(NSString *)selector {
    if ((self = [super initWithFrame:CGRectMake(0, 0, 320, 436)])) {
        self.panelSelector = selector;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        self.caption = [UILabel new];
        self.caption.text = @"面板预览（顶部状态为示意）";
        self.caption.textColor = UIColor.secondaryLabelColor;
        self.caption.font = [UIFont systemFontOfSize:13];
        [self addSubview:self.caption];
        self.preview = [DXPKeyboardPanelPreviewView new];
        [self addSubview:self.preview];
        [self refresh];
    }
    return self;
}
- (void)refresh { [self.preview configureWithPreferences:[DXPrefsManager.sharedInstance readPrefs] panelSelector:self.panelSelector]; }
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = MAX(0, self.bounds.size.width - 32);
    self.caption.frame = CGRectMake(20, 12, width, 20);
    self.preview.frame = CGRectMake(16, 40, width, 380);
}
@end
