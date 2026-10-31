#import "DXPSFSymbolPickerController.h"
#import "DXPSFSymbolCatalog.h"
#import "../common.h"

static NSBundle *tweakBundle;
// Successful catalogs only, confined to the main thread; failed loads retry.
static NSArray<DXPSFSymbolCategory *> *DXPAvailableSymbolCategories;
// Presentation only: share the last column choice within this Settings session.
static NSInteger DXPPreferredSymbolColumns = 4;

static NSString *DXPSymbolCategoryTitle(DXPSFSymbolCategory *category) {
    NSString *key = [@"SF_SYMBOL_CATEGORY_" stringByAppendingString:category.identifier];
    return [tweakBundle localizedStringForKey:key value:(category.title ?: category.identifier.capitalizedString) table:nil];
}

@interface DXPSFSymbolCell : UICollectionViewCell
@property (nonatomic, strong) UIView *tile;
@property (nonatomic, strong) UIImageView *symbolView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UIImageView *checkmark;
@property (nonatomic, strong) UIView *separator;
@property (nonatomic, assign) NSInteger columns;
- (void)configureWithName:(NSString *)name columns:(NSInteger)columns checked:(BOOL)checked;
@end

@implementation DXPSFSymbolCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.tile = [[UIView alloc] init];
    self.tile.layer.cornerRadius = 12;
    [self.contentView addSubview:self.tile];
    self.symbolView = [[UIImageView alloc] init];
    self.symbolView.contentMode = UIViewContentModeScaleAspectFit;
    self.symbolView.tintColor = UIColor.labelColor;
    [self.tile addSubview:self.symbolView];
    self.nameLabel = [[UILabel alloc] init];
    self.nameLabel.adjustsFontForContentSizeCategory = YES;
    self.nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.contentView addSubview:self.nameLabel];
    self.checkmark = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.circle.fill"]];
    self.checkmark.contentMode = UIViewContentModeScaleAspectFit;
    self.checkmark.tintColor = UIColor.systemBlueColor;
    [self.contentView addSubview:self.checkmark];
    self.separator = [[UIView alloc] init];
    self.separator.backgroundColor = UIColor.separatorColor;
    [self.contentView addSubview:self.separator];
    UIView *highlight = [[UIView alloc] init];
    highlight.backgroundColor = UIColor.tertiarySystemFillColor;
    highlight.layer.cornerRadius = 12;
    self.selectedBackgroundView = highlight;
    self.isAccessibilityElement = YES;
    return self;
}

- (void)configureWithName:(NSString *)name columns:(NSInteger)columns checked:(BOOL)checked {
    self.columns = columns;
    BOOL list = columns == 1;
    self.symbolView.image = [UIImage systemImageNamed:name withConfiguration:
        [UIImageSymbolConfiguration configurationWithPointSize:(list ? 24 : 32) weight:UIImageSymbolWeightRegular]];
    self.tile.backgroundColor = list ? UIColor.clearColor : UIColor.tertiarySystemFillColor;
    self.nameLabel.text = name;
    self.nameLabel.font = [[UIFontMetrics metricsForTextStyle:(list ? UIFontTextStyleBody : UIFontTextStyleFootnote)]
        scaledFontForFont:[UIFont systemFontOfSize:(list ? 15 : 12)]];
    self.nameLabel.textColor = list ? UIColor.labelColor : UIColor.secondaryLabelColor;
    self.nameLabel.textAlignment = list ? NSTextAlignmentNatural : NSTextAlignmentCenter;
    self.nameLabel.numberOfLines = list ? 1 : 2;
    self.separator.hidden = !list;
    self.checkmark.hidden = !checked;
    self.accessibilityLabel = name;
    self.accessibilityTraits = UIAccessibilityTraitButton | (checked ? UIAccessibilityTraitSelected : 0);
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.contentView.bounds);
    CGFloat height = CGRectGetHeight(self.contentView.bounds);
    if (self.columns == 1) {
        BOOL rtl = self.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
        self.tile.frame = CGRectMake(rtl ? width - 44 : 0, 0, 44, height);
        self.symbolView.frame = CGRectMake(8, (height - 28) / 2, 28, 28);
        self.nameLabel.frame = CGRectMake(rtl ? 30 : 56, 0, MAX(0, width - 86), height);
        self.checkmark.frame = CGRectMake(rtl ? 0 : width - 20, (height - 20) / 2, 20, 20);
        self.separator.frame = CGRectMake(rtl ? 0 : 56, height - 0.5, MAX(0, width - 56), 0.5);
    } else {
        CGFloat tileHeight = self.columns == 2 ? 76 : 64;
        self.tile.frame = CGRectMake(0, 0, width, tileHeight);
        self.symbolView.frame = CGRectMake(12, 12, MAX(0, width - 24), tileHeight - 24);
        self.nameLabel.frame = CGRectMake(0, tileHeight + 8, width, MAX(0, height - tileHeight - 8));
        self.checkmark.frame = CGRectMake(width - 24, 5, 19, 19);
    }
}

