#import "common.h"
#import "DXShared.h"
#import "DXCollectionView.h"
#import "DXHelper.h"
#import "DXAIPanel.h"
#import "DXClipboardPanel.h"
#import "DXKeyboardPanel.h"
#import "DXKeyboardPanelPreferences.h"
#import "DXPanelRegistry.h"
#import "DXToolbarHorizontalGesture.h"
#import "DXSystemOpenBroker.h"
#import "DXFloatingAppSession.h"
#import "DXJavaScriptHost.h"
#import "DXPixPinIntegration.h"

#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <SafariServices/SafariServices.h>

static const NSInteger DXCustomActionToastTag = 0x54584341;
static char DXCustomOpenGenerationKey;
static const NSInteger DXSubActionPanelOverlayTag = 0x54585341;
static __weak DXCollectionView *DXActiveSubActionPanelOwner;
// Strong handle on the dedicated panel window (iOS 17+ presentation path);
// created per present, hidden and released on dismiss.
static UIWindow *DXSubActionPanelFloatingHostWindow;

typedef void (^DXCustomActionOpenCompletion)(BOOL success);

@interface DXSubActionPanelItem : UIControl
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, copy) NSString *actionSelector;
@property (nonatomic, assign) CGFloat panelScale;
- (void)configureWithTitle:(NSString *)title image:(UIImage *)image;
@end

@implementation DXSubActionPanelItem

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconView.tintColor = UIColor.labelColor;
    [self addSubview:self.iconView];

    self.nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.nameLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    self.nameLabel.textColor = UIColor.labelColor;
    self.nameLabel.textAlignment = NSTextAlignmentCenter;
    self.nameLabel.numberOfLines = 2;
    self.nameLabel.adjustsFontSizeToFitWidth = YES;
    self.nameLabel.minimumScaleFactor = 0.8;
    [self addSubview:self.nameLabel];

    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    return self;
}

- (void)configureWithTitle:(NSString *)title image:(UIImage *)image {
    self.nameLabel.text = title;
    // Symbols template into the label color, but app icons arrive
    // always-original and must keep their artwork.
    UIImage *resolved = image;
    if (resolved && resolved.renderingMode != UIImageRenderingModeAlwaysOriginal) {
        resolved = [resolved imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    self.iconView.image = resolved;
    self.accessibilityLabel = title;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat scale = self.panelScale > 0 ? self.panelScale : 1.0;
    CGFloat iconSide = MIN(CGRectGetWidth(self.bounds) - 12.0, 38.0 * scale);
    CGFloat iconTop = 10.0 * scale;
    self.iconView.frame = CGRectMake((CGRectGetWidth(self.bounds) - iconSide) / 2.0, iconTop,
                                     iconSide, iconSide);
    CGFloat labelY = CGRectGetMaxY(self.iconView.frame) + 7.0 * scale;
    self.nameLabel.frame = CGRectMake(4.0, labelY, CGRectGetWidth(self.bounds) - 8.0,
                                      MAX(0.0, CGRectGetHeight(self.bounds) - labelY - 4.0));
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [UIView animateWithDuration:0.08 animations:^{
        self.alpha = highlighted ? 0.45 : 1.0;
        self.transform = highlighted ? CGAffineTransformMakeScale(0.94, 0.94) : CGAffineTransformIdentity;
    }];
}

@end

@interface DXTextActionPanelItem : UIButton
@property (nonatomic, copy) NSString *recordText;
@end
@implementation DXTextActionPanelItem
- (CGRect)titleRectForContentRect:(CGRect)contentRect {
    return UIEdgeInsetsInsetRect(contentRect, UIEdgeInsetsMake(8, 12, 8, 12));
}
@end

static BOOL DXIsHiddenShortcutSelector(NSString *selector) {
    return ![DXShortcutsGenerator isVisibleShortcutSelector:selector];
}

@interface DXCollectionView ()
@property (nonatomic, assign, readwrite) BOOL shortcutConfigurationAvailable;
// 上次成功应用的偏好快照引用：键盘出现路径的整表重载门控依据（顺序闪变修复）。
@property (nonatomic, strong) NSDictionary *dxAppliedPrefsSnapshot;
@property (nonatomic, assign) BOOL dxPreviewMode;
@property (nonatomic, copy) NSDictionary *dxPreviewPreferences;
@property (nonatomic, assign, readwrite) CGFloat bottomSpacing;
@property (nonatomic, assign, readwrite) NSInteger buttonsPerRow;
@property (nonatomic, assign, readwrite) CGFloat rowSpacing;
@property (nonatomic, strong) UIControl *subActionPanelOverlay;
@property (nonatomic, strong) UIButton *subActionPanelSourceButton;
@property (nonatomic, weak) id textPanelInput;
@property (nonatomic, weak) UIWindow *textPanelSourceWindow;
- (CGFloat)dxChromeFloat:(NSString *)key fallback:(CGFloat)fallback;
- (BOOL)dxChromeBool:(NSString *)key fallback:(BOOL)fallback;
- (UIColor *)dxButtonBackgroundTintColor;
- (UIColor *)dxButtonTintColor;
- (void)presentActionChooserForButton:(UIButton *)button selectors:(NSArray<NSString *> *)selectors
                         textRecords:(NSArray<NSString *> *)textRecords;
@end

// Shortcut order is a user-authored, physical left-to-right order. Keyboard
// accessory views can temporarily inherit a different semantic direction while
// UIKit moves them into its private keyboard hierarchy. UICollectionViewFlowLayout
// otherwise mirrors horizontal item positions when that direction changes,
// producing a reversed first frame followed by the configured order.
@interface DXTopShortcutFlowLayout : UICollectionViewFlowLayout
@end

@implementation DXTopShortcutFlowLayout

- (BOOL)flipsHorizontallyInOppositeLayoutDirection {
    return NO;
}

@end

// 多行模式布局：按钮按行填充，第一行钉在工具栏底部（贴键盘），第二行向上
// 堆叠。UICollectionViewFlowLayout 按方向整行/整列顺序填充，表达不了"短行
// 位于顶部"（末行不满时缺口会落在填充序列中段），所以直接自绘几何。
@interface DXMultiRowTopLayout : UICollectionViewLayout
@end

@implementation DXMultiRowTopLayout

- (DXCollectionView *)toolbar {
    return (DXCollectionView *)self.collectionView;
}

- (NSInteger)dxColumnCount {
    return MAX(1, self.toolbar.buttonsPerRow);
}

- (CGFloat)dxVerticalGap {
    return self.toolbar.rowSpacing;
}

- (CGFloat)dxHorizontalGap {
    return [self.toolbar buttonChromeActive] ? self.toolbar.buttonSpacing : 0.0;
}

- (CGFloat)dxHorizontalInset {
    return [self.toolbar buttonChromeActive] ? self.toolbar.buttonSpacing / 2.0 : 0.0;
}

// 逻辑行数：ceil(按钮数 / 每行个数)，空工具栏按 1 行占位，最多 2 行。
- (NSInteger)dxRowCount {
    NSInteger items = [self.collectionView numberOfItemsInSection:0];
    if (items <= 0) return 1;
    return MIN(maxMultiRowRows,
               (NSInteger)ceil((double)items / (double)self.dxColumnCount));
}

- (CGSize)collectionViewContentSize {
    CGFloat height = 8.0 + self.dxRowCount * self.toolbar.buttonHeight
                   + MAX(0, self.dxRowCount - 1) * self.dxVerticalGap
                   + self.toolbar.bottomSpacing;
    return CGSizeMake(MAX(0.0, CGRectGetWidth(self.collectionView.bounds)), height);
}

- (NSArray<UICollectionViewLayoutAttributes *> *)layoutAttributesForElementsInRect:(CGRect)rect {
    NSMutableArray *attributes = [NSMutableArray array];
    NSInteger items = [self.collectionView numberOfItemsInSection:0];
    for (NSInteger item = 0; item < items; item++) {
        UICollectionViewLayoutAttributes *attribute = [self layoutAttributesForItemAtIndexPath:
            [NSIndexPath indexPathForItem:item inSection:0]];
        if (!attribute) continue;
        if (CGRectIntersectsRect(attribute.frame, rect)) [attributes addObject:attribute];
    }
    return attributes;
}

- (UICollectionViewLayoutAttributes *)layoutAttributesForItemAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger columns = self.dxColumnCount;
    NSInteger row = indexPath.item / columns;      // 0 = 底行（第一行，贴键盘）
    NSInteger column = indexPath.item % columns;
    CGFloat verticalGap = self.dxVerticalGap;
    CGFloat horizontalGap = self.dxHorizontalGap;
    CGFloat cellHeight = MAX(1.0, self.toolbar.buttonHeight);
    CGFloat usableWidth = MAX(0.0, CGRectGetWidth(self.collectionView.bounds) - 2.0 * self.dxHorizontalInset);
    CGFloat cellWidth = MAX(0.0, (usableWidth - (columns - 1) * horizontalGap) / columns);
    CGFloat contentHeight = [self collectionViewContentSize].height;
    CGFloat y = contentHeight - self.toolbar.bottomSpacing
              - (row + 1) * cellHeight - row * verticalGap;
    CGFloat x = self.dxHorizontalInset + column * (cellWidth + horizontalGap);

    UICollectionViewLayoutAttributes *attributes =
        [UICollectionViewLayoutAttributes layoutAttributesForCellWithIndexPath:indexPath];
    attributes.frame = CGRectMake(x, y, cellWidth, cellHeight);
    return attributes;
}

- (BOOL)shouldInvalidateLayoutForBoundsChange:(CGRect)newBounds {
    return !CGSizeEqualToSize(newBounds.size, self.collectionView.bounds.size);
}

@end

@implementation DXCollectionView

// Resolves one configured shortcut entry into the parallel toolbar arrays.  The
// iOS 13 image slot takes the custom SF Symbol when it validates, and custom
// names are keyed by selector for short-label mode. iOS 12 has no SF Symbols,
// so images12 always keeps its default value.
-(void)integrateShortcutItem:(NSDictionary *)item
              intoImages12:(NSMutableArray *)images12
               images13:(NSMutableArray *)images13
               selectors:(NSMutableArray *)selectors
                    names:(NSMutableDictionary *)names {
    NSString *selector = item[@"selector"];
    [images12 addObject:item[@"images12"]];
    [images13 addObject:[DXHelper resolvedIconNameForShortcutItem:item defaultName:item[@"images13"]]];
    [selectors addObject:selector];

    NSString *customName = [DXHelper customNameForShortcutItem:item];
    if (customName) names[selector] = customName;
}

- (NSString *)scopedPreferenceKey:(NSString *)key {
    return DXScopedPreferenceKey(key, self.configuration ?: @"bottom");
}

// 多行模式（仅顶部）：单节承载全部按钮，由 DXMultiRowTopLayout 负责换行；
// 不再走"节=分页"的横滑模型。
- (BOOL)multiRowActive {
    return [self.configuration isEqualToString:@"top"];
}

// Button chrome is per toolbar: every value lives under the configuration-
// scoped key ("top"-prefixed on top of the keyboard, unprefixed below), so
// adjusting one toolbar never moves the other. Call after `prefs` reflects the
// current preference snapshot.
-(void)reloadButtonChrome {
    BOOL isTop = [self.configuration isEqualToString:@"top"];
    CGFloat heightFallback = isTop ? 33.33
        : ([self dxButtonBackgroundTintColor] ? cellsHeightDefault + 5 : cellsHeightDefault);
    self.buttonHeight = [self dxChromeFloat:kCellHeightkey fallback:heightFallback];
    self.buttonRadius = [self dxChromeFloat:kCellRadiuskey fallback:cellsRadiusDefault];
    self.buttonSpacing = [self dxChromeFloat:kCellSpacingkey fallback:spacingBetweenCellsDefault];
    self.bottomSpacing = isTop ? MIN(20.0, MAX(0.0,
        [self dxChromeFloat:kBottomSpacingKey fallback:topBottomSpacingDefault])) : 0.0;
    self.borderEnabled = [self dxChromeBool:kCellBorderEnabledkey fallback:NO];
    self.borderWidth = [self dxChromeFloat:kCellBorderWidthkey fallback:buttonBorderWidthDefault];
    self.widthScale = MIN(100, MAX(30, [self dxChromeFloat:kButtonWidthScalekey fallback:buttonWidthScaleDefault]));
    self.useShortLabel = [self dxChromeBool:kShortLabelEnabledKey fallback:NO];
    // 顶部固定使用多行布局；每行个数夹在 [1, 8] 防御 plist
    // 手改出的越界值（设置页滑动条本身已限范围）。
    float storedPerRow = [self dxChromeFloat:kButtonsPerRowKey fallback:buttonsPerRowDefault];
    self.buttonsPerRow = MIN(8, MAX(1, (NSInteger)storedPerRow));
    self.rowSpacing = MIN(20.0, MAX(0.0,
        [self dxChromeFloat:kMultiRowSpacingKey fallback:multiRowSpacingDefault]));
}

- (CGFloat)dxChromeFloat:(NSString *)key fallback:(CGFloat)fallback {
    NSString *scopedKey = [self scopedPreferenceKey:key];
    if (!self.dxPreviewMode) return preferencesFloat(scopedKey, fallback);
    id value = self.dxPreviewPreferences[scopedKey];
    return [value respondsToSelector:@selector(floatValue)] ? [value floatValue] : fallback;
}

- (BOOL)dxChromeBool:(NSString *)key fallback:(BOOL)fallback {
    NSString *scopedKey = [self scopedPreferenceKey:key];
    if (!self.dxPreviewMode) return preferencesBool(scopedKey, fallback);
    id value = self.dxPreviewPreferences[scopedKey];
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}

- (UIColor *)dxButtonBackgroundTintColor {
    if (!self.dxPreviewMode) return currentBackgroundTintColor;
    NSDictionary *snapshot = self.dxPreviewPreferences;
    if (![snapshot[kColorEnabledkey] boolValue]) return nil;
    id enabled = snapshot[kShortcutsBackgroundTintEnabled];
    if (enabled && ![enabled boolValue]) return nil;
    return DXColorFromHex(snapshot[@"shortcutsbackgroundtint"], @"#5B5B5B");
}

- (UIColor *)dxButtonTintColor {
    if (!self.dxPreviewMode) return currentTintColor;
    NSDictionary *snapshot = self.dxPreviewPreferences;
    return [snapshot[kShortcutsTintEnabled] boolValue]
        ? DXColorFromHex(snapshot[@"shortcutstint"], @"#ff0000")
        : UIColor.secondaryLabelColor;
}

- (void)configurePreviewWithPreferences:(NSDictionary *)preferences {
    if (!self.dxPreviewMode || ![preferences isKindOfClass:[NSDictionary class]]) return;
    self.dxPreviewPreferences = preferences;
    [self reloadShortcutConfiguration];
    [self.collectionViewLayout invalidateLayout];
    [self reloadData];
}

// 多行模式最多两行；超量旧配置由数据源先裁到当前两行容量。
- (NSInteger)multiRowVisibleItemCount {
    NSInteger items = ((NSArray *)_shortcuts[kbuttonsImages12]).count;
    NSInteger capacity = MIN(maxMultiRowButtons, MAX(1, self.buttonsPerRow) * maxMultiRowRows);
    return MIN(items, capacity);
}

// 逻辑行数与布局共用：ceil(可见按钮数 / 每行个数)，范围 1...2。
- (NSInteger)multiRowCountOfRows {
    NSInteger columns = MAX(1, self.buttonsPerRow);
    NSInteger items = [self multiRowVisibleItemCount];
    if (items <= 0) return 1;
    return MIN(maxMultiRowRows, (NSInteger)ceil((double)items / (double)columns));
}

- (CGFloat)preferredToolbarHeight {
    if (![self.configuration isEqualToString:@"top"]) return 0.0;
    NSInteger rows = [self multiRowCountOfRows];
    return 8.0 + rows * self.buttonHeight + (rows - 1) * self.rowSpacing
         + self.bottomSpacing;
}

// 顶部始终使用同一套多行布局，设置页预览也经过这个入口。
- (void)dxApplyLayoutForConfiguration {
    if (![self.configuration isEqualToString:@"top"]) return;
    if (![self.collectionViewLayout isKindOfClass:[DXMultiRowTopLayout class]]) {
        [self setCollectionViewLayout:[[DXMultiRowTopLayout alloc] init] animated:NO];
    }
}

// Buttons get visible chrome (per-button spacing, corner radius, spacing-aware
// insets) when either the shared background tint or this toolbar's border is on.
- (BOOL)buttonChromeActive {
    return [self dxButtonBackgroundTintColor] != nil || self.borderEnabled;
}

- (instancetype)initWithConfiguration:(NSString *)configuration{
    return [self initWithConfiguration:configuration preview:NO];
}

- (instancetype)initWithConfiguration:(NSString *)configuration preview:(BOOL)preview {

    // Both toolbars get the non-flipping flow layout: the dock toolbar joins
    // the same rebuilt keyboard hierarchy as the top accessory, so an unpinned
    // direction re-resolution there mirrors its items too.
    UICollectionViewFlowLayout *flowLayout = [[DXTopShortcutFlowLayout alloc] init];
    flowLayout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    flowLayout.minimumLineSpacing = 0;


    if (self = [super initWithFrame:CGRectZero collectionViewLayout:flowLayout]) {
        // Keep the configured array order stable before and after the view is
        // attached to the keyboard's accessory hierarchy — for both toolbars:
        // the keyboard's private hierarchy can temporarily resolve a different
        // semantic direction, and flow layout answers that by mirroring item
        // positions (the reversed-first-frame flash).
        self.semanticContentAttribute = UISemanticContentAttributeForceLeftToRight;
        self.configuration = configuration ?: @"bottom";
        self.dxPreviewMode = preview;
        if (preview) self.dxPreviewPreferences = [DXPrefsManager sharedInstance].prefs;
        self.shortcutsGenerator = [DXShortcutsGenerator sharedInstance];
        // Build the data source exactly once, directly from the complete
        // preference snapshot.  There is no default/cache view that is later
        // covered by a second user-configured view.
        [self reloadShortcutConfiguration];
        flowLayout.minimumInteritemSpacing = [self buttonChromeActive] ? self.buttonSpacing : 0;
        
        self.hapticType = 1;
        self.refreshView = YES;
        
        self.isWordSender = NO;
        self.moveCursorWithSelect = NO;
        
        
        self.backgroundColor = [UIColor clearColor];
        self.delegate = self;
        self.dataSource = self;
        self.showsVerticalScrollIndicator = NO;
        self.showsHorizontalScrollIndicator = NO;
        self.pagingEnabled = NO;
        self.scrollEnabled = NO;
        [self registerClass:NSClassFromString(@"DXCell") forCellWithReuseIdentifier:@"kMUBXCellID"];
        // A page preview never joins the live keyboard/panel lifecycle or routes actions.
        if (preview) {
            self.userInteractionEnabled = NO;
            return self;
        }
        DXToolbarHorizontalGesture *horizontal = [[DXToolbarHorizontalGesture alloc] initWithTarget:self action:@selector(toolbarHorizontalEnded:)];
        horizontal.cancelsTouchesInView = YES;
        horizontal.delaysTouchesBegan = NO;
        [self addGestureRecognizer:horizontal];
        [[DXKeyboardPanel sharedInstance] registerToolbar:self];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self keyboardRotated:nil];
        });
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(mubXLayoutChanged:) name:@"mubXLayoutChanged" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardRotated:) name:UIDeviceOrientationDidChangeNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHideForSubActionPanel:) name:UIKeyboardWillHideNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHideForSubActionPanel:) name:UIApplicationWillResignActiveNotification object:nil];
        
    }
    
    //if (!prefs[@"prevState"]){
    
    /*
     //}
     //dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
     if (@available(iOS 11.0, *)){
     [[DXPrefsManager sharedInstance] setValue:[NSKeyedArchiver archivedDataWithRootObject:self requiringSecureCoding:YES error:nil] forKey:@"prevState" fromSandbox:[DXPrefsManager isRunningInSandbox]];
     }
     //});
     */
    return self;
}


- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.dxPreviewMode) return;
    if (!self.window) {
        [self dismissSubActionPanelAnimated:NO completion:nil];
        [[DXKeyboardPanel sharedInstance] toolbarDetached:self];
    } else [[DXKeyboardPanel sharedInstance] registerToolbar:self];
}

- (void)dealloc {
    UIWindow *panelWindow = self.subActionPanelOverlay.window;
    [self.subActionPanelOverlay removeFromSuperview];
    if (panelWindow == DXSubActionPanelFloatingHostWindow &&
        ![panelWindow viewWithTag:DXSubActionPanelOverlayTag]) {
        panelWindow.hidden = YES;
        DXSubActionPanelFloatingHostWindow = nil;
    }
    if (DXActiveSubActionPanelOwner == self) DXActiveSubActionPanelOwner = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"mubXLayoutChanged" object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIDeviceOrientationDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIKeyboardWillHideNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillResignActiveNotification object:nil];
    //[[NSNotificationCenter defaultCenter] removeObserver:self name:UITextFieldTextDidBeginEditingNotification object:nil];
    
}

-(UITextRange *)selectedWordTextRangeWithDelegate:(id<UITextInput>)delegate{
    BOOL hasRightText = [delegate.tokenizer isPosition:delegate.selectedTextRange.start withinTextUnit:UITextGranularityWord inDirection:UITextLayoutDirectionRight];
    UITextStorageDirection direction = hasRightText ? UITextStorageDirectionForward : UITextStorageDirectionBackward;
    UITextRange *range = [delegate.tokenizer rangeEnclosingPosition:delegate.selectedTextRange.start
                                                    withGranularity:UITextGranularityWord
                                                        inDirection:direction];
    if (!range) {
        UITextPosition *p = [delegate.tokenizer positionFromPosition:delegate.selectedTextRange.start toBoundary:UITextGranularityWord inDirection:UITextStorageDirectionBackward];
        range = [delegate.tokenizer rangeEnclosingPosition:p withGranularity:UITextGranularityWord inDirection:UITextStorageDirectionBackward];
    }
    return range;
}

-(UITextRange *)selectedWordTextRangeWithDelegate:(id<UITextInput>)delegate direction:(UITextStorageDirection)direction{
    UITextRange *range = [delegate.tokenizer rangeEnclosingPosition:delegate.selectedTextRange.start
                                                    withGranularity:UITextGranularityWord
                                                        inDirection:direction];
    if (!range) {
        if (direction == UITextStorageDirectionBackward) {
            UITextPosition *p = [delegate.tokenizer positionFromPosition:delegate.selectedTextRange.start toBoundary:UITextGranularityWord inDirection:UITextStorageDirectionBackward];
            if (!p)
                p = [delegate.tokenizer positionFromPosition:delegate.selectedTextRange.start toBoundary:UITextGranularityLine inDirection:UITextLayoutDirectionUp];
            range = [delegate.tokenizer rangeEnclosingPosition:p withGranularity:UITextGranularityWord inDirection:UITextStorageDirectionBackward];
        } else {
            UITextPosition *p = [delegate.tokenizer positionFromPosition:delegate.selectedTextRange.start toBoundary:UITextGranularityWord inDirection:UITextStorageDirectionForward];
            if (!p)
                p = [delegate.tokenizer positionFromPosition:delegate.selectedTextRange.end toBoundary:UITextGranularityLine inDirection:UITextLayoutDirectionDown];
            range = [delegate.tokenizer rangeEnclosingPosition:p withGranularity:UITextGranularityWord inDirection:UITextStorageDirectionForward];
        }
    }
    return range;
}

-(void)moveCursorVerticalWithDelegate:(id<UITextInput>)delegate direction:(UITextLayoutDirection)direction{
    UITextPosition *position = [delegate positionFromPosition:delegate.selectedTextRange.start inDirection:direction offset:1];
    if (!position) return;
    UITextRange *range = [delegate textRangeFromPosition:position toPosition:position];
    delegate.selectedTextRange = range;
    //RevealSelection(delegate);
}

-(UITextRange *)autoDirectionWordSelectedTextRangeWithDelegate:(id<UITextInput> )delegate{
    BOOL hasRightText = [delegate.tokenizer isPosition:delegate.selectedTextRange.start withinTextUnit:UITextGranularityWord inDirection:UITextLayoutDirectionRight];
    UITextStorageDirection direction = hasRightText ? UITextStorageDirectionForward : UITextStorageDirectionBackward;
    return [self selectedWordTextRangeWithDelegate:delegate direction:direction];
}


-(UITextRange *)singleWordTextRangeWithDelegate:(id<UITextInput>)delegate direction:(UITextStorageDirection)direction{
    UITextRange *range = [self selectedWordTextRangeWithDelegate:delegate direction:direction];
    if (direction == UITextStorageDirectionForward)
        return [delegate textRangeFromPosition:range.end toPosition:range.end];
    else
        return [delegate textRangeFromPosition:range.start toPosition:range.start];
}

-(UITextRange *)lineExtremityTextRangeWithDelegate:(id<UITextInput>)delegate direction:(UITextLayoutDirection)direction{
    id<UITextInputTokenizer> tokenizer = delegate.tokenizer;
    UITextPosition *lineEdgePosition = [tokenizer positionFromPosition:delegate.selectedTextRange.end toBoundary:UITextGranularityLine inDirection:direction];
    // for until iOS 6 component.
    if ([lineEdgePosition isMemberOfClass:objc_getClass("UITextPositionImpl")])
        return [delegate textRangeFromPosition:lineEdgePosition toPosition:lineEdgePosition];
    // for iOS 7 buggy _UITextKitTextPosition workaround.
    for (int i=1; i<1000; i++) {
        lineEdgePosition = [delegate positionFromPosition:delegate.selectedTextRange.start inDirection:direction offset:i];
        NSComparisonResult result = [delegate comparePosition:lineEdgePosition
                                                   toPosition:(direction == UITextLayoutDirectionLeft) ? delegate.beginningOfDocument : delegate.endOfDocument];
        if (!lineEdgePosition || result == NSOrderedSame)
            return [delegate textRangeFromPosition:lineEdgePosition toPosition:lineEdgePosition];
        UITextRange *range = [delegate textRangeFromPosition:delegate.selectedTextRange.start toPosition:lineEdgePosition];
        NSString *text = [delegate textInRange:range];
        if ([text hasPrefix:@"\n"] || [text hasSuffix:@"\n"]) {
            lineEdgePosition = [delegate positionFromPosition:delegate.selectedTextRange.start inDirection:direction offset:i-1];
            return [delegate textRangeFromPosition:lineEdgePosition toPosition:lineEdgePosition];
        }
    }
    return nil;
}

-(void)moveCursorSingleWordWithDelegate:(id <UITextInput, UITextInputTokenizer>)delegate direction:(UITextStorageDirection)direction{
    if (delegate) {
        BOOL isRTL  = [self isRTLForDelegate:delegate];
        if (isRTL){
            if (direction == UITextStorageDirectionForward){
                direction = UITextStorageDirectionBackward;
            }else{
                direction = UITextStorageDirectionForward;
            }
        }
        UITextRange *textRange = [self singleWordTextRangeWithDelegate:delegate direction:direction];
        if (!textRange) return;
        [delegate setSelectedTextRange:textRange];
    }
}

-(void)moveCursorToLineExtremityWithDelegate:(id <UITextInput, UITextInputTokenizer>)delegate direction:(UITextLayoutDirection)direction{
    if (delegate) {
        BOOL isRTL  = [self isRTLForDelegate:delegate];
        if (isRTL){
            if (direction == UITextLayoutDirectionLeft){
                direction = UITextLayoutDirectionRight;
            }else{
                direction = UITextLayoutDirectionLeft;
            }
        }
        UITextRange *textRange = [self lineExtremityTextRangeWithDelegate:delegate direction:direction];
        if (!textRange) return;
        [delegate setSelectedTextRange:textRange];
    }
}

-(BOOL)isRTLForDelegate:(UIResponder *)delegate {
    UIKeyboardExtensionInputMode *inputMode = delegate.textInputMode;
    return [inputMode isDefaultRightToLeft];
    
}

- (NSInteger)currentCursorPosition:(id <UITextInput, UITextInputTokenizer>)delegate{
    UITextRange *selectedRange = delegate.selectedTextRange;
    UITextPosition *textPosition = selectedRange.start;
    return [delegate offsetFromPosition:delegate.beginningOfDocument toPosition:textPosition];
}


-(void)moveCursorWithDelegate:(id <UITextInput, UITextInputTokenizer>)delegate offset:(int)offset{
    if (delegate) {
        BOOL isRTL  = [self isRTLForDelegate:delegate];
        UITextPosition *textPosition;
        if (isRTL){
            textPosition = [delegate positionFromPosition:delegate.beginningOfDocument offset:([self currentCursorPosition:delegate]-offset)];
        }else{
            textPosition = [delegate positionFromPosition:delegate.beginningOfDocument offset:([self currentCursorPosition:delegate]+offset)];
        }
        
        [delegate setSelectedTextRange:[delegate textRangeFromPosition:textPosition toPosition:textPosition]];
    }
}

-(BOOL)reloadShortcutConfiguration{
    DXPrefsManager *manager = [DXPrefsManager sharedInstance];
    NSDictionary *freshPrefs = self.dxPreviewMode ? self.dxPreviewPreferences
        : (manager.preferencesAvailable ? manager.prefs : nil);
    NSDictionary *previousPrefs = self.dxAppliedPrefsSnapshot;
    self.shortcutConfigurationAvailable = [freshPrefs isKindOfClass:[NSDictionary class]];
    NSDictionary *currentPrefs = self.shortcutConfigurationAvailable ? freshPrefs : @{};
    if (!self.dxPreviewMode) prefs = [currentPrefs mutableCopy];
    NSMutableArray *defaultImages12 = [[self.shortcutsGenerator imageNameArrayForiOS:0] mutableCopy];
    NSMutableArray *defaultImages13 = [[self.shortcutsGenerator imageNameArrayForiOS:1] mutableCopy];
    NSMutableArray *defaultSelectors = [[self.shortcutsGenerator selectorNames] mutableCopy];

    NSMutableArray *images12 = [NSMutableArray array];
    NSMutableArray *images13 = [NSMutableArray array];
    NSMutableArray *selectors = [NSMutableArray array];
    NSString *shortcutsKey = [self scopedPreferenceKey:kShortcutskey];
    id configuredValue = currentPrefs[shortcutsKey];
    NSArray *configuredShortcuts = [configuredValue isKindOfClass:[NSArray class]] ? configuredValue : nil;

    // Top and bottom shortcuts are fully decoupled.  When a scoped key has no
    // persisted value (e.g. user never opened "顶部设置"), the else-branch
    // below uses the default set (first N actions from DXShortcutsGenerator).
    // The bottom configuration is never inherited by the top toolbar.

    if (self.shortcutConfigurationAvailable && configuredShortcuts.count > 0 &&
        [configuredShortcuts[0] isKindOfClass:[NSArray class]]) {
        NSMutableDictionary *customNames = [[NSMutableDictionary alloc] init];
        NSInteger enabledButtons = 0;
        NSInteger capacity = DXToolbarCapacityForPreferences(currentPrefs, self.configuration);
        for (NSDictionary *item in configuredShortcuts[0]) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSString *selector = item[@"selector"];
            // Draft buttons (saved without a tap action) render inert on the
            // toolbar; everything else unknown stays filtered out.
            if (!DXIsDraftActionSelector(selector) && DXIsHiddenShortcutSelector(selector)) continue;
            // Buttons switched off on the manage page stay stored but never render.
            if ([item[@"disabled"] boolValue]) continue;
            // Also clamp legacy settings before Settings has persisted disabled flags.
            if (enabledButtons >= capacity) continue;
            if (item[@"images12"] && item[@"images13"] && selector) {
                [self integrateShortcutItem:item intoImages12:images12 images13:images13 selectors:selectors names:customNames];
                enabledButtons++;
            }
        }
        self.customNames = customNames;
    } else if (self.shortcutConfigurationAvailable && configuredValue == nil) {
        NSUInteger count = MIN((NSUInteger)maxEnabledBottomButtons,
                               MIN(defaultImages12.count,
                                   MIN(defaultImages13.count, defaultSelectors.count)));
        for (NSUInteger index = 0; index < count; index++) {
            [images12 addObject:defaultImages12[index]];
            [images13 addObject:defaultImages13[index]];
            [selectors addObject:defaultSelectors[index]];
        }
        self.customNames = @{};
    } else {
        // A missing snapshot or malformed persisted shortcut value is not a
        // request for the six defaults.  Keep the toolbar empty until a valid
        // snapshot arrives.
        self.customNames = @{};
    }

    self.shortcuts = @[images12, images13, selectors];
    [self reloadButtonChrome];
    [self dxApplyLayoutForConfiguration];
    UICollectionViewFlowLayout *activeFlowLayout = (UICollectionViewFlowLayout *)self.collectionViewLayout;
    if ([activeFlowLayout isKindOfClass:[UICollectionViewFlowLayout class]]) {
        activeFlowLayout.minimumInteritemSpacing = [self buttonChromeActive] ? self.buttonSpacing : 0;
    }
    self.pagingEnabled = NO;
    self.scrollEnabled = NO;

    // 键盘每次弹出都会走带重载的路径，而偏好快照其实没变。无谓的整表
    // reloadData 会让复用 cell 跨位置换位，键盘装配期多次重布局里闪出一帧
    // 内容错位（顺序闪变根因）。快照对比一个判据覆盖全部可见输入（按钮数据、
    // 样式、手势绑定、色调），粒度等同旧的每次重载；真正的偏好变更必然返回
    // YES，调用方照常 invalidate + reloadData。
    self.dxAppliedPrefsSnapshot = freshPrefs;
    return !(freshPrefs == previousPrefs || [freshPrefs isEqual:previousPrefs]);
}


