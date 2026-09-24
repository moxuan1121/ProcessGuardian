/**
 * MCProcessListViewController.m —— 进程列表页。
 *
 * 这一页承担原面板「根页面内联进程行」的职责，但用普通 tableView 实现：
 * PreferenceLoader 要在静态 plist 之后插入动态行，得靠未文档化的 specifier 构造，
 * 换页面自己画表格更稳，功能一项没少。
 */
#import "MCPrefsClasses.h"

@interface MCProcessListViewController ()
@property (nonatomic, strong) NSArray<NSString *> *keys;
@property (nonatomic, strong) NSArray<NSString *> *filteredKeys;
@property (nonatomic, strong) UISearchController *search;
@end

@implementation MCProcessListViewController

- (NSDictionary<NSString *, NSDictionary *> *)allConfigs {
    id apps = [MCPrefs readPrefs][@"AppConfigs"];
    return [apps isKindOfClass:[NSDictionary class]] ? apps : @{};
}

- (NSArray<NSString *> *)sortedKeys:(NSDictionary *)apps {
    MCListSortMode mode = (MCListSortMode)[[MCPrefs readPrefs][@"SortMode"] integerValue];
    NSMutableArray *keys = [apps.allKeys mutableCopy];

    if (mode == MCListSortByNice) {
        [keys sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            NSInteger x = [apps[a][@"NiceValue"] integerValue];
            NSInteger y = [apps[b][@"NiceValue"] integerValue];
            /* nice 越小优先级越高，所以升序就是「优先级高到低」。 */
            return x == y ? NSOrderedSame : (x < y ? NSOrderedAscending : NSOrderedDescending);
        }];
    } else if (mode == MCListSortByJetsam) {
        [keys sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            NSInteger x = [apps[a][@"JetsamPriority"] integerValue];
            NSInteger y = [apps[b][@"JetsamPriority"] integerValue];
            return x == y ? NSOrderedSame : (x > y ? NSOrderedAscending : NSOrderedDescending);
        }];
    } else {
        [keys sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    }
    return keys;
}

- (NSString *)titleFor:(NSString *)key config:(NSDictionary *)cfg {
    NSString *remark = cfg[@"Remark"];
    return [remark isKindOfClass:[NSString class]] && remark.length ? remark : key;
}

- (void)reload {
    NSDictionary *apps = [self allConfigs];
    self.keys = [self sortedKeys:apps];

    NSString *q = self.search.searchBar.text.lowercaseString;
    if (q.length) {
        self.filteredKeys = [self.keys filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(NSString *k, NSDictionary *b) {
                NSDictionary *cfg = apps[k] ?: @{};
                return [[self titleFor:k config:cfg].lowercaseString containsString:q]
                       || [k.lowercaseString containsString:q];
            }]];
    } else {
        self.filteredKeys = self.keys;
    }
    [self.tableView reloadData];
}

- (NSArray<NSString *> *)visibleKeys { return self.filteredKeys ?: self.keys; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"进程列表";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 62;
    [self.tableView registerClass:[MCAppProcessCell class] forCellReuseIdentifier:@"MCAppProcessCell"];

    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.delegate = self;
    self.search.searchBar.placeholder = @"搜索进程或备注";
    self.tableView.tableHeaderView = self.search.searchBar;

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self action:@selector(addProcess)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)addProcess {
    MCProcessEditViewController *edit = [MCProcessEditViewController new];
    edit.creating = YES;
    [self.navigationController pushViewController:edit animated:YES];
}

/* ------------------------------------------------------------------ 数据源 */

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.visibleKeys.count; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)path {
    MCAppProcessCell *c = [tv dequeueReusableCellWithIdentifier:@"MCAppProcessCell" forIndexPath:path];
    NSString *key = self.visibleKeys[path.row];
    NSDictionary *cfg = [self allConfigs][key] ?: @{};
    NSString *subtitle = [MCPrefs subtitleForIdentifier:key config:cfg];
    [c configureWithTitle:[self titleFor:key config:cfg]
                 subtitle:[NSString stringWithFormat:@"%@\n%@", key, subtitle]
                  running:subtitle.length > 0 && ![subtitle containsString:@"进程未运行"]];
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tv deselectRowAtIndexPath:path animated:YES];
    MCProcessEditViewController *edit = [MCProcessEditViewController new];
    edit.targetIdentifier = self.visibleKeys[path.row];
    [self.navigationController pushViewController:edit animated:YES];
}

- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)path { return YES; }

- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style
    forRowAtIndexPath:(NSIndexPath *)path {
    if (style != UITableViewCellEditingStyleDelete) return;
    NSString *key = self.visibleKeys[path.row];

    NSMutableDictionary *prefs = [MCPrefs readPrefs];
    NSMutableDictionary *apps = [prefs[@"AppConfigs"] mutableCopy];
    [apps removeObjectForKey:key];
    prefs[@"AppConfigs"] = apps;
    /* 必须叫醒守护进程：它靠「配置里没这个键了」来判断要把内核设置恢复回去。 */
    [MCPrefs writePrefs:prefs wakeDaemon:YES];

    [self reload];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)controller { [self reload]; }

@end