@end

@interface DXPSFSymbolPickerController () <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate,
    UICollectionViewDataSource, UICollectionViewDelegateFlowLayout>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) UISegmentedControl *columnControl;
@property (nonatomic, strong) UICollectionView *collection;
@property (nonatomic, assign) NSInteger columnCount;
@property (nonatomic, assign) CGFloat collectionWidth;
@property (nonatomic, copy) NSArray<DXPSFSymbolCategory *> *categories;
// A category child shares the library's selection callback and closes both
// levels when selected. Cancelling the child returns to the category list.
@property (nonatomic, strong) DXPSFSymbolCategory *category;
@property (nonatomic, weak) DXPSFSymbolPickerController *libraryController;
// Search always starts from the complete, validated local catalog.
@property (nonatomic, copy) NSArray<NSString *> *allSymbols;
@property (nonatomic, copy) NSArray<NSString *> *symbols;
@property (nonatomic, assign) NSUInteger loadGeneration;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, assign) BOOL selectionFinished;
@property (nonatomic, assign) BOOL pushingCategory;
@property (nonatomic, assign) NSTimeInterval loadStarted;
@end

@implementation DXPSFSymbolPickerController

- (void)viewDidLoad {
    [super viewDidLoad];
    tweakBundle = [NSBundle bundleWithPath:bundlePath];
    [tweakBundle load];
    self.title = self.category ? DXPSymbolCategoryTitle(self.category) : LOCALIZED(@"SF_SYMBOL_PICKER_TITLE");
    self.categories = self.category ? @[] : (DXPAvailableSymbolCategories ?: @[]);
    self.allSymbols = self.category ? self.category.symbolNames : (self.categories.firstObject.symbolNames ?: @[]);
    self.symbols = self.allSymbols;
    if (self.category) {
        [self setupSymbolCollection];
    } else {
        [self setupLibraryPage];
    }
    [self setupSearchController];
    [self refreshBackground];
    NSLog(@"[MUBX][SFSymbol] picker open category=%@ rows=%lu", self.category.identifier ?: @"library",
          (unsigned long)(self.category ? self.symbols.count : self.categories.count));
}

- (void)setupSymbolGrid {
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    self.collection = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    self.collection.translatesAutoresizingMaskIntoConstraints = NO;
    self.collection.backgroundColor = UIColor.systemBackgroundColor;
    self.collection.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.collection.alwaysBounceVertical = YES;
    self.collection.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.collection.dataSource = self;
    self.collection.delegate = self;
    [self.collection registerClass:DXPSFSymbolCell.class forCellWithReuseIdentifier:@"DXPSFSymbolCell"];
}

// 搜索框内嵌导航栏（与 MUBX 首页同款挂载，同导航栈设备长期验证）：裸
// UISearchBar 直接挂 PSViewController.view 在设置进程不响应点击（4.0.7 起两页
// 皆然），文本回调仍走 UISearchBarDelegate，不引入 resultsUpdater。
- (void)setupSearchController {
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchBar.delegate = self;
    search.searchBar.placeholder = LOCALIZED(@"SF_SYMBOL_SEARCH");
    search.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    search.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    search.obscuresBackgroundDuringPresentation = NO;
    search.hidesNavigationBarDuringPresentation = NO;
    search.definesPresentationContext = YES;
    self.definesPresentationContext = YES;
    self.navigationItem.searchController = search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.searchController = search;
}