-(void)mubXLayoutChanged:(NSNotification*)notification{
    //self.hidden = isLandscape||isDictating?YES:NO;
    //[self reloadData];
    if (toggledOn){
        if (self.refreshView){
            [UIView performWithoutAnimation:^{
                // reloadData inside performBatchUpdates mixes a full reload with
                // batch semantics (undefined; cells can end up attributed to
                // stale index paths). Reload plainly; the empty batch only
                // forces the layout pass.
                [self reloadData];
                [self performBatchUpdates:^{} completion:^(BOOL finished) {}];
            }];
        }
        
        /*
         
         NSDictionary* userInfo = notification.userInfo;
         @try {
         if (self.refreshView)
         [UIView performWithoutAnimation:^{
         if ([userInfo[@"fullreload"] boolValue]){
         //[self reloadData];
         [self performBatchUpdates:^{
         [self reloadData];
         } completion:^(BOOL finished) {}];
         
         }else{
         //[self reloadData];
         [self performBatchUpdates:^{
         [self reloadData];
         } completion:^(BOOL finished) {}];
         
         //[self reloadItemsAtIndexPaths:[self indexPathsForVisibleItems]];
         
         }
         }];
         } @catch (NSException *exception) {
         if (self.refreshView)
         [UIView performWithoutAnimation:^{
         //[self reloadData];
         [self performBatchUpdates:^{
         [self reloadData];
         } completion:^(BOOL finished) {}];
         
         }];
         } @finally {
         
         }
         */
    }
    //[self reloadItemsAtIndexPaths:[self indexPathsForVisibleItems]] ;
}

- (void)keyboardRotated:(NSNotification *)notification {
    if (notification) [self dismissSubActionPanelAnimated:NO completion:nil];
    
    if (toggledOn){
        UIInterfaceOrientation orientation = DXCurrentInterfaceOrientation();
        isLandscape = UIInterfaceOrientationIsLandscape(orientation);
        if (self.refreshView){
            [UIView performWithoutAnimation:^{
                // reloadData inside performBatchUpdates mixes a full reload with
                // batch semantics (undefined; cells can end up attributed to
                // stale index paths). Reload plainly; the empty batch only
                // forces the layout pass.
                [self reloadData];
                [self performBatchUpdates:^{} completion:^(BOOL finished) {}];
            }];
        }
    }
    
    
    
    /*
     //self.hidden = isLandscape||isDictating ? YES : NO;
     @try {
     if (self.refreshView)
     [UIView performWithoutAnimation:^{
     //[self reloadItemsAtIndexPaths:[self indexPathsForVisibleItems]];
     [self performBatchUpdates:^{
     [self reloadData];
     } completion:^(BOOL finished) {}];
     
     }];
     } @catch (NSException *exception) {
     if (self.refreshView)
     [UIView performWithoutAnimation:^{
     //[self reloadData];
     [self performBatchUpdates:^{
     [self reloadData];
     } completion:^(BOOL finished) {}];
     
     }];
     } @finally {
     
     }
     }
     */
}

-(void)keyboardWillHideForSubActionPanel:(NSNotification *)notification {
    (void)notification;
    [self dismissSubActionPanelAnimated:NO completion:nil];
}


-(void)triggerImpactAndAnimationWithButton:(UIButton *)sender{
    //haptic, 0=none, 1=once, 2==success(twice)
    if ( preferencesBool(kEnabledHaptickey,YES) && self.hapticType != 0){

        if (self.hapticType == 1){
            [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
        }else{
            [[[UINotificationFeedbackGenerator alloc] init] notificationOccurred:UINotificationFeedbackTypeSuccess];
            self.hapticType = 1;
        }
    }
}

-(void)beginUpdateDelegate{
    Class implClass = objc_getClass("UIKeyboardImpl");
    kbImpl = [implClass respondsToSelector:@selector(activeInstance)] ? [implClass activeInstance] : nil;
    delegate = DXKeyboardInputDelegate(kbImpl);
}

-(void)beginImpactAnimationAndUpdateDelegateWithSender:(UIButton *)sender{
    [self triggerImpactAndAnimationWithButton:sender];
    [self beginUpdateDelegate];
}

#pragma mark actions
-(void)selectAllAction:(UIButton*)sender{
    [self beginImpactAnimationAndUpdateDelegateWithSender:sender];
    
    if ([delegate respondsToSelector:@selector(selectAll:)]) {
        [delegate selectAll:nil];
    }else if ([delegate respondsToSelector:@selector(selectAll)]) {
        [delegate selectAll];
        
        [kbImpl clearTransientState];
        [kbImpl clearAnimations];
        [kbImpl setCaretBlinks:YES];
    }
}

-(void)selectLineAction:(UIButton*)sender{
    [self beginImpactAnimationAndUpdateDelegateWithSender:sender];
    
    [delegate _moveToStartOfLine:NO withHistory:nil];
    [delegate _moveToEndOfLine:YES withHistory:nil];
}

-(void)selectParagraphAction:(UIButton*)sender{
    [self beginImpactAnimationAndUpdateDelegateWithSender:sender];
    
    [delegate _moveToStartOfParagraph:NO withHistory:nil];
    [delegate _moveToEndOfParagraph:YES withHistory:nil];;
}

-(void)selectSentenceAction:(UIButton*)sender{
    [self beginImpactAnimationAndUpdateDelegateWithSender:sender];
    UIResponder <UITextInput> *tempDelegate = (UIResponder <UITextInput, UITextInputTokenizer> *)delegate;
    
    UITextPosition *startPositionTemp = tempDelegate.selectedTextRange.start;
    UITextPosition *startPositionSentence = ((UITextRange * )[tempDelegate _rangeOfSentenceEnclosingPosition:startPositionTemp]).start;
    UITextPosition *endPositionSentence = ((UITextRange * )[tempDelegate _rangeOfSentenceEnclosingPosition:startPositionTemp]).end;
    
    BOOL isWKContentView = [tempDelegate isKindOfClass:objc_getClass("WKContentView")];
    
    if (isWKContentView){
        
    }else{
        UITextRange *textRange = [tempDelegate textRangeFromPosition:startPositionSentence toPosition:endPositionSentence];
        [tempDelegate setSelectedTextRange:textRange];
    }
}


-(void)copyAction:(UIButton*)sender{
    [self beginImpactAnimationAndUpdateDelegateWithSender:sender];

    if (![delegate respondsToSelector:@selector(selectedTextRange)]) {
        return;
    }

    // With no selection, copy the whole content instead of doing nothing.
    BOOL hadSelection = [[delegate textInRange:[delegate selectedTextRange]] length] > 0;
    if (!hadSelection) {
        if ([delegate respondsToSelector:@selector(selectAll:)]) {
            [delegate selectAll:nil];
        }else if ([delegate respondsToSelector:@selector(selectAll)]){
            [delegate selectAll];
        }
    }

    if ([delegate respondsToSelector:@selector(copy:)]) {
        [delegate copy:nil]; //UIResponderStandardEditActions.h
    }else{
        UITextRange *range = [delegate selectedTextRange];
        UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];

        [pasteboard setString:[delegate textInRange:range]];
    }

    if (!hadSelection) {
        // Do not linger in the select-all state: collapse the caret to the end
        // of the copied range, where a regular copy leaves it.
        UITextRange *range = [delegate selectedTextRange];
        if (range) {
            [delegate setSelectedTextRange:[delegate textRangeFromPosition:range.end toPosition:range.end]];
        }
        [kbImpl clearTransientState];
        [kbImpl clearAnimations];
        [kbImpl setCaretBlinks:YES];
    }
}

-(BOOL)isValidURL:(NSString *)urlString{
    NSURL *url = [NSURL URLWithString:urlString];
    BOOL isUrl = NO;
    if (url && url.scheme && url.host) isUrl = YES;
    return isUrl;
}

-(void)pasteAction:(UIButton*)sender{
    [self beginImpactAnimationAndUpdateDelegateWithSender:sender];
    
    BOOL isUnifiedField = [delegate isKindOfClass:objc_getClass("UnifiedField")];
    int pasteAndGoType = preferencesInt(kPasteAndGoEnabledkey, 2);
    if (pasteAndGoType > 0 && isSafari && isUnifiedField){
        if (pasteAndGoType == 1 && [self isValidURL:[[UIPasteboard generalPasteboard] string]]){
            if ([((UnifiedField *)delegate).delegate respondsToSelector:@selector(unifiedFieldShouldPasteAndNavigate:)]){
                [((UnifiedField *)delegate).delegate unifiedFieldShouldPasteAndNavigate:nil];
                return;
            }
        }else if (pasteAndGoType == 2){
            if ([((UnifiedField *)delegate).delegate respondsToSelector:@selector(unifiedFieldShouldPasteAndNavigate:)]){
                [((UnifiedField *)delegate).delegate unifiedFieldShouldPasteAndNavigate:nil];
                return;
            }
        }
    }
    
    if ([delegate respondsToSelector:@selector(paste:)]) {
        [delegate paste:nil]; //UIResponderStandardEditActions.h
    }else{
        if ([delegate respondsToSelector:@selector(selectedTextRange)]) {
            UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
            
            NSString *copiedtext = [pasteboard string];
            
            if (copiedtext) {
                [kbImpl insertText:copiedtext];
            }
            
            [kbImpl clearTransientState];
            [kbImpl clearAnimations];
            [kbImpl setCaretBlinks:YES];
            
        }
    }
}

-(void)cutAction:(UIButton*)sender{
    [self beginImpactAnimationAndUpdateDelegateWithSender:sender];

    // With no selection, cut the whole content instead of doing nothing.
    // Cutting collapses the selection back to a caret by itself.
    if ([delegate respondsToSelector:@selector(selectedTextRange)] &&
        [[delegate textInRange:[delegate selectedTextRange]] length] == 0) {
        if ([delegate respondsToSelector:@selector(selectAll:)]) {
            [delegate selectAll:nil];
        }else if ([delegate respondsToSelector:@selector(selectAll)]){
            [delegate selectAll];
        }
    }

    if ([delegate respondsToSelector:@selector(cut:)]) {
        [delegate cut:nil]; //UIResponderStandardEditActions.h
    }else if ([delegate respondsToSelector:@selector(selectedTextRange)]) {
        UITextRange *range = [delegate selectedTextRange];
        NSString *textRange = [delegate textInRange:range];
        UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];

        [pasteboard setString:textRange];

        [kbImpl deleteFromInput];
        [kbImpl clearTransientState];
        [kbImpl clearAnimations];
        [kbImpl setCaretBlinks:YES];
    }
}

-(void)undoAction:(UIButton*)sender{
    [self beginImpactAnimationAndUpdateDelegateWithSender:sender];
    if ([[delegate undoManager] canUndo]) {
        [[delegate undoManager] undo];
        
        [kbImpl clearTransientState];
        [kbImpl clearAnimations];
        [kbImpl setCaretBlinks:YES];
    }
}

-(void)redoAction:(UIButton*)sender{
    [self beginImpactAnimationAndUpdateDelegateWithSender:sender];
    if ([[delegate undoManager] canRedo]) {
        [[delegate undoManager] redo];
        
        [kbImpl clearTransientState];
        [kbImpl clearAnimations];
        [kbImpl setCaretBlinks:YES];
    }
}

-(void)selectAction:(UIButton*)sender{
    [self beginImpactAnimationAndUpdateDelegateWithSender:sender];
    
    if ([delegate respondsToSelector:@selector(select:)]) {
        [delegate select:nil]; //UIResponderStandardEditActions.h
    }else{
        if (![kbImpl isUsingDictationLayout]){
            NSString *selectedString = [delegate textInRange:[delegate selectedTextRange]];
            if (!selectedString.length) {
                UITextRange *textRange = [self selectedWordTextRangeWithDelegate:delegate];
                
                if (!textRange)
                    return;
                UIResponder <UITextInput> *tempDelegate = (UIResponder <UITextInput> *)delegate;
                if (![((UITextField *)tempDelegate).text isEqualToString:@"\uFFFC"]){
                    tempDelegate.selectedTextRange = textRange;
                }
                [kbImpl clearTransientState];
                [kbImpl clearAnimations];
                [kbImpl setCaretBlinks:YES];
            }
        }
    }
}

-(void)beginningAction:(UIButton*)sender{
    [self beginImpactAnimationAndUpdateDelegateWithSender:sender];
    UIResponder <UITextInput> *tempDelegate = (UIResponder <UITextInput> *)delegate;
    
    BOOL isWKContentView = [tempDelegate isKindOfClass:objc_getClass("WKContentView")];
    if (isWKContentView){
        [(WKContentView *)tempDelegate executeEditCommandWithCallback:@"moveToBeginningOfDocument"];
    }else{
        tempDelegate.selectedTextRange = [tempDelegate textRangeFromPosition:tempDelegate.beginningOfDocument toPosition:tempDelegate.beginningOfDocument];
    }
    [kbImpl clearTransientState];
    [kbImpl clearAnimations];
    [kbImpl setCaretBlinks:YES];
}

-(void)endingAction:(UIButton*)sender{
    [self beginImpactAnimationAndUpdateDelegateWithSender:sender];
    UIResponder <UITextInput> *tempDelegate = (UIResponder <UITextInput> *)delegate;
    
    BOOL isWKContentView = [tempDelegate isKindOfClass:objc_getClass("WKContentView")];
    if (isWKContentView){
        [(WKContentView *)tempDelegate executeEditCommandWithCallback:@"moveToEndOfDocument"];
    }else{
        tempDelegate.selectedTextRange = [tempDelegate textRangeFromPosition:tempDelegate.endOfDocument toPosition:tempDelegate.endOfDocument];
    }
    
    [kbImpl clearTransientState];
    [kbImpl clearAnimations];
    [kbImpl setCaretBlinks:YES];
}




-(void)deleteAction:(UIButton*)sender{
    [self beginImpactAnimationAndUpdateDelegateWithSender:sender];
    [kbImpl deleteBackward];
    [kbImpl clearTransientState];
    [kbImpl clearAnimations];
    [kbImpl setCaretBlinks:YES];
}

-(void)deleteForwardAction:(UIButton*)sender{
    [self beginImpactAnimationAndUpdateDelegateWithSender:sender];
    NSString *selectedString = [delegate textInRange:[delegate selectedTextRange]];
    BOOL smartDelete = preferencesBool(kEnabledSmartDeleteForwardkey, NO);
    if (!selectedString.length) {
        UITextRange *textRange = [self selectedWordTextRangeWithDelegate:delegate direction:UITextStorageDirectionForward];
        
        if (!textRange) return;
        
        UIResponder <UITextInput> *tempDelegate = (UIResponder <UITextInput> *)delegate;
        
        tempDelegate.selectedTextRange = textRange;
        //[kbImpl deleteFromInput];
        [kbImpl deleteFromInput];
        if (smartDelete) [kbImpl insertText:@" "];
        //[tempDelegate  _moveRight:NO withHistory:nil];
        
        [kbImpl clearTransientState];
        [kbImpl clearAnimations];
        [kbImpl setCaretBlinks:YES];
        
    }else{
        [kbImpl deleteForwardAndNotify:YES];
        if (smartDelete) [kbImpl insertText:@" "];
        [kbImpl clearTransientState];
        [kbImpl clearAnimations];
        [kbImpl setCaretBlinks:YES];
    }
    
}

