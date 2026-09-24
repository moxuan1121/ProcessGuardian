/**
 * MCLogViewController.m —— 运行日志查看器。
 *
 * 守护进程以 root 写 /var/mobile/Library/Logs，面板以 mobile 读同一份，不需要
 * 任何特权。日志按行缓存到内存再分页渲染：单条日志可能长达数百字（内核回读那条
 * 尤其长），一次全量 build attributed string 会明显卡顿。
 */
#import "MCPrefsClasses.h"

@interface MCLogViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray<NSString *> *lines;
@property (nonatomic, copy) NSString *filter;         /* nil = 不过滤 */
@end

@implementation MCLogViewController

static NSString *const kFilters[] = { nil, @"[守护]", @"[配置]", @"[内核]" };

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"运行日志";

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = UITableViewAutomaticDimension;
    self.table.estimatedRowHeight = 40;
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.table];

    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                      target:self action:@selector(reloadLog)],
        [[UIBarButtonItem alloc] initWithTitle:@"筛选" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(chooseFilter)],
    ];
    [self reloadLog];
}

- (void)reloadLog {
    NSString *text = [NSString stringWithContentsOfFile:[MCCommon logFilePath]
                                                encoding:NSUTF8StringEncoding error:nil];
    if (text.length == 0) {
        self.lines = @[ @"暂无日志或守护进程未启动。" ];
        [self.table reloadData];
        return;
    }
    NSArray *all = [text componentsSeparatedByString:@"\n"];
    if (self.filter) {
        NSPredicate *p = [NSPredicate predicateWithBlock:^BOOL(NSString *line, NSDictionary *b) {
            return [line containsString:self.filter];
        }];
        all = [all filteredArrayUsingPredicate:p];
    }
    /* 最新的在最上面：翻日志基本只看末尾。 */
    self.lines = [[all reverseObjectEnumerator] allObjects];
    [self.table reloadData];
}

- (void)chooseFilter {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"筛选标签"
                                                              message:nil
                                                       preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) ws = self;
    for (NSInteger i = 0; i < 4; i++) {
        NSString *title = kFilters[i] ?: @"全部";
        [a addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *x) {
            ws.filter = kFilters[i];
            [ws reloadLog];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.lines.count; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"log"];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"log"];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    c.textLabel.text = self.lines[path.row];
    c.textLabel.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    c.textLabel.numberOfLines = 0;
    return c;
}

@end