// Library home: search on the whole catalog in place — a non-empty query swaps
// the category list for a full-library result grid, clearing restores the list.
- (void)setupLibraryPage {
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.columnCount = DXPPreferredSymbolColumns;
    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.table.translatesAutoresizingMaskIntoConstraints = NO;
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = 56;
    self.table.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:self.table];
    [self setupSymbolGrid];
    self.collection.hidden = YES;
    [self.view addSubview:self.collection];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    // Let UIKit track docked/search keyboards without notification ownership.
    NSLayoutConstraint *tableBottom = [self.table.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor];
    NSLayoutConstraint *gridBottom = [self.collection.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor];
    tableBottom.priority = UILayoutPriorityDefaultHigh;
    gridBottom.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [self.table.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [self.table.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.table.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        tableBottom,
        [self.collection.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [self.collection.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.collection.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        gridBottom,
        [self.table.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
        [self.collection.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
    ]];
}

- (void)setupSymbolCollection {
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.columnCount = DXPPreferredSymbolColumns;
    self.columnControl = [[UISegmentedControl alloc] initWithItems:@[
        LOCALIZED(@"SF_SYMBOL_COLUMNS_ONE"), LOCALIZED(@"SF_SYMBOL_COLUMNS_TWO"),
        LOCALIZED(@"SF_SYMBOL_COLUMNS_THREE"), LOCALIZED(@"SF_SYMBOL_COLUMNS_FOUR")]];
    self.columnControl.translatesAutoresizingMaskIntoConstraints = NO;
    self.columnControl.selectedSegmentIndex = self.columnCount - 1;
    [self.columnControl addTarget:self action:@selector(columnsChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.columnControl];
    [self setupSymbolGrid];
    [self.view addSubview:self.collection];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    // Let UIKit track docked/search keyboards without notification ownership.
    NSLayoutConstraint *bottom = [self.collection.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor];
    bottom.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [self.columnControl.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [self.columnControl.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [self.columnControl.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [self.columnControl.heightAnchor constraintEqualToConstant:32],
        [self.collection.topAnchor constraintEqualToAnchor:self.columnControl.bottomAnchor constant:12],
        [self.collection.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.collection.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        bottom,
        [self.collection.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
    ]];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat width = CGRectGetWidth(self.collection.bounds);
    if (width != self.collectionWidth) {
        self.collectionWidth = width;
        [self.collection.collectionViewLayout invalidateLayout];
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (![previousTraitCollection.preferredContentSizeCategory isEqualToString:self.traitCollection.preferredContentSizeCategory]) {
        [self.collection.collectionViewLayout invalidateLayout];
        [self.collection reloadData];
    }
}

- (void)columnsChanged:(UISegmentedControl *)control {
    NSInteger columns = control.selectedSegmentIndex + 1;
    if (columns < 1 || columns > 4 || columns == self.columnCount) return;
    // Preserve the first visible symbol, including while searching.
    NSArray<NSIndexPath *> *visible = [self.collection.indexPathsForVisibleItems sortedArrayUsingSelector:@selector(compare:)];
    NSIndexPath *anchor = visible.firstObject;
    self.columnCount = columns;
    DXPPreferredSymbolColumns = columns;
    [self.collection.collectionViewLayout invalidateLayout];
    [self.collection reloadData];
    [self.collection layoutIfNeeded];
    if (anchor && anchor.item < (NSInteger)self.symbols.count) {
        [self.collection scrollToItemAtIndexPath:anchor atScrollPosition:UICollectionViewScrollPositionTop animated:NO];
    }
    NSLog(@"[MUBX][SFSymbol] layout category=%@ columns=%ld rows=%lu", self.category.identifier,
          (long)columns, (unsigned long)self.symbols.count);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.selectionFinished = NO;
    self.pushingCategory = NO;
    // The home grid has no column control of its own; follow switches made in
    // a category page so a kept-alive search shows the chosen density.
    if (!self.category && self.columnCount != DXPPreferredSymbolColumns) {
        self.columnCount = DXPPreferredSymbolColumns;
        if (!self.collection.hidden) [self.collection reloadData];
    }
    if (!self.category && !self.categories.count && !self.loading) [self loadSymbolCatalog];
    else [self refreshBackground];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    self.searchController.active = NO;
    self.loadGeneration++;
    self.loading = NO;
}

- (void)loadSymbolCatalog {
    if (self.category || self.loading) return;
    self.loading = YES;
    self.loadStarted = [NSDate timeIntervalSinceReferenceDate];
    NSUInteger generation = ++self.loadGeneration;
    self.navigationItem.rightBarButtonItem.enabled = NO;
    [self.table reloadData];
    [self refreshBackground];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSArray<NSString *> *sources = nil;
            NSArray<NSString *> *candidates = [DXPSFSymbolCatalog
                namesFromResourceDirectories:[DXPSFSymbolCatalog systemResourceDirectories] sourcePaths:&sources];
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(weakSelf) owner = weakSelf;
                if (!owner || !owner.loading || generation != owner.loadGeneration) return;
                NSLog(@"[MUBX][SFSymbol] catalog sources=%@ candidates=%lu", sources,
                      (unsigned long)candidates.count);
                [owner validateCandidates:candidates offset:0 available:[NSMutableArray array] generation:generation];
            });
        }
    });
}

- (void)validateCandidates:(NSArray<NSString *> *)candidates offset:(NSUInteger)offset
                 available:(NSMutableArray<NSString *> *)available generation:(NSUInteger)generation {
    if (!self.loading || generation != self.loadGeneration) return;
    // Yield between batches so catalog validation does not block navigation.
    NSTimeInterval started = [NSDate timeIntervalSinceReferenceDate];
    NSUInteger limit = MIN(offset + 32, candidates.count);
    while (offset < limit) {
        @autoreleasepool {
            NSString *name = candidates[offset++];
            if ([UIImage systemImageNamed:name]) [available addObject:name];
        }
        if ([NSDate timeIntervalSinceReferenceDate] - started >= 0.004) break;
    }
    if (offset == candidates.count) {
        self.allSymbols = available;
        NSArray<NSString *> *validNames = self.allSymbols;
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @autoreleasepool {
                NSArray<NSString *> *sources = nil;
                NSArray<DXPSFSymbolCategory *> *categories = [DXPSFSymbolCatalog
                    categoriesFromResourceDirectories:[DXPSFSymbolCatalog systemResourceDirectories]
                    availableNames:validNames sourcePaths:&sources];
                dispatch_async(dispatch_get_main_queue(), ^{
                    typeof(weakSelf) owner = weakSelf;
                    if (!owner || !owner.loading || generation != owner.loadGeneration) return;
                    owner.loading = NO;
                    owner.categories = categories;
                    // An All-only result stays usable but must not cache a
                    // failed category read for the lifetime of Preferences.
                    DXPAvailableSymbolCategories = categories.count > 1 ? categories : nil;
                    [owner.table reloadData];
                    // A home search may be waiting on the catalog results.
                    [owner.collection reloadData];
                    [owner refreshBackground];
                    NSLog(@"[MUBX][SFSymbol] catalog ready available=%lu candidates=%lu categories=%lu sources=%@ elapsed=%.3f",
                          (unsigned long)validNames.count, (unsigned long)candidates.count,
                          (unsigned long)categories.count, sources,
                          [NSDate timeIntervalSinceReferenceDate] - owner.loadStarted);
                });
            }
        });
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [weakSelf validateCandidates:candidates offset:offset available:available generation:generation];
    });
}

