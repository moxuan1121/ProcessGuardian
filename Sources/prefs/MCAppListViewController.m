/**
 * MCAppListViewController.m —— 选择要纳管的对象。
 *
 * 两条来源分开列，因为它们的匹配方式不同：已安装 App 用包名匹配（重装后依然有效），
 * 系统守护进程只能用进程名（它们根本没有 bundle id）。
 */
#import "MCPrefsClasses.h"

@interface MCAppListViewController ()
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UISegmentedControl *sourceControl;
@property (nonatomic, strong) UISearchController *search;

@property (nonatomic, strong) NSArray<NSString *> *appIds;        /* 包名，与下面按下标对齐 */
@property (nonatomic, strong) NSArray<NSString *> *appNames;
@property (nonatomic, strong) NSArray<NSString *> *processNames;

@property (nonatomic, copy) NSArray<NSString *> *visible;
@end

@implementation MCAppListViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择应用";

    [self loadData];

    self.sourceControl = [[UISegmentedControl alloc] initWithItems:@[@"应用程序", @"系统进程"]];
    self.sourceControl.selectedSegmentIndex = 0;
    [self.sourceControl addTarget:self action:@selector(sourceChanged:)
                 forControlEvents:UIControlEventValueChanged];

    /* 分段控件占标题位：这一页只有两个数据源，不值得为它单独留一行高度。 */
    self.navigationItem.titleView = self.sourceControl;

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.table.dataSource = self;
    self.table.delegate = self;
    [self.table registerClass:[MCAppProcessCell class] forCellReuseIdentifier:@"MCAppProcessCell"];
    self.table.translatesAutoresizingMaskIntoConstraints = NO;

    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.delegate = self;
    self.search.hidesSearchBarWhenScrolling = NO;
    self.search.searchBar.placeholder = @"搜索名称或包名";
    self.table.tableHeaderView = self.search.searchBar;

    UIView *tip = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 34)];
    UILabel *label = [UILabel new];
    label.frame = CGRectMake(16, 8, [UIScreen mainScreen].bounds.size.width - 32, 20);
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];
    label.textColor = [UIColor secondaryLabelColor];
    label.text = @"选择添加的进程类型：应用程序按包名识别，系统进程按进程名识别。";
    [tip addSubview:label];
    self.table.tableFooterView = tip;

    self.table.frame = self.view.bounds;
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.table];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addManually)];

    [self applyFilter];
}

- (void)loadData {
    NSDictionary *apps = [MCPrefs installedApps];
    self.appIds = [apps.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *bid in self.appIds) [names addObject:apps[bid]];
    self.appNames = names;
    self.processNames = [MCPrefs runningProcessNames];
}

- (BOOL)showingProcesses { return self.sourceControl.selectedSegmentIndex == 1; }

- (NSArray<NSString *> *)currentSource { return [self showingProcesses] ? self.processNames : self.appIds; }

- (NSString *)displayNameForIndex:(NSUInteger)i {
    if ([self showingProcesses]) return self.processNames[i];
    return self.appNames[i];
}

- (void)applyFilter {
    NSString *q = self.search.searchBar.text.lowercaseString;
    NSArray *source = [self currentSource];
    if (!q.length) { self.visible = source; [self.table reloadData]; return; }

    NSMutableArray *out = [NSMutableArray array];
    for (NSUInteger i = 0; i < source.count; i++) {
        NSString *idv = source[i];
        NSString *name = [self displayNameForIndex:i];
        if ([idv.lowercaseString containsString:q] || [name.lowercaseString containsString:q])
            [out addObject:idv];
    }
    self.visible = out;
    [self.table reloadData];
}

- (void)sourceChanged:(UISegmentedControl *)sender {
    self.title = sender.selectedSegmentIndex == 1 ? @"选择进程" : @"选择应用";
    [self applyFilter];
}

/** 直接填包名/进程名的入口，用于列表里看不到的进程（例如尚未启动的第三方 daemon）。 */
- (void)addManually {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"目标进程名 / 包名"
                                                              message:nil
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = @"com.example.app"; }];
    __weak typeof(self) ws = self;
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) {
        NSString *text = [a.textFields.firstObject.text
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        [ws pick:text];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)pick:(NSString *)identifier {
    if (identifier.length == 0) return;
    void (^block)(NSString *) = self.onPick;
    /* 先出栈再回调：回调里会 push 编辑器，两边同时操作导航栈会被 UIKit 丢掉一次。 */
    [self.navigationController popViewControllerAnimated:NO];
    if (block) block(identifier);
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.visible.count; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)path {
    MCAppProcessCell *c = [tv dequeueReusableCellWithIdentifier:@"MCAppProcessCell" forIndexPath:path];
    NSString *identifier = self.visible[path.row];
    NSUInteger src = [[self currentSource] indexOfObject:identifier];
    NSString *name = (src == NSNotFound) ? identifier : [self displayNameForIndex:src];
    BOOL running = MCPidsForIdentifier(identifier).count > 0;
    [c configureWithTitle:name subtitle:identifier running:running];
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tv deselectRowAtIndexPath:path animated:YES];
    [self pick:self.visible[path.row]];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)controller { [self applyFilter]; }

@end