// 删除光标前一个词：tokenizer 取光标前方的词范围后走系统删除路径；取不到
// 词边界（行首/空输入）时退化为删除一个字符。光标紧邻标点/符号时只删一个
// 字符：tokenizer 的 backward 词范围会整段跳过符号串直接返回前面的词（如
// "hello-" 会取到 "hello"），必须先看光标前一个字符再取词，否则符号永远轮不到删。
-(void)deleteWordAction:(UIButton*)sender{
    [self beginImpactAnimationAndUpdateDelegateWithSender:sender];
    BOOL deleted = NO;
    if ([delegate respondsToSelector:@selector(selectedTextRange)]) {
        UIResponder <UITextInput> *tempDelegate = (UIResponder <UITextInput> *)delegate;
        UITextPosition *caret = tempDelegate.selectedTextRange.start;
        UITextPosition *prevStart = caret ? [tempDelegate positionFromPosition:caret
                                                                  inDirection:UITextLayoutDirectionLeft offset:1] : nil;
        NSString *prevChar = prevStart ? [tempDelegate textInRange:
            [tempDelegate textRangeFromPosition:prevStart toPosition:caret]] : nil;
        BOOL prevIsSymbol = prevChar.length > 0 &&
            ![[NSCharacterSet alphanumericCharacterSet]
                characterIsMember:[prevChar characterAtIndex:prevChar.length - 1]] &&
            ![[NSCharacterSet whitespaceAndNewlineCharacterSet]
                characterIsMember:[prevChar characterAtIndex:prevChar.length - 1]];
        if (prevIsSymbol) {
            [kbImpl deleteBackward];
            deleted = YES;
        }
        UITextRange *range = prevIsSymbol ? nil :
            [self selectedWordTextRangeWithDelegate:delegate direction:UITextStorageDirectionBackward];
        if (range && range.start && range.end && [[tempDelegate textInRange:range] length] > 0) {
            UITextPosition *lastCharStart = [tempDelegate positionFromPosition:range.start
                                                                   inDirection:UITextLayoutDirectionRight offset:1];
            NSString *lastChar = lastCharStart ? [tempDelegate textInRange:
                [tempDelegate textRangeFromPosition:lastCharStart toPosition:range.end]] : nil;
            BOOL trailingIsSymbol = lastChar.length > 0 &&
                ![[NSCharacterSet alphanumericCharacterSet]
                    characterIsMember:[lastChar characterAtIndex:lastChar.length - 1]];
            if (trailingIsSymbol) {
                [kbImpl deleteBackward];
            } else {
                tempDelegate.selectedTextRange = range;
                [kbImpl deleteFromInput];
            }
            deleted = YES;
        }
    }
    if (!deleted) [kbImpl deleteBackward];
    [kbImpl clearTransientState];
    [kbImpl clearAnimations];
    [kbImpl setCaretBlinks:YES];
}

// Whole-document clear shared by the delete-all button and the AI seed
// hand-off: select the entire document directly instead of running the
// select-all action, and delete it within the same run-loop tick so no
// selection highlight or handles ever appear. No-op on an empty input.
-(void)clearHostInputText{
    if ([delegate respondsToSelector:@selector(selectedTextRange)]) {
        UIResponder <UITextInput> *tempDelegate = (UIResponder <UITextInput> *)delegate;
        UITextRange *wholeRange = [tempDelegate textRangeFromPosition:[tempDelegate beginningOfDocument]
                                                           toPosition:[tempDelegate endOfDocument]];
        if (wholeRange == nil || [[tempDelegate textInRange:wholeRange] length] == 0) {
            return;
        }
        tempDelegate.selectedTextRange = wholeRange;
    }else if ([delegate respondsToSelector:@selector(selectAll:)]) {
        [delegate selectAll:nil];
    }else if ([delegate respondsToSelector:@selector(selectAll)]){
        [delegate selectAll];
    }

    [kbImpl deleteFromInput];
    [kbImpl clearTransientState];
    [kbImpl clearAnimations];
    [kbImpl setCaretBlinks:YES];
}

-(void)deleteAllAction:(UIButton*)sender{
    self.hapticType = 2;
    [self beginImpactAnimationAndUpdateDelegateWithSender:sender];
    [self clearHostInputText];
}

-(void)dismissKeyboardAction:(UIButton*)sender{
    [self triggerImpactAndAnimationWithButton:sender];
    kbImpl = [objc_getClass("UIKeyboardImpl") activeInstance];
    [kbImpl dismissKeyboard];
}

// 截图按钮：ShellX 只注入 SpringBoard/assistivetouchd，键盘进程内其类不在内存，
// Darwin 通知 com.iosdump.screenshotshell/AssistiveScreenshot 是官方跨进程触发入口
// （SpringBoard 侧 CFNotificationCenterAddObserver，守卫检查 GlobalEnabled 后走系统截图路径）。
// 直接触发截图，保留当前键盘状态。
-(void)shellxScreenshotAction:(UIButton*)sender{
    [self triggerImpactAndAnimationWithButton:sender];
    notify_post("com.iosdump.screenshotshell/AssistiveScreenshot");
}

// PixPin's native area-capture notification is shared with the system action.
// Posting succeeds independently of PixPin's enabled/busy state; never retry.
-(void)pixpinScreenshotAction:(UIButton*)sender{
    if (!NSThread.isMainThread || !self.window || self.hidden ||
        ![DXShortcutsGenerator isPixPinScreenshotAvailable]) return;
    [self triggerImpactAndAnimationWithButton:sender];
    DXPostPixPinSystemAction(@"pixpin-area", DX_ROOT_PATH_NS(DXPixPinDylibPath));
}

// 剪贴板按钮：MUBX 已内置剪贴板历史（DXClipboardPanel，SpringBoard 监听 +
// cfprefsd 快照 + 面板进程内浮层），不再依赖 Kayoko。总开关 clipboardBOOL
// 关闭时回退到旧的 Kayoko 唤起通知（dev.traurige.kayoko.core.show），保证
// 装了 Kayoko 的老配置行为不变。
-(void)clipboardAction:(UIButton*)sender{
    [self triggerImpactAndAnimationWithButton:sender];

    BOOL clipEnabled = preferencesBool(kClipboardEnabledKey, YES);
    if (clipEnabled) {
        // 进程内浮层面板（宿主 app / SpringBoard 均可触发；面板弹窗前校验
        // 前台 scene 存在才显示，规避空白窗口）。
        [DXClipboardPanel present];
        return;
    }
    // 回退：Kayoko / KayokoX 官方唤起入口（未安装时通知无人接收，无害）。
    notify_post("dev.traurige.kayoko.core.show");
}

// 小把手按钮：PullOver X 在 SpringBoard 进程内常驻观察 external-wake 通知——
// 面板展开时收起，把手缩点时展开把手并唤出常驻竖栏，其余状态不动作（收端有
// externalWakeEnabled 开关与 1s 节流）。Darwin 通知系统级广播，键盘进程直发即达。
-(void)pulloverWakeAction:(UIButton*)sender{
    [self triggerImpactAndAnimationWithButton:sender];
    notify_post("com.mlgm.pulloverx.external-wake");
}

// AI 问答按钮，按承载能力分派（第一版 + ShellX 时代两套验证过的路径）：
// 系统键盘——MUBX 跑在宿主 app / SpringBoard 进程内（工具栏就长在 UIKeyboardImpl
// 上），面板第一版同款进程内承载，点按钮立即弹出，不依赖跨进程通道；
// 第三方键盘扩展——扩展进程的窗口逃不出键盘宿主区域，只能走 cfprefsd+Darwin
// 通道交 SpringBoard 弹出（种子：输入框全文 > 剪贴板文本 > 剪贴板图片；app
// 来源等回桌面再显示）。SB 端解析与桌面门控在 MUBX.xm。
-(void)aiChatAction:(UIButton*)sender{
    [self triggerImpactAndAnimationWithButton:sender];

    BOOL inProcess = [objc_getClass("UIKeyboardImpl") activeInstance] != nil;

    [self beginUpdateDelegate];
    NSString *seed = [self currentInputTextForCustomAction];
    if (seed.length > 20000) seed = [seed substringToIndex:20000];

    if (inProcess) {
        [DXAIPanel openFromKeyboardWithSeedText:seed];
        // 移动语义：输入框全文带入面板后即清空宿主输入框（面板必开，
        // clearHostInputText 空输入时为无害空操作）
        if (seed.length > 0) [self clearHostInputText];
        return;
    }

    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
    NSString *mode;
    if (seed.length > 0) {
        mode = @"text";
    } else if (pasteboard.string.length > 0) {
        seed = pasteboard.string;
        mode = @"text";
    } else if (pasteboard.hasImages) {
        mode = @"image";
    } else {
        mode = @"empty";
    }

    // 先收尾当前输入会话再投递（第一版顺序）：SB 端创建窗口后，宿主键盘若仍
    // 处于激活状态会与 SB 端窗口/触摸状态异步竞争。扩展进程内没有
    // UIKeyboardImpl，此调用为无害空操作。
    kbImpl = [objc_getClass("UIKeyboardImpl") activeInstance];
    [kbImpl dismissKeyboard];

    NSDictionary *request = @{@"format": @2,
                              @"requestID": [NSUUID UUID].UUIDString,
                              @"created": @([NSDate date].timeIntervalSince1970),
                              @"mode": mode,
                              @"origin": isSpringBoard ? @"sb" : @"app",
                              @"text": seed ?: @""};
    DXSetQuickActionSharedValue(request, MUBXAIChatRequestKey);
    notify_post(kAIChatRequestIdentifier.UTF8String);
}

-(void)moveCursorLeftAction:(UIButton*)sender{
    [self beginImpactAnimationAndUpdateDelegateWithSender:sender];
    
    BOOL isWKContentView = [delegate isKindOfClass:objc_getClass("WKContentView")];
    if (isWKContentView){
        BOOL isRTL  = [self isRTLForDelegate:delegate];
        if (isRTL){
            [(WKContentView *)delegate executeEditCommandWithCallback:@"moveRight"];
        }else{
            [(WKContentView *)delegate executeEditCommandWithCallback:@"moveLeft"];
        }
    }else{
        [self moveCursorWithDelegate:delegate offset:-1];
    }
}

-(void)moveCursorRightAction:(UIButton*)sender{
    [self beginImpactAnimationAndUpdateDelegateWithSender:sender];
    
    BOOL isWKContentView = [delegate isKindOfClass:objc_getClass("WKContentView")];
    if (isWKContentView){
        BOOL isRTL  = [self isRTLForDelegate:delegate];
        if (isRTL){
            [(WKContentView *)delegate executeEditCommandWithCallback:@"moveLeft"];
        }else{
            [(WKContentView *)delegate executeEditCommandWithCallback:@"moveRight"];
        }
    }else{
        [self moveCursorWithDelegate:delegate offset:1];
    }
}

-(void)moveCursorPreviousWordAction:(UIButton*)sender{
    if (sender || self.isWordSender){
        [self triggerImpactAndAnimationWithButton:sender];
    }
    [self beginUpdateDelegate];
    
    BOOL isWKContentView = [delegate isKindOfClass:objc_getClass("WKContentView")];
    BOOL isRTL  = [self isRTLForDelegate:delegate];
    if (isWKContentView){
        if (isRTL){
            [(WKContentView *)delegate _moveToEndOfWord:self.moveCursorWithSelect withHistory:nil];
        }else{
            [(WKContentView *)delegate _moveToStartOfWord:self.moveCursorWithSelect withHistory:nil];
        }
    }else{
        if ([delegate respondsToSelector:@selector(_moveToStartOfWord:withHistory:)]){
            //if (isRTL){
            //[delegate _moveToEndOfWord:NO withHistory:nil];
            //}else{
            [delegate _moveToStartOfWord:self.moveCursorWithSelect withHistory:nil];
            //}
        }else{
            [self moveCursorSingleWordWithDelegate:delegate direction:UITextStorageDirectionBackward];
        }
    }
    self.moveCursorWithSelect = NO;
    self.isWordSender = NO;
}

-(void)moveCursorNextWordAction:(UIButton*)sender{
    if (sender || self.isWordSender){
        [self triggerImpactAndAnimationWithButton:sender];
    }
    [self beginUpdateDelegate];
    
    BOOL isWKContentView = [delegate isKindOfClass:objc_getClass("WKContentView")];
    BOOL isRTL  = [self isRTLForDelegate:delegate];
    if (isWKContentView){
        if (isRTL){
            [(WKContentView *)delegate _moveToStartOfWord:self.moveCursorWithSelect withHistory:nil];
        }else{
            [(WKContentView *)delegate _moveToEndOfWord:self.moveCursorWithSelect withHistory:nil];
        }
    }else{
        if ([delegate respondsToSelector:@selector(_moveToEndOfWord:withHistory:)]){
            //if (isRTL){
            //[delegate _moveToStartOfWord:NO withHistory:nil];
            //}else{
            [delegate _moveToEndOfWord:self.moveCursorWithSelect withHistory:nil];
            //}
        }else{
            [self moveCursorSingleWordWithDelegate:delegate direction:UITextStorageDirectionForward];
        }
    }
    self.moveCursorWithSelect = NO;
    self.isWordSender = NO;
}

-(void)moveCursorStartOfLineAction:(UIButton*)sender{
    [self beginImpactAnimationAndUpdateDelegateWithSender:sender];
    UIResponder <UITextInput> *tempDelegate = (UIResponder <UITextInput> *)delegate;
    
    UITextPosition *startPositionTemp = tempDelegate.selectedTextRange.start;
    self.moveCursorWithSelect = NO;
    [self moveCursorPreviousWordAction:nil];
    UITextPosition *startPositionMovedTemp = tempDelegate.selectedTextRange.start;
    if (((UITextRange * )[delegate _rangeOfLineEnclosingPosition:startPositionMovedTemp]).start == ((UITextRange * )[delegate _rangeOfLineEnclosingPosition:startPositionTemp]).start){
        [delegate _moveToStartOfLine:NO withHistory:nil];
        
        //[self moveCursorPreviousWordAction:nil];
        
    }
    
    BOOL isWKContentView = [delegate isKindOfClass:objc_getClass("WKContentView")];
    BOOL isRTL  = [self isRTLForDelegate:delegate];
    
    if (isWKContentView){
        if (isRTL){
            [(WKContentView *)delegate _moveToEndOfLine:self.moveCursorWithSelect withHistory:nil];
        }else{
            [(WKContentView *)delegate _moveToStartOfLine:self.moveCursorWithSelect withHistory:nil];
        }
    }else{
        if ([delegate respondsToSelector:@selector(_moveToStartOfLine:withHistory:)]){
            //if (isRTL){
            //[delegate _moveToEndOfLine:NO withHistory:nil];
            //}else{
            [delegate _moveToStartOfLine:self.moveCursorWithSelect withHistory:nil];
            //}
        }else{
            [self moveCursorToLineExtremityWithDelegate:delegate direction:UITextLayoutDirectionLeft];
        }
    }
    self.moveCursorWithSelect = NO;
}

-(void)moveCursorEndOfLineAction:(UIButton*)sender{
    [self beginImpactAnimationAndUpdateDelegateWithSender:sender];
    UIResponder <UITextInput> *tempDelegate = (UIResponder <UITextInput> *)delegate;
    
    UITextPosition *startPositionTemp = tempDelegate.selectedTextRange.end;
    self.moveCursorWithSelect = NO;
    
    [self moveCursorNextWordAction:nil];
    UITextPosition *startPositionMovedTemp = tempDelegate.selectedTextRange.end;
    if (((UITextRange * )[delegate _rangeOfLineEnclosingPosition:startPositionMovedTemp]).end == ((UITextRange * )[delegate _rangeOfLineEnclosingPosition:startPositionTemp]).end){
        [self moveCursorNextWordAction:nil];
        
        [delegate _moveToEndOfLine:NO withHistory:nil];
        
    }
    
    BOOL isWKContentView = [delegate isKindOfClass:objc_getClass("WKContentView")];
    BOOL isRTL  = [self isRTLForDelegate:delegate];
    
    if (isWKContentView){
        if (isRTL){
            [(WKContentView *)delegate _moveToStartOfLine:self.moveCursorWithSelect withHistory:nil];
        }else{
            [(WKContentView *)delegate _moveToEndOfLine:self.moveCursorWithSelect withHistory:nil];
        }
    }else{
        if ([delegate respondsToSelector:@selector(_moveToEndOfLine:withHistory:)]){
            //if (isRTL){
            //[delegate _moveToStartOfLine:NO withHistory:nil];
            //}else{
            [delegate _moveToEndOfLine:self.moveCursorWithSelect withHistory:nil];
            //}
        }else{
            [self moveCursorToLineExtremityWithDelegate:delegate direction:UITextLayoutDirectionRight];
        }
    }
    self.moveCursorWithSelect = NO;
}