// Home is in search mode while the hidden-state flag on the grid is lifted;
// the flag is the single source of truth for empty-state placement too.
- (BOOL)librarySearchActive {
    return !self.category && self.collection && !self.collection.hidden;
}

- (void)refreshBackground {
    if (!self.category) {
        self.navigationItem.rightBarButtonItem = (!self.loading && self.allSymbols.count && self.categories.count == 1)
            ? [[UIBarButtonItem alloc] initWithTitle:LOCALIZED(@"SF_SYMBOL_RETRY") style:UIBarButtonItemStylePlain
                target:self action:@selector(loadSymbolCatalog)] : nil;
    }
    BOOL searching = self.librarySearchActive;
    if (self.category ? self.symbols.count : (searching ? self.symbols.count : self.categories.count)) {
        self.table.backgroundView = nil;
        self.collection.backgroundView = nil;
        return;
    }
    UIView *background = [[UIView alloc] initWithFrame:(self.category || searching) ? self.collection.bounds : self.table.bounds];
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [background addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:background.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:background.centerYAnchor],
        [stack.widthAnchor constraintLessThanOrEqualToAnchor:background.widthAnchor constant:-40],
    ]];
    if (self.loading) {
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [spinner startAnimating];
        [stack addArrangedSubview:spinner];
    }
    UILabel *message = [[UILabel alloc] init];
    message.font = [UIFont systemFontOfSize:15];
    message.textColor = UIColor.secondaryLabelColor;
    message.textAlignment = NSTextAlignmentCenter;
    message.numberOfLines = 0;
    message.text = self.loading ? LOCALIZED(@"SF_SYMBOL_LOADING") :
        ((self.category || searching) ? LOCALIZED(@"SF_SYMBOL_NO_RESULTS") : LOCALIZED(@"SF_SYMBOL_LOAD_FAILED"));
    [stack addArrangedSubview:message];
    if (!self.category && !self.loading && !self.allSymbols.count) {
        UIButton *retry = [UIButton buttonWithType:UIButtonTypeSystem];
        [retry setTitle:LOCALIZED(@"SF_SYMBOL_RETRY") forState:UIControlStateNormal];
        [retry addTarget:self action:@selector(loadSymbolCatalog) forControlEvents:UIControlEventTouchUpInside];
        [stack addArrangedSubview:retry];
    }
    if (self.category || searching) self.collection.backgroundView = background;
    else self.table.backgroundView = background;
}

