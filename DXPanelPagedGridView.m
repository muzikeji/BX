#import "DXPanelPagedGridView.h"
#import "DXKeyboardPanelLayout.h"

@interface DXPanelPagedGridView ()
@property(nonatomic, copy) NSArray<UIView *> *items;
@property(nonatomic, strong) UIControl *blank;
@property(nonatomic) NSInteger columns;
@property(nonatomic) CGFloat scale;
@property(nonatomic, readwrite) NSUInteger pageCount;
@property(nonatomic, readwrite) NSUInteger currentPage;
@property(nonatomic) CGSize lastLayoutSize;
@property(nonatomic) BOOL needsPageReset;
@property(nonatomic) BOOL updatingLayout;
@end

@implementation DXPanelPagedGridView
- (instancetype)init { return [self initWithFrame:CGRectZero]; }
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.columns = 4;
        self.scale = 1;
        self.delegate = self;
        self.pagingEnabled = YES;
        self.directionalLockEnabled = YES;
        self.showsVerticalScrollIndicator = NO;
        self.showsHorizontalScrollIndicator = YES;
        self.alwaysBounceVertical = NO;
        self.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        self.semanticContentAttribute = UISemanticContentAttributeForceLeftToRight;
        self.canCancelContentTouches = YES;
        self.delaysContentTouches = YES;
        self.blank = [UIControl new];
        [self.blank addTarget:self action:@selector(blankTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.blank];
    }
    return self;
}
- (void)configureWithItems:(NSArray<UIView *> *)items columns:(NSInteger)columns scale:(CGFloat)scale {
    if (!NSThread.isMainThread) return;
    for (UIView *item in self.items) [item removeFromSuperview];
    self.items = [items copy];
    self.columns = MAX(1, columns);
    self.scale = scale;
    self.pageCount = DXPanelPageCount(items.count, self.columns);
    self.currentPage = 0;
    self.needsPageReset = YES;
    self.alwaysBounceHorizontal = self.pageCount > 1;
    self.scrollEnabled = self.pageCount > 1;
    for (UIView *item in self.items) [self addSubview:item];
    [self setNeedsLayout];
}
- (CGFloat)preferredHeightForWidth:(CGFloat)width {
    return DXPanelPageHeight(self.items.count, width, self.columns, self.scale);
}
- (void)layoutSubviews {
    self.updatingLayout = YES;
    [super layoutSubviews];
    CGSize size = self.bounds.size;
    if (!isfinite(size.width) || size.width <= 0 || !isfinite(size.height) || size.height < 0) {
        self.updatingLayout = NO;
        return;
    }
    BOOL reposition = self.needsPageReset || !CGSizeEqualToSize(size, self.lastLayoutSize);
    self.currentPage = self.pageCount ? MIN(self.currentPage, self.pageCount - 1) : 0;
    for (NSUInteger index = 0; index < self.items.count; index++) {
        self.items[index].frame = DXPanelPagedItemFrame(index, self.items.count, size.width, self.columns, self.scale);
    }
    self.contentSize = CGSizeMake(MAX(1, self.pageCount) * size.width, size.height);
    self.blank.frame = CGRectMake(0, 0, self.contentSize.width, size.height);
    if (reposition) {
        [self setContentOffset:CGPointMake(DXPanelPageOffset(self.currentPage, self.pageCount, size.width), 0) animated:NO];
    }
    self.lastLayoutSize = size;
    self.needsPageReset = NO;
    self.updatingLayout = NO;
    self.accessibilityValue = self.pageCount > 1 ?
        [NSString stringWithFormat:@"%lu / %lu", (unsigned long)self.currentPage + 1, (unsigned long)self.pageCount] : nil;
}
- (BOOL)touchesShouldCancelInContentView:(UIView *)view {
    // A drag beginning on an icon or empty slot must page rather than fire
    // its TouchUpInside action. UIKit still handles the real pan arbitration.
    (void)view;
    return YES;
}
- (void)blankTapped {
    if (NSThread.isMainThread && self.blankAction) self.blankAction();
}
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView != self || self.updatingLayout || self.needsPageReset ||
        !CGSizeEqualToSize(self.bounds.size, self.lastLayoutSize)) return;
    self.currentPage = DXPanelPageAtOffset(self.contentOffset.x, self.pageCount, self.bounds.size.width);
    self.accessibilityValue = self.pageCount > 1 ?
        [NSString stringWithFormat:@"%lu / %lu", (unsigned long)self.currentPage + 1, (unsigned long)self.pageCount] : nil;
}
- (void)logPage {
    if (!self.diagnosticName.length || !self.window || self.pageCount < 2) return;
    NSLog(@"[MUBX][PanelGrid] page kind=%@ page=%lu/%lu items=%lu", self.diagnosticName,
        (unsigned long)self.currentPage + 1, (unsigned long)self.pageCount, (unsigned long)self.items.count);
}
- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView { if (scrollView == self) [self logPage]; }
- (void)scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView { if (scrollView == self) [self logPage]; }
- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (scrollView == self && !decelerate) [self logPage];
}
@end
