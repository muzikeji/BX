#import "DXPAppShortcutPickerController.h"
#import "DXPAppInfo.h"
#import "../common.h"
#import <notify.h>

static NSBundle *tweakBundle;

@interface DXPShortcutCell : UITableViewCell
@end
@implementation DXPShortcutCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    return [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
}
@end

@interface DXPAppShortcutPickerController () <UITableViewDelegate, UITableViewDataSource, UISearchResultsUpdating>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, copy) NSArray<NSDictionary *> *groups;
@property (nonatomic, copy) NSArray<NSDictionary *> *visibleGroups;
@property (nonatomic, strong) dispatch_queue_t readerQueue;
@property (nonatomic, assign) NSUInteger generation;
@property (nonatomic, assign) BOOL active;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, assign) BOOL refreshFailed;
@property (nonatomic, assign) int notificationToken;
@end

@implementation DXPAppShortcutPickerController

- (instancetype)init {
    if ((self = [super init])) _notificationToken = NOTIFY_TOKEN_INVALID;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    tweakBundle = [NSBundle bundleWithPath:bundlePath];
    self.title = LOCALIZED(@"SELECT_SHORTCUT");
    self.groups = @[];
    self.visibleGroups = @[];
    self.readerQueue = dispatch_queue_create("com.lindo.mubx.shortcut.picker", DISPATCH_QUEUE_SERIAL);
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.rowHeight = 60;
    [self.tableView registerClass:DXPShortcutCell.class forCellReuseIdentifier:@"Shortcut"];
    self.tableView.refreshControl = [UIRefreshControl new];
    [self.tableView.refreshControl addTarget:self action:@selector(refreshCatalogue) forControlEvents:UIControlEventValueChanged];
    self.view = self.tableView;
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = LOCALIZED(@"SEARCH");
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.active = YES;
    if (self.notificationToken == NOTIFY_TOKEN_INVALID) {
        __weak typeof(self) weakSelf = self;
        int token = NOTIFY_TOKEN_INVALID;
        uint32_t status = notify_register_dispatch(kShortcutSnapshotChangedIdentifier.UTF8String, &token,
            dispatch_get_main_queue(), ^(int unused) {
                typeof(self) view = weakSelf;
                if (view.active) [view loadGroupsRequestingRefresh:NO];
            });
        if (status == NOTIFY_STATUS_OK) self.notificationToken = token;
    }
    [self refreshCatalogue];
}

- (void)stopObserving {
    if (self.notificationToken != NOTIFY_TOKEN_INVALID) {
        notify_cancel(self.notificationToken);
        self.notificationToken = NOTIFY_TOKEN_INVALID;
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    self.active = NO;
    self.generation++;
    [self stopObserving];
    [self.tableView.refreshControl endRefreshing];
}

- (void)dealloc { [self stopObserving]; }

- (void)refreshCatalogue { [self loadGroupsRequestingRefresh:YES]; }

- (void)loadGroupsRequestingRefresh:(BOOL)refresh {
    NSUInteger generation = ++self.generation;
    self.loading = YES;
    [self applySearch];
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.readerQueue, ^{
        @autoreleasepool {
            NSArray *groups = [DXPAppInfo appShortcutGroups];
            BOOL requested = !refresh || [DXPAppInfo requestShortcutSnapshotRefresh];
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) view = weakSelf;
                if (!view.active || generation != view.generation) return;
                view.groups = groups;
                view.loading = NO;
                view.refreshFailed = !requested;
                [view.tableView.refreshControl endRefreshing];
                [view applySearch];
            });
        }
    });
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController { [self applySearch]; }

- (void)applySearch {
    NSString *query = [self.searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray *visible = [NSMutableArray array];
    for (NSDictionary *group in self.groups) {
        if (!DXIsValidBundleIdentifier(group[@"bundleID"])) continue;
        BOOL matchesApp = !query.length || [group[@"name"] localizedCaseInsensitiveContainsString:query] ||
            [group[@"bundleID"] localizedCaseInsensitiveContainsString:query];
        NSMutableArray *items = [NSMutableArray array];
        for (DXPAppShortcutItem *item in group[@"items"]) {
            if (!DXIsValidAppShortcutType(item.type)) continue;
            if (matchesApp || [item.title localizedCaseInsensitiveContainsString:query] ||
                [item.subtitle localizedCaseInsensitiveContainsString:query] || [item.type localizedCaseInsensitiveContainsString:query]) {
                [items addObject:item];
            }
        }
        if (items.count) [visible addObject:@{@"name": group[@"name"], @"bundleID": group[@"bundleID"], @"items": items}];
    }
    self.visibleGroups = visible;
    [self.tableView reloadData];
    if (visible.count) {
        self.tableView.backgroundView = nil;
    } else {
        UILabel *label = [[UILabel alloc] initWithFrame:self.tableView.bounds];
        label.numberOfLines = 0;
        label.textAlignment = NSTextAlignmentCenter;
        label.textColor = UIColor.secondaryLabelColor;
        label.font = [UIFont systemFontOfSize:15];
        label.text = self.loading ? LOCALIZED(@"SHORTCUTS_LOADING") :
            (query.length ? LOCALIZED(@"SHORTCUTS_NO_MATCHES") :
            (self.refreshFailed ? LOCALIZED(@"SHORTCUTS_REFRESH_FAILED") : LOCALIZED(@"NO_APP_SHORTCUTS")));
        self.tableView.backgroundView = label;
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return self.visibleGroups.count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self.visibleGroups[section][@"items"] count];
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.visibleGroups[section][@"name"];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Shortcut" forIndexPath:indexPath];
    NSDictionary *group = self.visibleGroups[indexPath.section];
    DXPAppShortcutItem *item = group[@"items"][indexPath.row];
    cell.textLabel.text = item.title;
    cell.detailTextLabel.text = item.subtitle.length ? item.subtitle : group[@"name"];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.imageView.image = [DXPAppInfo iconForBundleID:group[@"bundleID"]];
    cell.accessoryType = [group[@"bundleID"] isEqualToString:self.selectedBundleIdentifier] &&
        [item.type isEqualToString:self.selectedShortcutType] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!self.active || indexPath.section >= (NSInteger)self.visibleGroups.count) return;
    NSDictionary *group = self.visibleGroups[indexPath.section];
    if (indexPath.row >= (NSInteger)[group[@"items"] count]) return;
    DXPAppShortcutItem *item = group[@"items"][indexPath.row];
    self.active = NO; // Ignore another tap while the navigation transition runs.
    if (self.completion) self.completion(group[@"bundleID"], group[@"name"], item);
    self.searchController.active = NO;
    [self.navigationController popViewControllerAnimated:YES];
}
@end
