#import "DXPActionOrganizationController.h"
#import "DXPActionGroups.h"
#import "DXPLinkActionEditorController.h"
#import "../DXPrefsManager.h"

static NSString *DXOrgText(NSString *key) {
    return [[NSBundle bundleWithPath:bundlePath] localizedStringForKey:key value:key table:nil] ?: key;
}

@interface DXPActionOrganizationController ()
@property(nonatomic, strong) UISearchController *groupSearch;
@property(nonatomic, copy) NSArray<NSString *> *visibleGroups;
@end

@implementation DXPActionOrganizationController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = DXOrgText(self.managesGroups ? @"ACTION_GROUP_MANAGER" : @"ACTION_GROUP");
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"Group"];
    self.groupSearch = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.groupSearch.searchResultsUpdater = self;
    self.groupSearch.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = self.groupSearch;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    UIBarButtonItem *add = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(createGroup)];
    if (self.managesGroups)
        self.navigationItem.rightBarButtonItems = @[add, self.editButtonItem];
    else self.navigationItem.rightBarButtonItem = add;
    [self reloadGroups];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setToolbarHidden:YES animated:animated];
    [self reloadGroups];
}
- (void)reloadGroups {
    if (self.managesGroups) {
        NSDictionary *prefs = [DXPrefsManager.sharedInstance readPrefs];
        self.groups = DXActionGroupNames(prefs, DXActionMutableDefinitions(prefs));
    }
    [self updateSearchResultsForSearchController:self.groupSearch];
}
- (void)updateSearchResultsForSearchController:(UISearchController *)controller {
    NSString *query = controller.searchBar.text ?: @"";
    NSMutableArray *visible = [NSMutableArray array];
    for (NSString *group in self.groups ?: @[])
        if (!query.length || [group localizedCaseInsensitiveContainsString:query]) [visible addObject:group];
    self.visibleGroups = visible;
    if (query.length && self.tableView.editing) [self setEditing:NO animated:YES];
    [self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.visibleGroups.count + (self.managesGroups ? 0 : 1);
}
- (NSString *)groupAtPath:(NSIndexPath *)path {
    NSInteger row = path.row - (self.managesGroups ? 0 : 1);
    return row >= 0 && row < (NSInteger)self.visibleGroups.count ? self.visibleGroups[row] : @"";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Group" forIndexPath:path];
    NSString *group = [self groupAtPath:path];
    cell.textLabel.text = group.length ? group : DXOrgText(@"UNGROUPED");
    cell.imageView.image = [UIImage systemImageNamed:@"folder"];
    cell.accessoryType = self.managesGroups ? UITableViewCellAccessoryDisclosureIndicator :
        ([group isEqual:self.selectedGroup ?: @""] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone);
    return cell;
}
- (void)finishWithGroup:(NSString *)group created:(BOOL)created {
    if (self.navigationController.viewControllers.lastObject != self) return;
    void (^completion)(NSString *, BOOL) = self.completion;
    self.completion = nil;
    // A batch-add caller immediately pushes the app picker. Complete the pop
    // synchronously so the two navigation transitions cannot overlap.
    [self.navigationController popViewControllerAnimated:NO];
    if (completion) completion(group, created);
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    if (path.row < 0 || path.row >= (NSInteger)self.visibleGroups.count + (self.managesGroups ? 0 : 1)) return;
    [tableView deselectRowAtIndexPath:path animated:YES];
    NSString *name = [self groupAtPath:path];
    if (!self.managesGroups) { [self finishWithGroup:name created:NO]; return; }
    if (!name.length) return;
    __weak typeof(self) weakSelf = self;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:name message:nil preferredStyle:UIAlertControllerStyleAlert];
    [menu addAction:[UIAlertAction actionWithTitle:DXOrgText(@"RENAME_GROUP") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf requestNameForGroup:name];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:DXOrgText(@"DELETE_GROUP") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [weakSelf confirmDeleteGroup:name];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:DXOrgText(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:menu animated:YES completion:nil];
}
- (void)createGroup { [self requestNameForGroup:nil]; }
- (void)requestNameForGroup:(NSString *)old {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:DXOrgText(old ? @"RENAME_GROUP" : @"NEW_GROUP")
        message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.text = old; field.placeholder = DXOrgText(@"GROUP_NAME"); }];
    __weak typeof(self) weakSelf = self;
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:DXOrgText(@"SAVE") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) owner = weakSelf;
        if (!owner) return;
        NSString *raw = [weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *name = DXActionGroupNormalizedName(raw);
        if (!name.length || raw.length > 32) { [owner showError:@"ACTION_GROUP_NAME_INVALID"]; return; }
        if ([name isEqual:old]) return;
        NSMutableDictionary *prefs = [[DXPrefsManager.sharedInstance readPrefs] mutableCopy] ?: [NSMutableDictionary dictionary];
        NSArray *groups = owner.managesGroups ? DXActionGroupNames(prefs, DXActionMutableDefinitions(prefs)) : owner.groups;
        if ([groups containsObject:name]) { [owner showError:@"GROUP_EXISTS"]; return; }
        if (!owner.managesGroups) { [owner finishWithGroup:name created:YES]; return; }
        if (old) {
            if (!DXActionChangeGroup(prefs, old, name)) { [owner reloadGroups]; return; }
        } else prefs[kLinkActionGroupsKey] = [groups arrayByAddingObject:name];
        [DXPrefsManager.sharedInstance writePrefs:prefs];
        [owner reloadGroups];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:DXOrgText(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)showError:(NSString *)key {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:DXOrgText(key) preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:DXOrgText(@"ANSWER_OK") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)confirmDeleteGroup:(NSString *)name {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:DXOrgText(@"DELETE_GROUP")
        message:[NSString stringWithFormat:DXOrgText(@"DELETE_GROUP_CONFIRM"), name] preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:DXOrgText(@"DELETE") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        NSMutableDictionary *prefs = [[DXPrefsManager.sharedInstance readPrefs] mutableCopy] ?: [NSMutableDictionary dictionary];
        if (DXActionChangeGroup(prefs, name, @"")) [DXPrefsManager.sharedInstance writePrefs:prefs];
        [weakSelf reloadGroups];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:DXOrgText(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)path {
    return self.managesGroups && !self.groupSearch.searchBar.text.length;
}
- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)path {
    return UITableViewCellEditingStyleNone;
}
- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)path {
    return [self tableView:tableView canEditRowAtIndexPath:path];
}
- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)source toIndexPath:(NSIndexPath *)destination {
    NSString *moving = [self groupAtPath:source], *target = [self groupAtPath:destination];
    NSMutableDictionary *prefs = [[DXPrefsManager.sharedInstance readPrefs] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableArray *names = [DXActionGroupNames(prefs, DXActionMutableDefinitions(prefs)) mutableCopy];
    NSUInteger from = [names indexOfObject:moving], to = [names indexOfObject:target];
    if (from != NSNotFound && to != NSNotFound) {
        [names removeObjectAtIndex:from];
        [names insertObject:moving atIndex:to];
        prefs[kLinkActionGroupsKey] = names;
        [DXPrefsManager.sharedInstance writePrefs:prefs];
    }
    [self reloadGroups];
}
@end

void DXPPresentActionGroupChooser(UIViewController *controller, NSArray<NSString *> *groups,
    NSString *selected, void (^completion)(NSString *, BOOL)) {
    DXPActionOrganizationController *picker = [DXPActionOrganizationController new];
    picker.groups = groups ?: @[];
    picker.selectedGroup = selected;
    picker.completion = completion;
    [controller.navigationController pushViewController:picker animated:YES];
}

void DXPPresentActionTypeFilter(UIViewController *controller, NSString *current, void (^completion)(NSString *)) {
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:DXOrgText(@"ACTION_TYPE_FILTER") message:nil preferredStyle:UIAlertControllerStyleAlert];
    for (NSString *type in @[@"", @"openapp", @"urlscheme", @"shortcut", @"text", @"system", @"javascript", @"url"]) {
        NSString *title = type.length ? ([DXPLinkActionEditorController displayNameForType:type] ?: type) : DXOrgText(@"ACTION_ALL_TYPES");
        if ([type isEqual:current ?: @""]) title = [@"✓ " stringByAppendingString:title];
        [menu addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            if (completion) completion(type);
        }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:DXOrgText(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [controller presentViewController:menu animated:YES completion:nil];
}
