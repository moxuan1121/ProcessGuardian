/**
 * MCAppListViewController.m —— 选择要纳管的对象。
 *
 * 应用程序按包名列出，进程按系统枚举的名称列出；搜索同时覆盖两组。
 */
#import "MCPrefsClasses.h"

@interface MCAppListViewController ()
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UISegmentedControl *sourceControl;
@property (nonatomic, strong) UISearchBar *search;

@property (nonatomic, strong) NSArray<NSString *> *appIds;        /* 包名，与下面按下标对齐 */
@property (nonatomic, strong) NSArray<NSString *> *appNames;
@property (nonatomic, strong) NSArray<NSString *> *processNames;
@property (nonatomic, copy) NSSet<NSString *> *runningAppIds;

@property (nonatomic, copy) NSArray<NSArray<NSString *> *> *visibleSections;
@property (nonatomic, copy) NSArray<NSString *> *visibleTitles;
@end

@implementation MCAppListViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择进程";

    [self loadData];

    self.sourceControl = [[UISegmentedControl alloc] initWithItems:@[@"应用程序", @"系统进程"]];
    self.sourceControl.selectedSegmentIndex = 0;
    [self.sourceControl addTarget:self action:@selector(sourceChanged:)
                 forControlEvents:UIControlEventValueChanged];

    self.navigationItem.title = @"选择进程";

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.table.dataSource = self;
    self.table.delegate = self;
    [self.table registerClass:[MCAppProcessCell class] forCellReuseIdentifier:@"MCAppProcessCell"];
    self.table.translatesAutoresizingMaskIntoConstraints = NO;

    self.search = [UISearchBar new];
    self.search.delegate = self;
    self.search.placeholder = @"搜索应用名称、包名或系统进程";
    self.search.searchBarStyle = UISearchBarStyleMinimal;

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 110)];
    self.search.translatesAutoresizingMaskIntoConstraints = NO;
    self.sourceControl.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:self.search];
    [header addSubview:self.sourceControl];
    [NSLayoutConstraint activateConstraints:@[
        [self.search.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:8],
        [self.search.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-8],
        [self.search.topAnchor constraintEqualToAnchor:header.topAnchor constant:4],
        [self.search.heightAnchor constraintEqualToConstant:48],
        [self.sourceControl.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
        [self.sourceControl.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16],
        [self.sourceControl.topAnchor constraintEqualToAnchor:self.search.bottomAnchor constant:8],
    ]];
    self.table.tableHeaderView = header;

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
    self.runningAppIds = [NSSet setWithArray:MCPidsForIdentifiers(self.appIds).allKeys];
}

- (BOOL)showingProcesses { return self.sourceControl.selectedSegmentIndex == 1; }

- (void)applyFilter {
    NSString *q = [[self.search.text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    self.sourceControl.enabled = !q.length;
    if (!q.length) {
        self.visibleSections = @[ [self showingProcesses] ? self.processNames : self.appIds ];
        self.visibleTitles = @[ [self showingProcesses] ? @"系统进程" : @"应用程序" ];
    } else {
        NSMutableArray<NSString *> *apps = [NSMutableArray array], *processes = [NSMutableArray array];
        for (NSUInteger i = 0; i < self.appIds.count; i++)
            if ([self.appIds[i].lowercaseString containsString:q] ||
                [self.appNames[i].lowercaseString containsString:q]) [apps addObject:self.appIds[i]];
        for (NSString *name in self.processNames)
            if ([name.lowercaseString containsString:q]) [processes addObject:name];
        self.visibleSections = @[ apps, processes ];
        self.visibleTitles = @[ @"应用程序", @"系统进程" ];
    }
    [self.table reloadData];
}

- (void)sourceChanged:(UISegmentedControl *)sender {
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
    [self.search resignFirstResponder];
    if (self.navigationController.viewControllers.count > 1)
        [self.navigationController popViewControllerAnimated:YES];
    if (block) block(identifier);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return self.visibleSections.count; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.visibleSections[s].count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return self.visibleTitles[s];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)path {
    MCAppProcessCell *c = [tv dequeueReusableCellWithIdentifier:@"MCAppProcessCell" forIndexPath:path];
    NSString *identifier = self.visibleSections[path.section][path.row];
    BOOL process = [self.visibleTitles[path.section] isEqualToString:@"系统进程"];
    NSUInteger src = [self.appIds indexOfObject:identifier];
    NSString *name = process || src == NSNotFound ? identifier : self.appNames[src];
    BOOL running = process || [self.runningAppIds containsObject:identifier];
    NSString *subtitle = process ? (running ? @"系统进程 · 运行中" : @"系统进程 · 未运行")
        : [NSString stringWithFormat:@"%@ · %@", identifier, running ? @"运行中" : @"未运行"];
    [c configureWithTitle:name subtitle:subtitle running:running];
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tv deselectRowAtIndexPath:path animated:YES];
    [self pick:self.visibleSections[path.section][path.row]];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText { [self applyFilter]; }

@end