-(void)moveCursorStartOfParagraphAction:(UIButton*)sender{
    [self beginImpactAnimationAndUpdateDelegateWithSender:sender];
    UIResponder <UITextInput> *tempDelegate = (UIResponder <UITextInput> *)delegate;
    
    UITextPosition *startPositionTemp = tempDelegate.selectedTextRange.start;
    if (startPositionTemp == ((UITextRange * )[delegate _rangeOfParagraphEnclosingPosition:startPositionTemp]).start){
        self.moveCursorWithSelect = NO;
        [self moveCursorPreviousWordAction:nil];
    }
    
    BOOL isWKContentView = [delegate isKindOfClass:objc_getClass("WKContentView")];
    BOOL isRTL  = [self isRTLForDelegate:delegate];
    
    if (isWKContentView){
        if (isRTL){
            [(WKContentView *)delegate _moveToEndOfParagraph:self.moveCursorWithSelect withHistory:nil];
        }else{
            [(WKContentView *)delegate _moveToStartOfParagraph:self.moveCursorWithSelect withHistory:nil];
        }
    }else{
        if ([delegate respondsToSelector:@selector(_moveToStartOfParagraph:withHistory:)]){
            //if (isRTL){
            //[delegate _moveToStartOfLine:NO withHistory:nil];
            //}else{
            [delegate _moveToStartOfParagraph:self.moveCursorWithSelect withHistory:nil];
            //}
        }
    }
    self.moveCursorWithSelect = NO;
}

-(void)moveCursorEndOfParagraphAction:(UIButton*)sender{
    [self beginImpactAnimationAndUpdateDelegateWithSender:sender];
    UIResponder <UITextInput> *tempDelegate = (UIResponder <UITextInput> *)delegate;
    
    UITextPosition *endPositionTemp = tempDelegate.selectedTextRange.end;
    if (endPositionTemp == ((UITextRange * )[delegate _rangeOfParagraphEnclosingPosition:endPositionTemp]).end){
        self.moveCursorWithSelect = NO;
        [self moveCursorNextWordAction:nil];
    }
    BOOL isWKContentView = [delegate isKindOfClass:objc_getClass("WKContentView")];
    BOOL isRTL  = [self isRTLForDelegate:delegate];
    
    if (isWKContentView){
        if (isRTL){
            [(WKContentView *)delegate _moveToStartOfParagraph:self.moveCursorWithSelect withHistory:nil];
        }else{
            [(WKContentView *)delegate _moveToEndOfParagraph:self.moveCursorWithSelect withHistory:nil];
        }
    }else{
        if ([delegate respondsToSelector:@selector(_moveToEndOfParagraph:withHistory:)]){
            //if (isRTL){
            //[delegate _moveToStartOfLine:NO withHistory:nil];
            //}else{
            [delegate _moveToEndOfParagraph:self.moveCursorWithSelect withHistory:nil];
            //}
        }
    }
    self.moveCursorWithSelect = NO;
}

-(void)moveCursorStartOfSentenceAction:(UIButton*)sender{
    [self beginImpactAnimationAndUpdateDelegateWithSender:sender];
    UIResponder <UITextInput> *tempDelegate = (UIResponder <UITextInput> *)delegate;
    
    UITextPosition *startPositionTemp = tempDelegate.selectedTextRange.start;
    self.moveCursorWithSelect = NO;
    [self moveCursorPreviousWordAction:nil];
    UITextPosition *startPositionMovedTemp = tempDelegate.selectedTextRange.start;
    if (((UITextRange * )[delegate _rangeOfSentenceEnclosingPosition:startPositionMovedTemp]).start == ((UITextRange * )[delegate _rangeOfSentenceEnclosingPosition:startPositionTemp]).start){
        //[delegate _moveToStartOfLine:NO withHistory:nil];
        
        [self moveCursorPreviousWordAction:nil];
        
    }
    
    [delegate _setSelectionToPosition:((UITextRange * )[delegate _rangeOfSentenceEnclosingPosition:startPositionMovedTemp]).start];
    
}

-(void)moveCursorEndOfSentenceAction:(UIButton*)sender{
    [self beginImpactAnimationAndUpdateDelegateWithSender:sender];
    UIResponder <UITextInput> *tempDelegate = (UIResponder <UITextInput> *)delegate;
    
    UITextPosition *startPositionTemp = tempDelegate.selectedTextRange.end;
    self.moveCursorWithSelect = NO;
    
    [self moveCursorNextWordAction:nil];
    UITextPosition *startPositionMovedTemp = tempDelegate.selectedTextRange.end;
    if (((UITextRange * )[delegate _rangeOfSentenceEnclosingPosition:startPositionMovedTemp]).end == ((UITextRange * )[delegate _rangeOfSentenceEnclosingPosition:startPositionTemp]).end){
        [self moveCursorNextWordAction:nil];
        
        //[delegate _moveToEndOfLine:NO withHistory:nil];
        
    }
    [delegate _setSelectionToPosition:((UITextRange * )[delegate _rangeOfSentenceEnclosingPosition:startPositionMovedTemp]).end];
    
}

-(void)moveCursorUpAction:(UIButton*)sender{
    [self beginImpactAnimationAndUpdateDelegateWithSender:sender];
    
    BOOL isWKContentView = [delegate isKindOfClass:objc_getClass("WKContentView")];
    if (isWKContentView){
        [(WKContentView *)delegate executeEditCommandWithCallback:@"moveUp"];
    }else{
        [self moveCursorVerticalWithDelegate:delegate direction:UITextLayoutDirectionUp];
    }
}

-(void)moveCursorDownAction:(UIButton*)sender{
    [self beginImpactAnimationAndUpdateDelegateWithSender:sender];
    
    BOOL isWKContentView = [delegate isKindOfClass:objc_getClass("WKContentView")];
    if (isWKContentView){
        [(WKContentView *)delegate executeEditCommandWithCallback:@"moveDown"];
    }else{
        [self moveCursorVerticalWithDelegate:delegate direction:UITextLayoutDirectionDown];
    }
}

-(void)moveCursorContinuoslyWithDelegate:(id <UITextInput, UITextInputTokenizer>)delegate offset:(int)offset{
    [self moveCursorWithDelegate:delegate offset:offset];
}

-(void)defineAction:(UIButton*)sender{
    [self beginImpactAnimationAndUpdateDelegateWithSender:sender];
    UIResponder <UITextInput> *tempDelegate = (UIResponder <UITextInput> *)delegate;
    
    BOOL isWKContentView = [tempDelegate isKindOfClass:objc_getClass("WKContentView")];
    if (isWKContentView){
        NSString *selectedString = [(WKContentView *)tempDelegate selectedText];
        [(WKContentView *)tempDelegate select:nil];
        if ([selectedString length] == 0) return;
        if ([tempDelegate respondsToSelector:@selector(_define:)]){
            //[(WKContentView *)tempDelegate selectWordBackward];
            [(WKContentView *)tempDelegate _define:selectedString];
        }
    }else{
        NSString *selectedString = [tempDelegate textInRange:[tempDelegate selectedTextRange]];
        
        if (!selectedString.length) {
            UITextRange *textRange = [self autoDirectionWordSelectedTextRangeWithDelegate:tempDelegate];
            if (!textRange) return;
            tempDelegate.selectedTextRange = textRange;
            selectedString = [tempDelegate textInRange:textRange];
        }
        if ([tempDelegate respondsToSelector:@selector(_define:)]){
            [tempDelegate _define:selectedString];
        }
    }
}

-(NSDictionary *)getItemWithID:(NSString *)snippetID forKey:(NSString *)keyName identifierKey:(NSString *)identifier{
    NSString *scopedKey = [self scopedPreferenceKey:keyName];
    NSArray *arrayWithEventID = [prefs[scopedKey] valueForKey:identifier];
    NSUInteger index = [arrayWithEventID indexOfObject:snippetID];
    NSDictionary *snippet = index != NSNotFound ? prefs[scopedKey][index] : nil;
    return snippet;
}

-(void)runCommand:(NSString *)cmd{
    if ([cmd length] != 0){
        DXRunShellCommand(cmd);
    }
}

-(void)runCommandAction:(UIButton*)sender{
    NSDictionary *snippet = [self getItemWithID:NSStringFromSelector(_cmd) forKey:@"snippets" identifierKey:@"entryID"];
    [self triggerImpactAndAnimationWithButton:sender];
    if (snippet[@"command"]){
        [self runCommand:snippet[@"command"]];
    }
}

-(BOOL)boolWithProbability:(double)probability{
    return rand() <  probability * ((double)RAND_MAX + 1.0);
}

-(NSString *)capitalize:(NSString *)theString probability:(double)probability{
    NSInteger theStrLen = theString.length;
    if (theStrLen == 0) return theString;
    NSMutableString *capStr = [NSMutableString stringWithCapacity:theStrLen];
    for (NSInteger i = 0; i < theStrLen; i++) {
        NSRange range = NSMakeRange(i, 1);
        NSString *character = [theString substringWithRange:range];
        character = [self boolWithProbability:probability] ? [character uppercaseString] : [character lowercaseString];
        [capStr appendString:character];
    }
    return [NSString stringWithString:capStr];
}

-(NSString *)capitalizeAlternatively:(NSString *)theString{
    NSInteger theStrLen = theString.length;
    if (theStrLen == 0) return theString;
    BOOL firstSeed = [self boolWithProbability:0.5];
    NSMutableString *capStr = [NSMutableString stringWithCapacity:theStrLen];
    for (NSInteger i = 0; i < theStrLen; i++) {
        NSRange range = NSMakeRange(i, 1);
        NSString *character = [theString substringWithRange:range];
        character = firstSeed ? [character uppercaseString] : [character lowercaseString];
        firstSeed = !firstSeed;
        [capStr appendString:character];
    }
    return [NSString stringWithString:capStr];
}

-(BOOL)isVowel:(NSString *)theString{
    NSAssert([theString length] == 1, @"Invalid character length");
    return ([@"aeiou" rangeOfString:[theString lowercaseString]].location != NSNotFound);
}

-(NSString *)capitalize:(NSString *)theString phonemes:(DXPhonemesType)type{
    NSInteger theStrLen = theString.length;
    if (theStrLen == 0) return theString;
    NSMutableString *capStr = [NSMutableString stringWithCapacity:theStrLen];
    for (NSInteger i = 0; i < theStrLen; i++) {
        NSRange range = NSMakeRange(i, 1);
        NSString *character = [theString substringWithRange:range];
        switch (type){
            case DXPhonemesTypeConsonent:{
                character = ![self isVowel:character] ? [character uppercaseString] : [character lowercaseString];
                break;
            }
            default:{
                character = [self isVowel:character] ? [character uppercaseString] : [character lowercaseString];
                break;
            }
        }
        [capStr appendString:character];
    }
    return [NSString stringWithString:capStr];
}

-(void)spongebobAction:(UIButton*)sender{
    [self beginImpactAnimationAndUpdateDelegateWithSender:sender];
    NSString *selectedString = [delegate textInRange:[delegate selectedTextRange]];
    if (!selectedString.length) {
        
        UITextRange *textRange;
        UIResponder <UITextInput> *tempDelegate = (UIResponder <UITextInput, UITextInputTokenizer> *)delegate;
        
        UITextPosition *startPositionTemp = tempDelegate.selectedTextRange.start;
        UITextPosition *startPositionSentence = ((UITextRange * )[tempDelegate _rangeOfSentenceEnclosingPosition:startPositionTemp]).start;
        UITextPosition *endPositionSentence = ((UITextRange * )[tempDelegate _rangeOfSentenceEnclosingPosition:startPositionTemp]).end;
        
        BOOL isWKContentView = [tempDelegate isKindOfClass:objc_getClass("WKContentView")];
        
        if (isWKContentView){
            
        }else{
            textRange = [tempDelegate textRangeFromPosition:startPositionSentence toPosition:endPositionSentence];
            [tempDelegate setSelectedTextRange:textRange];
        }
        
        if (!textRange) return;
        selectedString = [delegate textInRange:[delegate selectedTextRange]];
    }
    switch (spongebobEntropy){
        case DXStudlyCapsTypeAlternate:
            [kbImpl insertText:[self capitalizeAlternatively:selectedString]];
            break;
        case DXStudlyCapsTypeVowel:
            [kbImpl insertText:[self capitalize:selectedString phonemes:DXPhonemesTypeVowel]];
            break;
        case DXStudlyCapsTypeConsonent:
            [kbImpl insertText:[self capitalize:selectedString phonemes:DXPhonemesTypeConsonent]];
            break;
        default:
            [kbImpl insertText:[self capitalize:selectedString probability:0.5]];
            break;
            
    }
    [kbImpl clearTransientState];
    [kbImpl clearAnimations];
    [kbImpl setCaretBlinks:YES];
}

#pragma mark collectionview


-(NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView {
    (void)collectionView;
    return 1;
}
-(NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    (void)collectionView;
    return section == 0 ? MIN(((NSArray *)self.shortcuts[kselectors]).count,
        DXToolbarCapacityForPreferences(self.dxPreviewMode ? self.dxPreviewPreferences
            : [DXPrefsManager sharedInstance].prefs, self.configuration)) : 0;
}

// All six gestures share the same behavior: one action runs directly;
// multiple actions open the existing chooser in their configured order.
-(void)runSubActionsForButton:(UIButton *)button gesture:(DXShortcutGestureType)gesture {
    if (![button isKindOfClass:[UIButton class]] || !button.window) return;
    [DXJavaScriptHost cancelActive];
    NSArray<NSString *> *subActions = preferencesGestureActionSelectors(button.accessibilityIdentifier, (int)gesture, self.configuration);
    if (subActions.count == 0) return;

    self.hapticType = gesture == DXShortcutGestureTap ? 1 : 2;
    NSLog(@"[MUBX][Gesture] trigger gesture=%ld count=%lu configuration=%@", (long)gesture, (unsigned long)subActions.count, self.configuration);

    if (subActions.count == 1) {
        [self dispatchSubActionSelector:subActions.firstObject sender:button];
        return;
    }
    [self presentSubActionChooserForButton:button selectors:subActions];
}

-(void)activateLPActions:(UIGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) return;
    [self runSubActionsForButton:(UIButton *)recognizer.view gesture:DXShortcutGestureLongPress];
}

// Bundle identifiers use reverse-DNS notation. Web links are classified first,
// so this validator can accept any syntactically valid identifier without a
// hard-coded top-level-domain allowlist.
-(BOOL)isBundleIdentifier:(NSString *)value {
    if (value.length == 0) return NO;
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:@"^[A-Za-z0-9_](?:[A-Za-z0-9_-]*[A-Za-z0-9_])?(?:\\.[A-Za-z0-9_](?:[A-Za-z0-9_-]*[A-Za-z0-9_])?)+$"
                                                                                options:0
                                                                                  error:nil];
    return [expression firstMatchInString:value options:0 range:NSMakeRange(0, value.length)] != nil;
}

-(NSString *)currentInputTextForCustomAction {
    if (![delegate respondsToSelector:@selector(beginningOfDocument)] ||
        ![delegate respondsToSelector:@selector(endOfDocument)] ||
        ![delegate respondsToSelector:@selector(textRangeFromPosition:toPosition:)] ||
        ![delegate respondsToSelector:@selector(textInRange:)]) return @"";

    @try {
        UITextPosition *beginning = [delegate beginningOfDocument];
        UITextPosition *end = [delegate endOfDocument];
        UITextRange *range = [delegate textRangeFromPosition:beginning toPosition:end];
        NSString *text = range ? [delegate textInRange:range] : nil;
        return [text isKindOfClass:[NSString class]] ? text : @"";
    } @catch (__unused NSException *exception) {
        return @"";
    }
}

-(NSString *)escapedCustomActionParameter:(NSString *)value {
    NSMutableCharacterSet *allowed = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [allowed addCharactersInString:@"-._~"];
    return [value stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

-(void)showCustomActionMessage:(NSString *)message {
    if (message.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *container = self.window ?: DXKeyWindow();
        if (!container) return;

        [[container viewWithTag:DXCustomActionToastTag] removeFromSuperview];
        UILabel *toast = [[UILabel alloc] initWithFrame:CGRectZero];
        toast.tag = DXCustomActionToastTag;
        toast.text = message;
        toast.textColor = UIColor.whiteColor;
        toast.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.88];
        toast.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        toast.textAlignment = NSTextAlignmentCenter;
        toast.numberOfLines = 0;
        toast.layer.cornerRadius = 9;
        toast.layer.masksToBounds = YES;

        CGFloat maxWidth = MAX(120, MIN(CGRectGetWidth(container.bounds) - 40, 320));
        CGSize textSize = [toast sizeThatFits:CGSizeMake(maxWidth - 28, CGFLOAT_MAX)];
        CGFloat width = MIN(maxWidth, MAX(160, textSize.width + 28));
        CGFloat height = MAX(42, textSize.height + 20);
        CGFloat y = MAX(20, CGRectGetMidY(container.bounds) - height / 2.0);
        toast.frame = CGRectMake((CGRectGetWidth(container.bounds) - width) / 2.0, y, width, height);
        toast.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                                 UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
        toast.alpha = 0;
        [container addSubview:toast];

        [UIView animateWithDuration:0.18 animations:^{
            toast.alpha = 1;
        } completion:^(BOOL finished) {
            [UIView animateWithDuration:0.22 delay:1.6 options:UIViewAnimationOptionCurveEaseInOut animations:^{
                toast.alpha = 0;
            } completion:^(BOOL finished) {
                [toast removeFromSuperview];
            }];
        }];
    });
}

