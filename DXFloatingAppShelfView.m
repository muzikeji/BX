#import "DXFloatingAppShelfView.h"
#import "DXFloatingAppShelfChannel.h"
#import "DXSystemOpenBroker.h"
#import "DXHelper.h"
#import "common.h"
#import "DXShared.h"
#import <notify.h>

@interface DXFloatingAppShelfView () <UIScrollViewDelegate>
@property(nonatomic, strong) UIScrollView *scroll;
@property(nonatomic, strong) UIPageControl *pages;
@property(nonatomic, strong) UILabel *message;
@property(nonatomic, strong) NSArray<UIButton *> *buttons;
@property(nonatomic, copy) NSDictionary *snapshot;
@property(nonatomic, copy) NSString *pendingIdentifier;
@property(nonatomic) NSUInteger requestGeneration;
@property(nonatomic) NSUInteger messageGeneration;
@property(nonatomic) CGSize previousSize;
@property(nonatomic) int token;
@end
@implementation DXFloatingAppShelfView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.token = NOTIFY_TOKEN_INVALID;
        self.clipsToBounds = YES;
        self.scroll = [UIScrollView new];
        self.scroll.delegate = self;
        self.scroll.pagingEnabled = YES;
        self.scroll.showsHorizontalScrollIndicator = NO;
        self.scroll.showsVerticalScrollIndicator = NO;
        self.scroll.directionalLockEnabled = YES;
        self.scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        self.scroll.semanticContentAttribute = UISemanticContentAttributeForceLeftToRight;
        [self addSubview:self.scroll];
        self.pages = [UIPageControl new];
        self.pages.userInteractionEnabled = NO;
        self.pages.pageIndicatorTintColor = UIColor.tertiaryLabelColor;
        self.pages.currentPageIndicatorTintColor = UIColor.secondaryLabelColor;
        self.pages.hidesForSinglePage = YES;
        [self addSubview:self.pages];
        self.message = [UILabel new];
        self.message.hidden = YES;
        self.message.numberOfLines = 2;
        self.message.textAlignment = NSTextAlignmentCenter;
        self.message.font = [UIFont systemFontOfSize:11];
        self.message.textColor = UIColor.labelColor;
        self.message.backgroundColor = UIColor.secondarySystemBackgroundColor;
        self.message.userInteractionEnabled = NO;
        [self addSubview:self.message];
        __weak typeof(self) weakSelf = self;
        int token = NOTIFY_TOKEN_INVALID;
        if (notify_register_dispatch(DXFloatingShelfChangedName, &token, dispatch_get_main_queue(), ^(__unused int changed) {
            [weakSelf refresh];
        }) == NOTIFY_STATUS_OK) self.token = token;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh) name:UIKeyboardDidShowNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh) name:UIApplicationDidBecomeActiveNotification object:nil];
        [self refresh];
    }
    return self;
}
- (void)dealloc {
    if (self.token != NOTIFY_TOKEN_INVALID) notify_cancel(self.token);
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}
- (BOOL)hasApps { return [self.snapshot[@"unlocked"] boolValue] && [self.snapshot[@"items"] count] > 0; }
- (void)didMoveToWindow { [super didMoveToWindow]; if (self.window) [self refresh]; }
- (void)refresh {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self refresh]; }); return; }
    NSDictionary *snapshot = DXReadFloatingShelf();
    if (!snapshot || [snapshot isEqual:self.snapshot]) return;
    NSArray *oldIDs = [self.snapshot[@"items"] valueForKey:@"bundleID"];
    NSArray *newIDs = [snapshot[@"items"] valueForKey:@"bundleID"];
    BOOL orderChanged = ![oldIDs isEqual:newIDs];
    NSString *previousActive = self.snapshot[@"active"];
    BOOL minimizedFirst = previousActive.length && ![snapshot[@"active"] length] &&
        [newIDs.firstObject isEqual:previousActive];
    self.snapshot = snapshot;
    for (UIButton *button in self.buttons) [button removeFromSuperview];
    NSMutableArray *buttons = [NSMutableArray array];
    for (NSDictionary *item in snapshot[@"items"]) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.accessibilityIdentifier = item[@"bundleID"];
        button.accessibilityLabel = item[@"title"];
        BOOL active = [snapshot[@"active"] isEqual:item[@"bundleID"]];
        BOOL foreground = [snapshot[@"foreground"] isEqual:item[@"bundleID"]];
        button.accessibilityValue = active ? LOCALIZED(@"FLOATING_SHELF_ACTIVE") :
            (foreground ? LOCALIZED(@"FLOATING_SHELF_FOREGROUND") : nil);
        button.backgroundColor = active ? [UIColor.systemBlueColor colorWithAlphaComponent:0.12] : UIColor.clearColor;
        button.layer.cornerRadius = 8;
        UIImage *icon = [DXHelper appIconImageForBundleID:item[@"bundleID"]] ?: [UIImage systemImageNamed:@"app"];
        [button setImage:icon forState:UIControlStateNormal];
        button.imageView.contentMode = UIViewContentModeScaleAspectFit;
        button.tintColor = UIColor.secondaryLabelColor;
        button.enabled = !active && !foreground && ![self.pendingIdentifier isEqual:item[@"bundleID"]];
        [button addTarget:self action:@selector(activate:) forControlEvents:UIControlEventTouchUpInside];
        [self.scroll addSubview:button];
        [buttons addObject:button];
    }
    self.buttons = buttons;
    self.pages.numberOfPages = MAX(1, (NSInteger)(buttons.count + 3) / 4);
    self.scroll.scrollEnabled = buttons.count > 4;
    if (orderChanged || minimizedFirst) { self.scroll.contentOffset = CGPointZero; self.pages.currentPage = 0; }
    [self setNeedsLayout];
    if (self.contentChanged) self.contentChanged();
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.bounds), height = CGRectGetHeight(self.bounds);
    NSInteger page = self.pages.currentPage;
    self.scroll.frame = self.bounds;
    self.scroll.contentSize = CGSizeMake(width * self.pages.numberOfPages, height);
    for (NSUInteger index = 0; index < self.buttons.count; index++) {
        self.buttons[index].frame = CGRectMake(index * width / 4 + 3, DXBottomToolbarCellTopInset,
            MAX(0, width / 4 - 6), MAX(0, MIN(33, height - DXBottomToolbarCellTopInset)));
    }
    self.pages.frame = CGRectMake(0, MAX(0, height - 8), width, 8);
    self.message.frame = CGRectMake(0, DXBottomToolbarCellTopInset, width, MAX(0, height - DXBottomToolbarCellTopInset));
    if (!CGSizeEqualToSize(self.previousSize, self.bounds.size)) {
        self.previousSize = self.bounds.size;
        self.scroll.contentOffset = CGPointMake(MIN(page, self.pages.numberOfPages - 1) * width, 0);
    }
}
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    CGFloat width = CGRectGetWidth(scrollView.bounds);
    if (width > 0) self.pages.currentPage = MIN(self.pages.numberOfPages - 1, MAX(0, (NSInteger)lround(scrollView.contentOffset.x / width)));
}
- (void)activate:(UIButton *)button {
    NSDictionary *preferences = DXPrefsManager.sharedInstance.prefs;
    if (!self.window || self.hidden || self.pendingIdentifier ||
        ![preferences[kFloatingShelfEnabledKey] isKindOfClass:NSNumber.class] || ![preferences[kFloatingShelfEnabledKey] boolValue] || ![self.buttons containsObject:button]) return;
    NSString *identifier = [button.accessibilityIdentifier copy];
    uint64_t revision = [self.snapshot[@"revision"] unsignedLongLongValue];
    self.pendingIdentifier = identifier;
    NSUInteger generation = ++self.requestGeneration;
    button.enabled = NO;
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.center = CGPointMake(CGRectGetMidX(button.bounds), CGRectGetMidY(button.bounds));
    [button addSubview:spinner]; [spinner startAnimating];
    __weak typeof(self) weakSelf = self;
    DXRestoreFloatingApplication(identifier, revision, ^(DXSystemOpenResult result) {
        DXFloatingAppShelfView *view = weakSelf;
        if (!view || view.requestGeneration != generation || ![view.pendingIdentifier isEqual:identifier]) return;
        view.pendingIdentifier = nil;
        [spinner removeFromSuperview];
        for (UIButton *current in view.buttons) current.enabled =
            ![view.snapshot[@"active"] isEqual:current.accessibilityIdentifier] &&
            ![view.snapshot[@"foreground"] isEqual:current.accessibilityIdentifier];
        [view refresh];
        if (result != DXSystemOpenSucceeded && view.window && !view.hidden) {
            NSUInteger messageGeneration = ++view.messageGeneration;
            view.message.text = LOCALIZED(@"FLOATING_SHELF_RESTORE_FAILED"); view.message.hidden = NO;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                if (weakSelf.messageGeneration == messageGeneration) weakSelf.message.hidden = YES;
            });
        }
    });
}
@end