- (void)filterWithQuery:(NSString *)query {
    query = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSPredicate *matcher = [NSPredicate predicateWithFormat:@"self CONTAINS[cd] %@", query];
    if (self.category) {
        self.symbols = query.length ? [self.allSymbols filteredArrayUsingPredicate:matcher] : self.allSymbols;
        [self.collection reloadData];
        [self.collection setContentOffset:CGPointZero animated:NO];
        [self refreshBackground];
        return;
    }
    // Library home: a non-empty query swaps the category list for the
    // whole-catalog result grid; clearing restores the list.
    BOOL searching = query.length > 0;
    self.symbols = searching ? [self.allSymbols filteredArrayUsingPredicate:matcher] : @[];
    self.table.hidden = searching;
    self.collection.hidden = !searching;
    self.table.backgroundView = nil;
    [self.collection reloadData];
    [self.collection setContentOffset:CGPointZero animated:NO];
    [self refreshBackground];
    NSLog(@"[MUBX][SFSymbol] library search length=%lu results=%lu",
          (unsigned long)query.length, (unsigned long)self.symbols.count);
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    [self filterWithQuery:searchText ?: @""];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

// 取消/失活后按最终文本重算一次：恢复分类列表或保留查询，不依赖系统在
// 取消时是否清空文本的行为差异。
- (void)didDismissSearchController:(UISearchController *)searchController {
    [self filterWithQuery:searchController.searchBar.text ?: @""];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return self.categories.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return (!self.category && !self.loading && self.categories.count == 1)
        ? LOCALIZED(@"SF_SYMBOL_CATEGORIES_UNAVAILABLE") : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"DXPSFSymbolCategoryCell"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"DXPSFSymbolCategoryCell"];
    DXPSFSymbolCategory *category = self.categories[indexPath.row];
    cell.textLabel.text = DXPSymbolCategoryTitle(category);
    cell.textLabel.font = [UIFont systemFontOfSize:17];
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.text = @(category.symbolNames.count).stringValue;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.imageView.image = category.iconName.length ? [UIImage systemImageNamed:category.iconName
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:23 weight:UIImageSymbolWeightRegular]] : nil;
    cell.imageView.tintColor = UIColor.labelColor;
    cell.imageView.contentMode = UIViewContentModeScaleAspectFit;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)self.categories.count) return;
    if (self.pushingCategory) return;
    self.pushingCategory = YES;
    DXPSFSymbolPickerController *picker = [[DXPSFSymbolPickerController alloc] init];
    picker.category = self.categories[indexPath.row];
    picker.libraryController = self;
    picker.selectedSymbolName = self.selectedSymbolName;
    picker.completion = self.completion;
    [picker setRootController:[self rootController]];
    [picker setParentController:[self parentController]];
    [self pushController:picker];
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    (void)collectionView; (void)section;
    return self.symbols.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    DXPSFSymbolCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"DXPSFSymbolCell" forIndexPath:indexPath];
    NSString *name = self.symbols[indexPath.item];
    [cell configureWithName:name columns:self.columnCount checked:[name isEqualToString:self.selectedSymbolName]];
    return cell;
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout
    sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    (void)layout; (void)indexPath;
    BOOL list = self.columnCount == 1;
    CGFloat spacing = list ? 0 : 12;
    CGFloat width = MAX(1, floor((CGRectGetWidth(collectionView.bounds) - 32 - spacing * (self.columnCount - 1)) / self.columnCount));
    UIFont *font = [[UIFontMetrics metricsForTextStyle:(list ? UIFontTextStyleBody : UIFontTextStyleFootnote)]
        scaledFontForFont:[UIFont systemFontOfSize:(list ? 15 : 12)]];
    CGFloat height = list ? MAX(56, ceil(font.lineHeight) + 24)
        : (self.columnCount == 2 ? 76 : 64) + 8 + ceil(font.lineHeight) * 2;
    return CGSizeMake(width, height);
}