-(void)showCustomActionLinkError {
    NSString *message = LOCALIZED(@"CUSTOM_ACTION_LINK_ERROR");
    [self showCustomActionMessage:message.length > 0 ? message : @"动作链接设置错误"];
}

-(void)finishCustomActionOpen:(DXCustomActionOpenCompletion)completion success:(BOOL)success {
    if (!completion) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(success);
    });
}

// Privileged actions execute in SpringBoard and complete from its reply, not
// from the success of publishing bytes. Ordinary URLs retain UIApplication's
// existing host route (including PullOver's interception/completion behavior).
-(DXCustomActionOpenCompletion)guardedCustomOpenCompletion:(DXCustomActionOpenCompletion)completion {
    NSUInteger generation = [objc_getAssociatedObject(self, &DXCustomOpenGenerationKey) unsignedIntegerValue] + 1;
    objc_setAssociatedObject(self, &DXCustomOpenGenerationKey, @(generation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak DXCollectionView *weakSelf = self;
    __weak UIWindow *originWindow = self.window;
    NSTimeInterval started = [NSDate date].timeIntervalSince1970;
    return ^(BOOL success) {
        DXCollectionView *view = weakSelf;
        if (!view || [objc_getAssociatedObject(view, &DXCustomOpenGenerationKey) unsignedIntegerValue] != generation) return;
        // A late error belongs to the toolbar/session that submitted it.
        if (!success && ([NSDate date].timeIntervalSince1970 - started > 15.0 ||
            !originWindow || view.window != originWindow || originWindow.hidden || view.hidden ||
            (!isSpringBoard && UIApplication.sharedApplication.applicationState != UIApplicationStateActive))) return;
        if (completion) completion(success);
    };
}

-(void)openApplicationWithBundleIdentifier:(NSString *)bundleIdentifier
                                 completion:(DXCustomActionOpenCompletion)completion {
    completion = [self guardedCustomOpenCompletion:completion];
    DXOpenSystemApplication(bundleIdentifier, ^(DXSystemOpenResult result) {
        [self finishCustomActionOpen:completion success:result == DXSystemOpenSucceeded];
    });
}

-(void)openCustomActionURL:(NSURL *)url completion:(DXCustomActionOpenCompletion)completion {
    completion = [self guardedCustomOpenCompletion:completion];
    if (!url.scheme.length) {
        [self finishCustomActionOpen:completion success:NO];
        return;
    }
    if (DXIsSensitiveOpenScheme(url.scheme)) {
        DXOpenSensitiveSystemURL(url, ^(DXSystemOpenResult result) {
            [self finishCustomActionOpen:completion success:result == DXSystemOpenSucceeded];
        });
        return;
    }

    UIApplication *application = UIApplication.sharedApplication;
    SEL openSelector = @selector(openURL:options:completionHandler:);
    if (!application || ![application respondsToSelector:openSelector]) {
        [self finishCustomActionOpen:completion success:NO];
        return;
    }
    // UIApplication's method returns void. A swallowed completion (for example
    // PullOver hosting the target) never triggers another open or a timeout toast.
    __block BOOL completionDelivered = NO;
    NSString *scheme = url.scheme.lowercaseString;
    NSLog(@"[MUBX] URL scheme single-shot dispatch: scheme=%@ sb=%d", scheme, isSpringBoard);
    void (^finish)(BOOL) = ^(BOOL success) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completionDelivered) return;
            completionDelivered = YES;
            NSLog(@"[MUBX] URL scheme single-shot completion: scheme=%@ success=%d", scheme, success);
            [self finishCustomActionOpen:completion success:success];
        });
    };
    @try {
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(application, openSelector, url, @{}, finish);
    } @catch (NSException *exception) {
        NSLog(@"[MUBX] URL scheme single-shot exception: scheme=%@ exception=%@", scheme, exception.name);
        finish(NO);
    }
}

// The @@@ placeholder receives the active input control's complete text,
// percent-encoded. URL-ish payloads only (url / url scheme / legacy /
// shortcut name). Text records are always literal.
-(NSString *)expandedCustomActionPayload:(NSString *)payload escaped:(BOOL)escaped {
    if (payload.length == 0 || ![payload containsString:@"@@@"]) return payload;
    NSString *parameter = [self currentInputTextForCustomAction];
    if (escaped) parameter = [self escapedCustomActionParameter:parameter];
    return [payload stringByReplacingOccurrencesOfString:@"@@@" withString:parameter];
}

// 剪切替换 for @@@: the entry's switch picks between cut semantics (the field
// is cleared once its text has been passed into the payload) and copy
// semantics (the field keeps its content, the historical default). Armed only
// when the raw payload actually contains @@@ — a payload that never reads the
// field must never clear it.
-(BOOL)cutReplaceArmedForEntry:(NSDictionary *)entry rawPayload:(NSString *)rawPayload {
    return [entry[kCustomActionCutReplaceKey] boolValue] && [rawPayload containsString:@"@@@"];
}

// Same whole-document clear the delete-all button and the AI seed hand-off
// use. Only called after the action has passed its validation and is about to
// dispatch, so a rejected action never destroys the field content.
-(void)cutHostInputField {
    [self beginUpdateDelegate];
    [self clearHostInputText];
}

// Inserts at the caret through the same channel the built-in paste action
// uses. The private UIKeyboardImpl insert must stay a last-resort fallback:
// calling it as the primary path crashes host apps on iOS 17, and no built-in
// action reaches it in practice (their delegate-first ladder answers first).
-(void)insertTextIntoInputField:(NSString *)text {
    // insertText: is UIKeyInput — every real text responder
    // (UITextField/UITextView/web editors) implements it.
    if (delegate && [delegate respondsToSelector:@selector(insertText:)]) {
        @try {
            [delegate insertText:text];
            return;
        } @catch (__unused NSException *exception) {
            // Fall through to the keyboard-impl fallback, then the toast.
        }
    }

    Class implClass = objc_getClass("UIKeyboardImpl");
    UIKeyboardImpl *impl = kbImpl;
    if (!impl && [implClass respondsToSelector:@selector(activeInstance)]) impl = [implClass activeInstance];
    if (![impl respondsToSelector:@selector(insertText:)]) {
        [self showCustomActionMessage:LOCALIZED(@"TEXT_RECORD_INPUT_UNAVAILABLE")];
        return;
    }
    @try {
        [impl insertText:text];
        if ([impl respondsToSelector:@selector(clearTransientState)]) [impl clearTransientState];
        if ([impl respondsToSelector:@selector(clearAnimations)]) [impl clearAnimations];
        if ([impl respondsToSelector:@selector(setCaretBlinks:)]) [impl setCaretBlinks:YES];
    } @catch (__unused NSException *exception) {
        [self showCustomActionMessage:LOCALIZED(@"TEXT_RECORD_INPUT_UNAVAILABLE")];
    }
}

// Text actions contain only literal records. There is no fallback to link.
-(void)performTextCustomAction:(NSDictionary *)entry sender:(UIButton *)sender {
    NSMutableArray<NSString *> *records = [NSMutableArray array];
    id stored = entry[kCustomActionTextRecordsKey];
    if ([stored isKindOfClass:NSArray.class]) {
        for (id record in stored) {
            if ([record isKindOfClass:NSString.class] && [record length]) [records addObject:record];
        }
    }
    [DXActiveSubActionPanelOwner dismissSubActionPanelAnimated:NO completion:nil];
    if (!records.count) {
        [self showCustomActionMessage:LOCALIZED(@"TEXT_RECORD_REQUIRED")];
    } else if (records.count == 1) {
        [self insertTextIntoInputField:records.firstObject];
    } else {
        [self presentActionChooserForButton:sender selectors:nil textRecords:records];
    }
}

// In-app open for the url type. SFSafariViewController needs a presenting
// view controller, which only exists in host-app processes; SpringBoard (and
// any presentation failure) returns NO so the caller falls back to the
// out-of-app open ladder.
-(BOOL)openURLInAppBrowser:(NSURL *)url {
    UIViewController *presenter = nil;
    UIWindow *window = self.window ?: DXKeyWindow();
    if ([UIApplication sharedApplication] && window) {
        presenter = window.rootViewController;
        while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    }
    if (!presenter) return NO;

    @try {
        SFSafariViewController *safari = [[SFSafariViewController alloc] initWithURL:url];
        [presenter presentViewController:safari animated:YES completion:nil];
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

-(BOOL)dispatchWebURLCustomAction:(NSString *)link inApp:(BOOL)inApp cutInputField:(BOOL)cutInputField {
    NSString *lowercaseLink = link.lowercaseString;
    BOOL isHTTPURL = [lowercaseLink hasPrefix:@"http://"] || [lowercaseLink hasPrefix:@"https://"];
    BOOL isWWWURL = [lowercaseLink hasPrefix:@"www."];
    if (!isHTTPURL && !isWWWURL) {
        [self showCustomActionLinkError];
        return YES;
    }

    NSString *webLink = isWWWURL ? [@"https://" stringByAppendingString:link] : link;
    NSURL *url = [NSURL URLWithString:webLink];
    BOOL validWebURL = url && url.host.length > 0 &&
        ([url.scheme.lowercaseString isEqualToString:@"http"] ||
         [url.scheme.lowercaseString isEqualToString:@"https"]);
    if (!validWebURL) {
        [self showCustomActionLinkError];
        return YES;
    }

    // 剪切替换: the field goes only after the URL has been accepted.
    if (cutInputField) [self cutHostInputField];

    if (inApp && [self openURLInAppBrowser:url]) {
        return YES;
    }
    [self openCustomActionURL:url completion:^(BOOL success) {
        if (!success) {
            [self showCustomActionLinkError];
        }
    }];
    return YES;
}

// Runs one user-defined custom action. The entry's "type" picks the
// execution path; legacy entries without a type keep the old auto-detecting
// link behavior. Ordinary URL-scheme opens are single-shot UIApplication
// requests so PullOver-X can claim them without a later retry opening the app
// full-screen. Sensitive system schemes select the SpringBoard route up front.
-(BOOL)dispatchLinkActionSelector:(NSString *)selectorName
                           sender:(UIButton *)sender {
    NSDictionary *entry = preferencesLinkActionForSelector(selectorName);
    if (!entry) return NO;

    NSString *type = [entry[kCustomActionTypeKey] isKindOfClass:[NSString class]] ? entry[kCustomActionTypeKey] : @"";

    [self beginImpactAnimationAndUpdateDelegateWithSender:sender];

    if ([type isEqualToString:kCustomActionTypeSystem]) {
        __weak DXCollectionView *weakSelf = self;
        __weak id originalInput = delegate;
        __block NSString *failureKey = @"SYSTEM_ACTION_UNAVAILABLE";
        DXCustomActionOpenCompletion completion = [self guardedCustomOpenCompletion:^(BOOL success) {
            DXCollectionView *view = weakSelf;
            if (!view || success || !originalInput) return;
            Class keyboardClass = NSClassFromString(@"UIKeyboardImpl");
            if (![keyboardClass respondsToSelector:@selector(activeInstance)] ||
                DXKeyboardInputDelegate([keyboardClass activeInstance]) != originalInput) return;
            [view showCustomActionMessage:LOCALIZED(failureKey)];
        }];
        DXRunSystemAction(entry[kCustomActionSystemIdentifierKey], ^(DXSystemOpenResult result) {
            switch (result) {
                case DXSystemOpenFailed: failureKey = @"SYSTEM_ACTION_FAILED"; break;
                case DXSystemOpenTimedOut: failureKey = @"SYSTEM_ACTION_TIMEOUT"; break;
                case DXSystemOpenInvalid: failureKey = @"SYSTEM_ACTION_INVALID"; break;
                case DXSystemOpenBusy:
                case DXSystemOpenExpired: failureKey = @"SYSTEM_ACTION_EXPIRED"; break;
                default: break;
            }
            completion(result == DXSystemOpenSucceeded);
        });
        return YES;
    }
    if ([type isEqualToString:kCustomActionTypeJavaScript]) {
        __weak DXCollectionView *weakSelf = self;
        [DXJavaScriptHost startEntry:entry sourceView:self inputProvider:^id{
            Class cls = objc_getClass("UIKeyboardImpl");
            if (![cls respondsToSelector:@selector(activeInstance)]) return nil;
            @try { return DXKeyboardInputDelegate([cls activeInstance]); }
            @catch (__unused NSException *exception) { return nil; }
        } open:^(NSString *kind, NSString *content) {
            DXCollectionView *view = weakSelf;
            if (!view) return;
            if ([kind isEqualToString:@"app"]) {
                [view openApplicationWithBundleIdentifier:content completion:^(BOOL success) {
                    if (!success) [weakSelf showCustomActionLinkError];
                }];
            } else {
                NSURL *url = [NSURL URLWithString:content];
                BOOL web = [@[@"http", @"https"] containsObject:url.scheme.lowercaseString];
                if ([kind isEqualToString:@"urlInApp"] && web) {
                    [view dispatchWebURLCustomAction:content inApp:YES cutInputField:NO];
                } else {
                    [view openCustomActionURL:url completion:^(BOOL success) {
                        if (!success) [weakSelf showCustomActionLinkError];
                    }];
                }
            }
        } error:^(NSString *message) { [weakSelf showCustomActionMessage:message]; }];
        return YES;
    }

    NSString *link = [entry[@"link"] isKindOfClass:[NSString class]] ? entry[@"link"] : @"";
    link = [link stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if ([type isEqualToString:kCustomActionTypeShortcut]) {
        DXCustomActionOpenCompletion completion = [self guardedCustomOpenCompletion:^(BOOL success) {
            if (!success) [self showCustomActionMessage:LOCALIZED(@"CUSTOM_ACTION_SHORTCUT_ERROR")];
        }];
        DXOpenSystemShortcut(link, entry[kCustomActionShortcutTypeKey], ^(DXSystemOpenResult result) {
            [self finishCustomActionOpen:completion success:result == DXSystemOpenSucceeded];
        });
        return YES;
    }

    if ([type isEqualToString:kCustomActionTypeOpenApp]) {
        if (!DXIsValidBundleIdentifier(link)) {
            [self showCustomActionLinkError];
            return YES;
        }

        if (DXActionUsesFloatingApp(entry, YES)) {
            DXCustomActionOpenCompletion completion = [self guardedCustomOpenCompletion:^(BOOL success) {
                if (!success) [self showCustomActionMessage:LOCALIZED(@"FLOATING_APP_OPEN_ERROR")];
            }];
            DXOpenFloatingApplication(link, ^(DXSystemOpenResult result) {
                [self finishCustomActionOpen:completion success:result == DXSystemOpenSucceeded];
            });
        } else {
            [self openApplicationWithBundleIdentifier:link completion:^(BOOL success) {
                if (!success) [self showCustomActionLinkError];
            }];
        }
        return YES;
    }

    if ([type isEqualToString:kCustomActionTypeText]) {
        [self performTextCustomAction:entry sender:sender];
        return YES;
    }

    if ([type isEqualToString:kCustomActionTypeURL]) {
        id storedInApp = entry[kCustomActionInAppKey];
        // APP内打开 is the default: an absent flag still means in-app.
        BOOL inApp = (storedInApp == nil) || [storedInApp boolValue];
        BOOL cutField = [self cutReplaceArmedForEntry:entry rawPayload:link];
        return [self dispatchWebURLCustomAction:[self expandedCustomActionPayload:link escaped:YES]
                                          inApp:inApp
                                  cutInputField:cutField];
    }

    if ([type isEqualToString:kCustomActionTypeURLScheme]) {
        NSString *payload = [self expandedCustomActionPayload:link escaped:YES];
        if (!DXIsOpenableSchemeURLString(payload)) {
            [self showCustomActionLinkError];
            return YES;
        }
        if ([self cutReplaceArmedForEntry:entry rawPayload:link]) [self cutHostInputField];
        NSURL *url = [NSURL URLWithString:payload];
        if (DXActionUsesFloatingApp(entry, NO)) {
            DXCustomActionOpenCompletion completion = [self guardedCustomOpenCompletion:^(BOOL success) {
                if (!success) [self showCustomActionMessage:LOCALIZED(@"FLOATING_APP_OPEN_ERROR")];
            }];
            DXOpenFloatingURL(url, ^(DXSystemOpenResult result) {
                [self finishCustomActionOpen:completion success:result == DXSystemOpenSucceeded];
            });
        } else {
            [self openCustomActionURL:url completion:^(BOOL success) {
                if (!success) [self showCustomActionLinkError];
            }];
        }
        return YES;
    }

    // Legacy entry: open a user-defined web URL, URL scheme, or installed app
    // bundle ID, classified from the link itself. The armed flag reads the raw
    // link before expansion overwrites it.
    BOOL cutField = [self cutReplaceArmedForEntry:entry rawPayload:link];
    link = [self expandedCustomActionPayload:link escaped:YES];
    if (link.length == 0) {
        [self showCustomActionLinkError];
        return YES;
    }

    NSString *lowercaseLink = link.lowercaseString;
    BOOL isHTTPURL = [lowercaseLink hasPrefix:@"http://"] || [lowercaseLink hasPrefix:@"https://"];
    BOOL isWWWURL = [lowercaseLink hasPrefix:@"www."];
    if (isHTTPURL || isWWWURL) {
        return [self dispatchWebURLCustomAction:link inApp:NO cutInputField:cutField];
    }

    NSRange schemeRange = [link rangeOfString:@"^[A-Za-z][A-Za-z0-9+.-]*:"
                                      options:NSRegularExpressionSearch];
    if (schemeRange.location == 0) {
        if (!DXIsOpenableSchemeURLString(link)) {
            [self showCustomActionLinkError];
            return YES;
        }

        if (cutField) [self cutHostInputField];
        NSURL *url = [NSURL URLWithString:link];
        if (DXActionUsesFloatingApp(entry, NO)) {
            DXCustomActionOpenCompletion completion = [self guardedCustomOpenCompletion:^(BOOL success) {
                if (!success) [self showCustomActionMessage:LOCALIZED(@"FLOATING_APP_OPEN_ERROR")];
            }];
            DXOpenFloatingURL(url, ^(DXSystemOpenResult result) {
                [self finishCustomActionOpen:completion success:result == DXSystemOpenSucceeded];
            });
            return YES;
        }
        [self openCustomActionURL:url completion:^(BOOL success) {
            if (!success) {
                [self showCustomActionLinkError];
            }
        }];
        return YES;
    }

    if ([self isBundleIdentifier:link]) {
        if (cutField) [self cutHostInputField];
        if (DXActionUsesFloatingApp(entry, YES)) {
            DXCustomActionOpenCompletion completion = [self guardedCustomOpenCompletion:^(BOOL success) {
                if (!success) [self showCustomActionMessage:LOCALIZED(@"FLOATING_APP_OPEN_ERROR")];
            }];
            DXOpenFloatingApplication(link, ^(DXSystemOpenResult result) {
                [self finishCustomActionOpen:completion success:result == DXSystemOpenSucceeded];
            });
            return YES;
        }
        [self openApplicationWithBundleIdentifier:link completion:^(BOOL success) {
            if (!success) {
                [self showCustomActionLinkError];
            }
        }];
        return YES;
    }

    [self showCustomActionLinkError];
    return YES;
}

// Dispatches either one built-in selector or one user-defined custom action.
-(void)dispatchConfiguredActionSelector:(NSString *)selectorName sender:(UIButton *)sender {
    [DXJavaScriptHost cancelActive];
    if (DXIsPanelSelector(selectorName)) {
        if (DXPanelAllowed(prefs, selectorName, DXPanelKeyboardKind))
            [[DXKeyboardPanel sharedInstance] presentFromToolbar:self panelSelector:selectorName];
        return;
    }
    if ([self dispatchLinkActionSelector:selectorName sender:sender]) return;
    if (![DXShortcutsGenerator isVisibleShortcutSelector:selectorName]) {
        return;
    }

    SEL action = NSSelectorFromString(selectorName);
    if (![self respondsToSelector:action]) {
        return;
    }

    ((void(*)(id, SEL, id))objc_msgSend)(self, action, sender);
}

-(void)dispatchSubActionSelector:(NSString *)selectorName sender:(UIButton *)sender {
    [self dispatchConfiguredActionSelector:selectorName sender:sender];
}

-(NSString *)subActionPanelTitleForSelector:(NSString *)selectorName {
    NSDictionary *linkAction = DXPanelDefinition(prefs, selectorName) ?: preferencesLinkActionForSelector(selectorName);
    NSString *title = [linkAction[@"name"] isKindOfClass:[NSString class]] ? linkAction[@"name"] : @"";
    if (title.length == 0) {
        title = [DXHelper localizedStringForActionNamed:selectorName shortName:NO bundle:tweakBundle];
    }
    return title.length ? title : selectorName;
}

-(UIImage *)subActionPanelImageForSelector:(NSString *)selectorName {
    NSDictionary *linkAction = DXPanelDisplayDefinition(prefs, selectorName) ?: preferencesLinkActionForSelector(selectorName);
    if (linkAction) {
        NSString *iconName = [linkAction[@"icon"] isKindOfClass:[NSString class]] ? linkAction[@"icon"] : @"";
        return [DXHelper imageForIconConfig:iconName defaultSymbolName:@"link"]
            ?: [UIImage systemImageNamed:@"link"];
    }

    NSArray<NSString *> *actionSelectors = [self.shortcutsGenerator selectorNames];
    NSUInteger index = [actionSelectors indexOfObject:selectorName];
    if (index != NSNotFound) {
        NSInteger imageVersion = 0;
        if (@available(iOS 13.0, *)) imageVersion = 1;
        NSArray<NSString *> *imageNames = [self.shortcutsGenerator imageNameArrayForiOS:imageVersion];
        if (index < imageNames.count) {
            UIImage *image = [DXHelper imageForName:imageNames[index] withSystemColor:NO completion:nil];
            if (image) return image;
        }
    }
    return [UIImage systemImageNamed:@"square.grid.2x2"];
}

// Creates (or reuses) the dedicated window that hosts the floating panel on
// iOS 17+. There the system keyboard is a remotely hosted window whose
// hierarchy no longer reliably renders foreign full-screen overlays or
// routes their touches, so the panel lives in its own window instead: same
// scene as the app's key window (falling back to the source window's scene,
// then any foreground-active scene), full-screen, at a level above every
// system window (status bar/alert/keyboard stay far below this). The window
// is never made key, so the text input keeps first responder and the panel's
// actions dispatch exactly as before. Returns nil when no usable scene
// exists and the caller should fall back to the source window.
static UIWindow *DXSubActionPanelCreateHostWindow(UIWindow *sourceWindow) {
    UIWindowScene *scene = DXKeyWindow().windowScene;
    if (!scene) scene = sourceWindow.windowScene;
    if (!scene) {
        for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
            if ([candidate isKindOfClass:[UIWindowScene class]] &&
                candidate.activationState == UISceneActivationStateForegroundActive) {
                scene = (UIWindowScene *)candidate;
                break;
            }
        }
    }
    if (!scene) return nil;

    if (DXSubActionPanelFloatingHostWindow) {
        if (DXSubActionPanelFloatingHostWindow.windowScene == scene) {
            DXSubActionPanelFloatingHostWindow.frame = scene.coordinateSpace.bounds;
            DXSubActionPanelFloatingHostWindow.hidden = NO;
            return DXSubActionPanelFloatingHostWindow;
        }
        DXSubActionPanelFloatingHostWindow.hidden = YES;
        DXSubActionPanelFloatingHostWindow = nil;
    }

    UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
    window.frame = scene.coordinateSpace.bounds;
    window.backgroundColor = UIColor.clearColor;
    window.windowLevel = 1000000.0;
    window.hidden = NO;
    DXSubActionPanelFloatingHostWindow = window;
    return window;
}

-(CGFloat)subActionPanelAnchorYInWindow:(UIWindow *)window {
    // Measured inside the toolbar's own window first: convertRect:toView: is
    // only defined within one window's hierarchy, and the iOS 17+ floating
    // host window is not an ancestor of the toolbar. That window is
    // full-screen at the scene origin, so its coordinates equal the source
    // window's screen coordinates, which convertRect:toWindow:nil provides.
    UIWindow *sourceWindow = self.window ?: [self keyWindow] ?: window;
    CGRect toolbarFrame = [self convertRect:self.bounds toView:sourceWindow];
    CGFloat anchorY = CGRectGetMinY(toolbarFrame);
    CGFloat minimumUsefulY = sourceWindow.safeAreaInsets.top + 40.0;
    CGFloat minimumWideWidth = CGRectGetWidth(sourceWindow.bounds) * 0.72;

    // The bottom toolbar lives near the keyboard's bottom. Walk through its
    // full-width keyboard ancestors to find the keyboard's upper edge. The top
    // accessory toolbar is already at that edge, so its own frame wins.
    for (UIView *ancestor = self.superview; ancestor && ancestor != sourceWindow; ancestor = ancestor.superview) {
        CGRect frame = [ancestor convertRect:ancestor.bounds toView:sourceWindow];
        CGFloat candidateY = CGRectGetMinY(frame);
        if (CGRectGetWidth(frame) >= minimumWideWidth && candidateY > minimumUsefulY && candidateY < anchorY) {
            anchorY = candidateY;
        }
    }
    if (window != sourceWindow) {
        anchorY = [sourceWindow convertRect:CGRectMake(0, anchorY, 1, 1) toWindow:nil].origin.y;
    }
    return anchorY;
}

-(void)dismissSubActionPanelAnimated:(BOOL)animated completion:(void (^)(void))completion {
    UIControl *overlay = self.subActionPanelOverlay;
    if (!overlay) {
        if (completion) completion();
        return;
    }

    self.subActionPanelOverlay = nil;
    self.subActionPanelSourceButton = nil;
    self.textPanelInput = nil;
    self.textPanelSourceWindow = nil;
    if (DXActiveSubActionPanelOwner == self) DXActiveSubActionPanelOwner = nil;

    // The dedicated iOS 17+ host window dies with its overlay. Captured
    // before the overlay leaves the hierarchy — afterwards its window reads
    // as nil.
    UIWindow *floatingHost = (overlay.window == DXSubActionPanelFloatingHostWindow)
        ? DXSubActionPanelFloatingHostWindow : nil;

    void (^removePanel)(void) = ^{
        [overlay removeFromSuperview];
        if (floatingHost && ![floatingHost viewWithTag:DXSubActionPanelOverlayTag]) {
            floatingHost.hidden = YES;
            if (DXSubActionPanelFloatingHostWindow == floatingHost) DXSubActionPanelFloatingHostWindow = nil;
        }
        if (completion) completion();
    };
    if (!animated) {
        removePanel();
        return;
    }

    UIView *panel = [overlay viewWithTag:DXSubActionPanelOverlayTag + 1];
    [UIView animateWithDuration:0.14 animations:^{
        overlay.alpha = 0.0;
        panel.transform = CGAffineTransformConcat(CGAffineTransformMakeTranslation(0, 8),
                                                   CGAffineTransformMakeScale(0.97, 0.97));
    } completion:^(__unused BOOL finished) {
        removePanel();
    }];
}

-(void)subActionPanelBackgroundTapped:(UIControl *)sender {
    (void)sender;
    [self dismissSubActionPanelAnimated:YES completion:nil];
}

-(void)subActionPanelItemTapped:(DXSubActionPanelItem *)item {
    NSString *selectorName = [item.actionSelector copy];
    UIButton *sourceButton = self.subActionPanelSourceButton;
    [self dismissSubActionPanelAnimated:YES completion:^{
        if (selectorName.length > 0) {
            [self dispatchSubActionSelector:selectorName sender:sourceButton];
        }
    }];
}

-(void)textActionPanelItemTapped:(DXTextActionPanelItem *)item {
    if (!self.subActionPanelOverlay || ![item isDescendantOfView:self.subActionPanelOverlay]) return;
    id originalInput = self.textPanelInput;
    UIWindow *sourceWindow = self.textPanelSourceWindow;
    [self beginUpdateDelegate];
    BOOL valid = originalInput && delegate == originalInput && sourceWindow &&
        self.window == sourceWindow && !sourceWindow.hidden && !self.hidden &&
        (!sourceWindow.windowScene || sourceWindow.windowScene.activationState == UISceneActivationStateForegroundActive);
    NSString *text = item.recordText;
    // Synchronous dismissal and insertion leave no delayed callback that can
    // write into a different input session after animation or another tap.
    [self dismissSubActionPanelAnimated:NO completion:nil];
    if (!valid) {
        NSLog(@"[MUBX] text-record: selection cancelled after input/window change");
        return;
    }
    [self insertTextIntoInputField:text];
}

-(void)presentSubActionChooserForButton:(UIButton *)button selectors:(NSArray<NSString *> *)selectors {
    [self presentActionChooserForButton:button selectors:selectors textRecords:nil];
}

-(void)presentActionChooserForButton:(UIButton *)button selectors:(NSArray<NSString *> *)selectors
                         textRecords:(NSArray<NSString *> *)textRecords {
    BOOL textMode = textRecords.count > 0;
    NSUInteger itemCount = textMode ? textRecords.count : selectors.count;
    if (!itemCount) return;
    [[DXKeyboardPanel sharedInstance] dismiss];
    UIWindow *sourceWindow = button.window ?: self.window ?: [self keyWindow];
    if (!sourceWindow) return;
    if (DXActiveSubActionPanelOwner && DXActiveSubActionPanelOwner != self) {
        [DXActiveSubActionPanelOwner dismissSubActionPanelAnimated:NO completion:nil];
    }
    [self dismissSubActionPanelAnimated:NO completion:nil];
    UIWindow *hostWindow = sourceWindow;
    if (@available(iOS 17.0, *)) {
        UIWindow *floating = DXSubActionPanelCreateHostWindow(sourceWindow);
        if (floating) hostWindow = floating;
    }
    NSLog(@"[MUBX] panel: presenting %lu %@ (floating host: %d)",
          (unsigned long)itemCount, textMode ? @"text records" : @"sub-actions", hostWindow != sourceWindow);

    UIControl *overlay = [[UIControl alloc] initWithFrame:hostWindow.bounds];
    overlay.tag = DXSubActionPanelOverlayTag;
    overlay.backgroundColor = UIColor.clearColor;
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [overlay addTarget:self action:@selector(subActionPanelBackgroundTapped:) forControlEvents:UIControlEventTouchUpInside];
    [hostWindow addSubview:overlay];

    CGFloat windowWidth = CGRectGetWidth(hostWindow.bounds);
    CGFloat panelScale = preferencesFloat([self scopedPreferenceKey:kSubActionPanelScaleKey],
                                          subActionPanelScaleDefault) / 100.0;
    panelScale = MIN(1.2, MAX(0.5, panelScale));
    CGFloat horizontalMargin = 8.0;
    CGFloat defaultPanelWidth = MIN(460.0, MAX(240.0, windowWidth - 24.0));
    // The size setting scales panel content and height only. Keep the panel's
    // horizontal footprint stable so changing the slider never shifts columns
    // or makes the floating panel narrower/wider.
    CGFloat panelWidth = MIN(windowWidth - horizontalMargin * 2.0, defaultPanelWidth);
    NSInteger columns = textMode ? 1 : (windowWidth >= 320.0 ? 4 : 3);
    CGFloat panelPadding = 10.0 * panelScale;
    CGFloat itemHeight = (textMode ? 70.0 : 92.0) * panelScale;
    CGFloat itemWidth = (panelWidth - panelPadding * 2.0) / columns;
    NSInteger rows = (itemCount + columns - 1) / columns;
    CGFloat contentHeight = panelPadding * 2.0 + rows * itemHeight;

    CGFloat safeTop = hostWindow.safeAreaInsets.top + 8.0;
    CGFloat anchorY = [self subActionPanelAnchorYInWindow:hostWindow];
    CGFloat availableHeight = MAX(itemHeight + panelPadding * 2.0, anchorY - safeTop - 8.0);
    CGFloat panelHeight = MIN(contentHeight, MIN(availableHeight, 300.0 * panelScale));
    CGFloat panelY = MAX(safeTop, anchorY - panelHeight - 8.0);

    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake((windowWidth - panelWidth) / 2.0,
                                                             panelY, panelWidth, panelHeight)];
    panel.tag = DXSubActionPanelOverlayTag + 1;
    panel.layer.cornerRadius = 18.0 * panelScale;
    panel.layer.shadowColor = UIColor.blackColor.CGColor;
    panel.layer.shadowOpacity = 0.2;
    panel.layer.shadowRadius = 14.0 * panelScale;
    panel.layer.shadowOffset = CGSizeMake(0, 5.0 * panelScale);
    [overlay addSubview:panel];

    UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
    UIVisualEffectView *background = [[UIVisualEffectView alloc] initWithEffect:effect];
    background.frame = panel.bounds;
    background.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    background.layer.cornerRadius = panel.layer.cornerRadius;
    background.layer.masksToBounds = YES;
    [panel addSubview:background];

    UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:panel.bounds];
    scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scrollView.contentSize = CGSizeMake(panelWidth, contentHeight);
    scrollView.alwaysBounceVertical = contentHeight > panelHeight;
    scrollView.showsVerticalScrollIndicator = NO;
    [panel addSubview:scrollView];

    // Cover the scrollable content behind the action items so gaps, padding,
    // and the unused cells in the final row dismiss the panel as well.
    UIControl *blankArea = [[UIControl alloc] initWithFrame:CGRectMake(0, 0, panelWidth,
                                                                       MAX(contentHeight, panelHeight))];
    blankArea.backgroundColor = UIColor.clearColor;
    [blankArea addTarget:self action:@selector(subActionPanelBackgroundTapped:) forControlEvents:UIControlEventTouchUpInside];
    [scrollView addSubview:blankArea];

    if (textMode) {
        [textRecords enumerateObjectsUsingBlock:^(NSString *text, NSUInteger index, __unused BOOL *stop) {
            DXTextActionPanelItem *item = [[DXTextActionPanelItem alloc] initWithFrame:
                CGRectMake(panelPadding, panelPadding + index * itemHeight, itemWidth, itemHeight)];
            item.recordText = text;
            item.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
            item.titleLabel.font = [UIFont systemFontOfSize:MAX(12, 16 * panelScale)];
            item.titleLabel.numberOfLines = 3;
            item.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
            [item setTitle:text forState:UIControlStateNormal];
            [item setTitleColor:UIColor.labelColor forState:UIControlStateNormal];
            [item setTitleColor:UIColor.secondaryLabelColor forState:UIControlStateHighlighted];
            item.accessibilityLabel = text;
            [item addTarget:self action:@selector(textActionPanelItemTapped:) forControlEvents:UIControlEventTouchUpInside];
            [scrollView addSubview:item];
            if (index + 1 < textRecords.count) {
                UIView *separator = [[UIView alloc] initWithFrame:CGRectMake(12, itemHeight - 0.5, MAX(0, itemWidth - 24), 0.5)];
                separator.backgroundColor = UIColor.separatorColor;
                separator.userInteractionEnabled = NO;
                [item addSubview:separator];
            }
        }];
        self.textPanelInput = delegate;
        self.textPanelSourceWindow = self.window;
    }
    [selectors enumerateObjectsUsingBlock:^(NSString *selectorName, NSUInteger index, __unused BOOL *stop) {
        NSInteger row = index / columns;
        NSInteger column = index % columns;
        DXSubActionPanelItem *item = [[DXSubActionPanelItem alloc] initWithFrame:CGRectMake(panelPadding + column * itemWidth,
                                                                                            panelPadding + row * itemHeight,
                                                                                            itemWidth, itemHeight)];
        item.actionSelector = selectorName;
        item.panelScale = panelScale;
        item.nameLabel.font = [UIFont systemFontOfSize:MAX(10.0, 13.0 * panelScale)
                                                weight:UIFontWeightRegular];
        [item configureWithTitle:[self subActionPanelTitleForSelector:selectorName]
                           image:[self subActionPanelImageForSelector:selectorName]];
        [item addTarget:self action:@selector(subActionPanelItemTapped:) forControlEvents:UIControlEventTouchUpInside];
        [scrollView addSubview:item];
    }];

    self.subActionPanelOverlay = overlay;
    self.subActionPanelSourceButton = button;
    DXActiveSubActionPanelOwner = self;

    overlay.alpha = 0.0;
    panel.transform = CGAffineTransformConcat(CGAffineTransformMakeTranslation(0, 8),
                                               CGAffineTransformMakeScale(0.97, 0.97));
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        overlay.alpha = 1.0;
        panel.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)toolbarHorizontalEnded:(DXToolbarHorizontalGesture *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded || !self.window || self.hidden ||
        gesture.sourceWindow != self.window || !self.shortcutConfigurationAvailable || isLandscape || isDictating || !toggledOn) return;
    if (gesture.sourceButton && ![gesture.sourceIdentifier isEqual:gesture.sourceButton.accessibilityIdentifier]) return;
    NSInteger result = gesture.result;
    if (labs(result) == 2) {
        NSString *enabledKey = [self.configuration isEqual:@"top"] ? kDXPanelTopEnabled : kDXPanelBottomEnabled;
        NSString *selector = DXToolbarAction(prefs, self.configuration, result < 0 ? @"left" : @"right");
        if (selector.length && DXKeyboardPanelBool(prefs, enabledKey, YES))
            [self dispatchKeyboardPanelSelector:selector sender:gesture.sourceButton];
    } else if (labs(result) == 1 && gesture.sourceButton.window == self.window) {
        [self runSubActionsForButton:gesture.sourceButton gesture:result < 0 ? DXShortcutGestureSwipeLeft : DXShortcutGestureSwipeRight];
    }
}
- (void)dismissKeyboardActionChooser { [self dismissSubActionPanelAnimated:NO completion:nil]; }
- (BOOL)canExecuteKeyboardPanelSelector:(NSString *)selector {
    if (![selector isKindOfClass:NSString.class] || !selector.length) return NO;
    if (DXIsPanelSelector(selector)) return DXPanelAllowed(prefs, selector, DXPanelKeyboardKind);
    if (DXIsLinkActionSelector(selector)) return preferencesLinkActionForSelector(selector) != nil;
    if (![DXShortcutsGenerator isVisibleShortcutSelector:selector] || ![self respondsToSelector:NSSelectorFromString(selector)]) return NO;
    if ([selector isEqualToString:@"shellxScreenshotAction:"]) return [DXShortcutsGenerator isShellXScreenshotAvailable];
    // MUBX 已内置剪贴板历史，按钮永远可用；Kayoko 只作为总开关关闭时的回退。
    if ([selector isEqualToString:@"clipboardAction:"]) return YES;
    if ([selector isEqualToString:@"pulloverWakeAction:"]) return [DXShortcutsGenerator isPullOverXInstalled];
    return YES;
}
- (void)dispatchKeyboardPanelSelector:(NSString *)selector sender:(UIButton *)sender {
    if (![NSThread isMainThread] || !self.window || self.hidden || ![self canExecuteKeyboardPanelSelector:selector]) return;
    [self beginUpdateDelegate];
    [self dispatchConfiguredActionSelector:selector sender:sender];
}