- (UIEdgeInsets)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout
    insetForSectionAtIndex:(NSInteger)section {
    (void)collectionView; (void)layout; (void)section;
    return UIEdgeInsetsMake(8, 16, 16, 16);
}

- (CGFloat)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout
    minimumInteritemSpacingForSectionAtIndex:(NSInteger)section {
    (void)collectionView; (void)layout; (void)section;
    return self.columnCount == 1 ? 0 : 12;
}

- (CGFloat)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout
    minimumLineSpacingForSectionAtIndex:(NSInteger)section {
    (void)collectionView; (void)layout; (void)section;
    return self.columnCount == 1 ? 0 : 16;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [collectionView deselectItemAtIndexPath:indexPath animated:YES];
    if (indexPath.item < 0 || indexPath.item >= (NSInteger)self.symbols.count) return;
    // A category child hands the callback to the library level; on the home
    // page the picker itself is the library and closes in one pop.
    DXPSFSymbolPickerController *library = self.category ? self.libraryController : self;
    if (!library || self.selectionFinished || library.selectionFinished) return;
    NSString *name = self.symbols[indexPath.item];
    // Cached names can outlive an external symbol hook's configuration.
    if (![UIImage systemImageNamed:name]) {
        DXPAvailableSymbolCategories = nil;
        library.categories = @[];
        // Dropping the library's own cache is the child's job; on home it
        // would wipe allSymbols before the removal below can copy from it.
        if (library != self) library.allSymbols = @[];
        NSMutableArray *remaining = [self.allSymbols mutableCopy];
        [remaining removeObject:name];
        self.allSymbols = remaining;
        [self filterWithQuery:self.searchController.searchBar.text ?: @""];
        // Home has no parent to fall back on: rebuild catalog and categories
        // right away so clearing the query cannot strand an empty list.
        if (!self.category && !self.loading) [self loadSymbolCatalog];
        NSLog(@"[MUBX][SFSymbol] selection unavailable name=%@", name);
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:self.title
            message:LOCALIZED(@"SF_SYMBOL_UNAVAILABLE") preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:LOCALIZED(@"ANSWER_OK")
            style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    self.selectionFinished = YES;
    library.selectionFinished = YES;
    library.selectedSymbolName = name;
    UINavigationController *navigation = self.navigationController;
    NSArray<UIViewController *> *controllers = navigation.viewControllers;
    NSUInteger libraryIndex = [controllers indexOfObjectIdenticalTo:library];
    UIViewController *returnController = (libraryIndex != NSNotFound && libraryIndex > 0) ? controllers[libraryIndex - 1] : nil;
    NSLog(@"[MUBX][SFSymbol] picked name=%@ completion=%d", name, self.completion != nil);
    if (self.completion) self.completion(name);
    if (returnController && [navigation.viewControllers containsObject:returnController]) {
        [navigation popToViewController:returnController animated:YES];
    } else {
        NSLog(@"[MUBX][SFSymbol] return controller unavailable");
        [navigation popViewControllerAnimated:YES];
    }
}

@end