- (void)activateSwipeActions:(UISwipeGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateEnded) return;

    int gestureType;
    switch (recognizer.direction) {
        case UISwipeGestureRecognizerDirectionUp: gestureType = DXShortcutGestureSwipeUp; break;
        case UISwipeGestureRecognizerDirectionDown: gestureType = DXShortcutGestureSwipeDown; break;
        case UISwipeGestureRecognizerDirectionLeft: gestureType = DXShortcutGestureSwipeLeft; break;
        case UISwipeGestureRecognizerDirectionRight: gestureType = DXShortcutGestureSwipeRight; break;
        default: return;
    }

    [self runSubActionsForButton:(UIButton *)recognizer.view gesture:(DXShortcutGestureType)gestureType];
}

-(void)cellButtonTouchUpInside:(UIButton *)sender {
    [self runSubActionsForButton:sender gesture:DXShortcutGestureTap];
}

-(UIWindow *)keyWindow {
    return DXKeyWindow();
}


// 短文本按钮标题自适应：短标签模式下每个按钮只有一格宽度，两三个字放得下，
// 更多字数会被 UIButton 整体截成"…"。按"按钮可用宽度 / 文本自然宽度"等比缩小
// 字号（最小压到 9pt）让全文显示，仍放不下才回落系统截断。颜色属性刻意不带，
// 继续走 setTitleColor 设置的 textColor。
- (NSAttributedString *)shortLabelTitleByFittingText:(NSAttributedString *)title
                                              button:(UIButton *)button
                                      collectionView:(UICollectionView *)collectionView
                                           indexPath:(NSIndexPath *)indexPath {
    NSString *text = title.string;
    if (text.length == 0) return title;

    CGSize slot = [self collectionView:collectionView layout:collectionView.collectionViewLayout
              sizeForItemAtIndexPath:indexPath];
    CGFloat multiplier = self.widthScale / buttonWidthScaleDefault;
    if (multiplier <= 0) multiplier = 1.0;
    CGFloat available = slot.width * multiplier - 6.0; // 两侧各留 3pt，不顶圆角边框
    if (available <= 0) return title;

    UIFont *baseFont = button.titleLabel.font ?: [UIFont systemFontOfSize:15.0];
    CGFloat textWidth = [text sizeWithAttributes:@{NSFontAttributeName : baseFont}].width;
    CGFloat scaledSize = baseFont.pointSize;
    if (textWidth > available) {
        scaledSize = MAX(floorf(baseFont.pointSize * available / textWidth * 2.0) / 2.0, 9.0);
    }
    UIFontDescriptor *descriptor = [baseFont.fontDescriptor fontDescriptorWithSize:scaledSize];
    // SDK 头文件未声明 fontWithDescriptor:traits:，system 字体按 traits 走对应便捷构造
    UIFont *fittedFont = baseFont;
    if (descriptor.pointSize != baseFont.pointSize) {
        BOOL bold = (baseFont.fontDescriptor.symbolicTraits & UIFontDescriptorTraitBold) != 0;
        fittedFont = bold ? [UIFont boldSystemFontOfSize:descriptor.pointSize]
                          : [UIFont systemFontOfSize:descriptor.pointSize];
    }
    return [[NSMutableAttributedString alloc] initWithString:text
                                                  attributes:@{NSFontAttributeName : fittedFont}];
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    DXCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"kMUBXCellID" forIndexPath:indexPath];
    //cell.transform = CGAffineTransformMakeScale(-1, 1);
    int cellIndex = (int)indexPath.item;
    //[cell.btn setTitle:_buttons[indexPath.row] forState:UIControlStateNormal];
    NSString* selectorName = ((NSArray *)_shortcuts[kselectors])[cellIndex];
    
    UIImage* image;
    NSAttributedString *imageOfName = [[NSMutableAttributedString alloc] initWithString:@""];
    
    
    if (@available(iOS 13.0, *)){
        imageOfName = self.useShortLabel
            ? [(self.customNames[selectorName] ?: [DXHelper localizedStringForActionNamed:selectorName shortName:YES bundle:tweakBundle]) attributedString]
            : [((NSArray *)_shortcuts[kbuttonsImages13])[cellIndex] attributedString];
    }else{
        imageOfName = self.useShortLabel
            ? [(self.customNames[selectorName] ?: [DXHelper localizedStringForActionNamed:selectorName shortName:YES bundle:tweakBundle]) attributedString]
            : [((NSArray *)_shortcuts[kbuttonsImages12])[cellIndex] attributedString];
    }
    if (!self.useShortLabel) {
        image = [DXHelper imageForName:imageOfName.string withSystemColor:NO completion:nil];
    }
    if (self.useShortLabel){
        [cell.btn setImage:nil forState:UIControlStateNormal];
        [cell.btn setAttributedTitle:[self shortLabelTitleByFittingText:imageOfName
                                                                 button:cell.btn
                                                         collectionView:collectionView
                                                              indexPath:indexPath]
                           forState:UIControlStateNormal];
    }else{
        [cell.btn setAttributedTitle:nil forState:UIControlStateNormal];
        [cell.btn setImage:image forState:UIControlStateNormal];
    }
    cell.btn.accessibilityIdentifier = selectorName;
    [cell.btn removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    
    // Single tap is the button's own TouchUpInside event: it fires on touch-up
    // with no gesture-recognizer window, so taps can be repeated as fast as the
    // user likes. No tap recognizer is mounted; one would delay every touch-up
    // until it fails.
    if (!self.dxPreviewMode)
        [cell.btn addTarget:self action:@selector(cellButtonTouchUpInside:) forControlEvents:UIControlEventTouchUpInside];

    // Mount recognizers only for gestures with executable actions.
    NSMutableArray<UIGestureRecognizer *> *recognizers = [NSMutableArray array];
    if (!self.dxPreviewMode && [preferencesGestureActionSelectors(cell.btn.accessibilityIdentifier, DXShortcutGestureLongPress, self.configuration) count] > 0) {
        UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(activateLPActions:)];
        longPress.minimumPressDuration = 0.5;
        [recognizers addObject:longPress];
    }

    // Horizontal gestures are routed once by the toolbar; only vertical swipes stay on buttons.
    for (NSInteger gesture = DXShortcutGestureSwipeUp; gesture <= DXShortcutGestureSwipeDown; gesture++) {
        if (self.dxPreviewMode) break;
        if ([preferencesGestureActionSelectors(cell.btn.accessibilityIdentifier, (int)gesture, self.configuration) count] == 0) continue;

        UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(activateSwipeActions:)];
        switch (gesture) {
            case DXShortcutGestureSwipeUp: swipe.direction = UISwipeGestureRecognizerDirectionUp; break;
            case DXShortcutGestureSwipeDown: swipe.direction = UISwipeGestureRecognizerDirectionDown; break;
            case DXShortcutGestureSwipeLeft: swipe.direction = UISwipeGestureRecognizerDirectionLeft; break;
            default: swipe.direction = UISwipeGestureRecognizerDirectionRight; break;
        }
        [recognizers addObject:swipe];
    }
    cell.btn.gestureRecognizers = recognizers;
    
    //cell.btn.backgroundColor = [UIColor clearColor];
    //cell.btn.layer.cornerRadius = 0; // this value vary as per your desire
    //cell.btn.clipsToBounds = NO;
    //}
    //self.layer.masksToBounds = NO;
    
    if (self.useShortLabel) cell.btn.clipsToBounds = YES; else cell.btn.clipsToBounds = NO;

    // Button chrome: corner radius and the optional outlined border. The border
    // color follows the system label color so it stays visible on both light
    // and dark keyboards.
    cell.btn.layer.cornerRadius = [self buttonChromeActive] ? self.buttonRadius : 0;
    cell.btn.layer.borderWidth = self.borderEnabled ? self.borderWidth : 0;
    cell.btn.layer.borderColor = self.borderEnabled ? [UIColor labelColor].CGColor : NULL;
    [cell applyButtonWidthMultiplier:self.widthScale / buttonWidthScaleDefault];
    cell.btn.backgroundColor = [self dxButtonBackgroundTintColor] ?: [UIColor clearColor];
    UIColor *buttonTint = [self dxButtonTintColor];
    cell.btn.tintColor = buttonTint;
    [cell.btn setTitleColor:buttonTint forState:UIControlStateNormal];
    cell.btn.hidden = !self.dxPreviewMode && (isLandscape || isDictating);
    //cell.btn.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.7];
    return cell;
    
    
}


- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger count = [self multiRowActive] ? self.buttonsPerRow : MAX(1, [self numberOfItemsInSection:0]);
    UIEdgeInsets insets = [self collectionView:collectionView layout:collectionViewLayout insetForSectionAtIndex:0];
    CGFloat gap = [self buttonChromeActive] ? self.buttonSpacing : 0;
    CGFloat width = MAX(0, (CGRectGetWidth(collectionView.bounds) - insets.left - insets.right - gap * (count - 1)) / count);
    return CGSizeMake(width, self.buttonHeight);
}

- (UIEdgeInsets)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout insetForSectionAtIndex:(NSInteger)section {
    if ([self.configuration isEqualToString:@"top"]) {
        if (![self buttonChromeActive]) return UIEdgeInsetsMake(8.0, 0.0, 0.0, 0.0);
        // Half a gap on each side keeps N slots plus N-1 gaps centered in the bar.
        CGFloat halfGap = self.buttonSpacing / 2.0;
        return UIEdgeInsetsMake(8.0, halfGap, 0.0, halfGap);
    }
    // Bottom bar insets are fixed (22pt top padding; the chrome spacing keeps
    // the tinted buttons clear of the dock's edge buttons).
    if ([self buttonChromeActive]){
        if (section == 0){
            return UIEdgeInsetsMake(DXBottomToolbarCellTopInset, 2*self.buttonSpacing, 0.0, 0.0);

        }
        return UIEdgeInsetsMake(DXBottomToolbarCellTopInset, self.buttonSpacing, 0.0, 0.0);

    }
    return UIEdgeInsetsMake(DXBottomToolbarCellTopInset, 0.0, 0.0, 0.0);
}

- (CGFloat)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout*)collectionViewLayout minimumLineSpacingForSectionAtIndex:(NSInteger)section{
    return [self buttonChromeActive]?self.buttonSpacing:0;
}

@end
