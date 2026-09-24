/**
 * MCProcessEditViewController.m —— 单条配置的编辑器。
 *
 * 不用 PSListController 而是手搓 tableView：这一页要同时放文本框、开关，以及一个
 * 需要跳子页选择的 Jetsam band 列表。用 specifier 驱动就得为每个控件现造
 * PSSpecifier，还得依赖 PreferenceLoader 未文档化的 Detail 传递机制。
 *
 * 字段说明文案与原面板逐字对齐 —— 它们是用户判断该不该勾的依据，不能改写。
 */
#import "MCPrefsClasses.h"

/* ------------------------------------------------------------------ 行模型 */

typedef NS_ENUM(NSInteger, MCEditRowKind) {
    MCEditRowText,     /* 文本（进程名 / 备注） */
    MCEditRowNumber,   /* 数字（限额 / nice / CPU） */
    MCEditRowSwitch,   /* 开关 */
    MCEditRowOption,   /* 跳子页选择 */
};

@interface MCEditRow : NSObject
@property (nonatomic, assign) MCEditRowKind kind;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *footer;
@property (nonatomic, copy) NSString *key;
@property (nonatomic, strong) id placeholder;
/* 调用方在别的 @implementation 里，必须在这里声明，光有 @implementation 里的定义不够。 */
+ (instancetype)rowWithKind:(MCEditRowKind)kind title:(NSString *)title
                     footer:(NSString *)footer key:(NSString *)key;
@end

@implementation MCEditRow
+ (instancetype)rowWithKind:(MCEditRowKind)kind title:(NSString *)title footer:(NSString *)footer key:(NSString *)key {
    MCEditRow *r = [MCEditRow new];
    r.kind = kind; r.title = title; r.footer = footer; r.key = key;
    return r;
}
@end

/* ------------------------------------------------------------------ 两个控件 cell */

@interface MCFieldCell : UITableViewCell
@property (nonatomic, strong) UITextField *field;
@property (nonatomic, copy) void (^onCommit)(NSString *text);
@end

@implementation MCFieldCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
    self = [super initWithStyle:style reuseIdentifier:rid];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _field = [UITextField new];
        _field.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        _field.textAlignment = NSTextAlignmentRight;
        _field.clearButtonMode = UITextFieldViewModeWhileEditing;
        _field.autocorrectionType = UITextAutocorrectionTypeNo;
        _field.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_field];
        [NSLayoutConstraint activateConstraints:@[
            [_field.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_field.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
            [_field.widthAnchor constraintEqualToConstant:160],
            [_field.heightAnchor constraintEqualToConstant:30],
        ]];
        [_field addTarget:self action:@selector(commit) forControlEvents:UIControlEventEditingDidEnd];
    }
    return self;
}
- (void)commit { if (self.onCommit) self.onCommit(self.field.text ?: @""); }
@end

@interface MCSwitchCell : UITableViewCell
@property (nonatomic, strong) UISwitch *sw;
@property (nonatomic, copy) void (^onToggle)(BOOL on);
@end

@implementation MCSwitchCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
    self = [super initWithStyle:style reuseIdentifier:rid];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _sw = [UISwitch new];
        [_sw addTarget:self action:@selector(toggle) forControlEvents:UIControlEventValueChanged];
        self.accessoryView = _sw;
    }
    return self;
}
- (void)toggle { if (self.onToggle) self.onToggle(self.sw.isOn); }
@end

/* ------------------------------------------------------------------  编辑器 */

@interface MCProcessEditViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray<NSArray<MCEditRow *> *> *sections;
@property (nonatomic, strong) NSMutableArray<NSString *> *sectionTitles;
@property (nonatomic, strong) NSMutableDictionary *config;
@property (nonatomic, copy) NSString *originalIdentifier;
@end

@implementation MCProcessEditViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.creating ? @"添加进程" : @"编辑进程";
    self.originalIdentifier = self.targetIdentifier;

    NSDictionary *stored = self.targetIdentifier.length
        ? [MCPrefs readPrefs][@"AppConfigs"][self.targetIdentifier] : nil;
    self.config = [stored isKindOfClass:[NSDictionary class]]
                  ? [stored mutableCopy]
                  : [[[MCProcessConfig defaultConfigForIdentifier:self.targetIdentifier] dictionaryValue] mutableCopy];

    [self buildRows];
    [self setupTable];
    if (self.creating) self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemSave target:self action:@selector(saveNewProcess)];
}

- (void)chooseIdentifier {
    MCAppListViewController *picker = [MCAppListViewController new];
    __weak typeof(self) ws = self;
    picker.onPick = ^(NSString *identifier) {
        ws.targetIdentifier = identifier;
        [ws.table reloadData];
    };
    [self.navigationController pushViewController:picker animated:YES];
}

- (void)saveNewProcess {
    [self.view endEditing:YES];
    NSString *identifier = [self.targetIdentifier stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!identifier.length) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"请填写进程名或包名"
            message:nil preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    NSMutableDictionary *prefs = [MCPrefs readPrefs];
    NSMutableDictionary *apps = [prefs[@"AppConfigs"] mutableCopy] ?: [NSMutableDictionary dictionary];
    if (apps[identifier]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"进程已添加"
            message:identifier preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    apps[identifier] = [self.config copy];
    prefs[@"AppConfigs"] = apps;
    [MCPrefs writePrefs:prefs wakeDaemon:YES];
    if (self.navigationController.viewControllers.count > 1)
        [self.navigationController popViewControllerAnimated:YES];
    else
        [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)buildRows {
    NSMutableArray *identity = [NSMutableArray array], *limits = [NSMutableArray array],
                   *switches = [NSMutableArray array];

    [identity addObject:[MCEditRow rowWithKind:MCEditRowText title:@"目标进程名 / 包名"
                     footer:@"通过包名或进程名识别进程" key:@"__identifier"]];
    [identity addObject:[MCEditRow rowWithKind:MCEditRowText title:@"备注 (主页显示名称)"
                     footer:nil key:@"Remark"]];

    [limits addObject:[MCEditRow rowWithKind:MCEditRowNumber title:@"活跃内存限制 (MB)"
                     footer:@"0 让插件不要设置\n-1 表示不受限制(会分配当前设备最高的用户内存)\n或自定义填写最大内存限制(MB）"
                     key:@"MemLimitActive"]];
    [limits addObject:[MCEditRow rowWithKind:MCEditRowNumber title:@"后台内存限制 (MB)"
                     footer:@"同上，作用于进程处于后台时" key:@"MemLimitInactive"]];
    [limits addObject:[MCEditRow rowWithKind:MCEditRowNumber title:@"进程优先级 (Nice)"
                     footer:@"-20 最高优先 到 19 最低优先, 默认为空不设置" key:@"NiceValue"]];
    [limits addObject:[MCEditRow rowWithKind:MCEditRowOption title:@"内存优先级 (Jetsam)"
                     footer:@"-1 让插件不要设置；0 重新让系统接管；其余为内核 jetsam band"
                     key:@"JetsamPriority"]];
    [limits addObject:[MCEditRow rowWithKind:MCEditRowNumber title:@"前台 CPU 上限 (%)"
                     footer:@"0 关闭；2～1000 为 CPU 百分比阈值。100% 约为单个核心满载"
                     key:@"CPUThreshold"]];
    [limits addObject:[MCEditRow rowWithKind:MCEditRowNumber title:@"连续超限时间 (秒)"
                     footer:@"默认 10 秒；只有前台 CPU 上限大于 0 时生效"
                     key:@"CPUDuration"]];

    [switches addObject:[MCEditRow rowWithKind:MCEditRowSwitch title:@"后台被杀后自动重新拉起"
        footer:@"仅适用于应用包名；超过内存或 CPU 阈值而退出后也会重新拉起"
        key:@"KeepAlive"]];
    [switches addObject:[MCEditRow rowWithKind:MCEditRowSwitch title:@"注销后自动拉起"
        footer:@"重启 SpringBoard 后按顺序恢复已守护的应用" key:@"RelaunchAfterRespring"]];

    self.sections = @[ identity, limits, switches ];
    self.sectionTitles = [@[ @"目标说明", @"内存限制", @"强锁选项" ] mutableCopy];
}

- (void)setupTable {
    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = UITableViewAutomaticDimension;
    self.table.estimatedRowHeight = 64;
    [self.table registerClass:[MCFieldCell class] forCellReuseIdentifier:@"field"];
    [self.table registerClass:[MCSwitchCell class] forCellReuseIdentifier:@"switch"];
    [self.table registerClass:[UITableViewCell class] forCellReuseIdentifier:@"plain"];
    self.table.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.table];
    [NSLayoutConstraint activateConstraints:@[
        [self.table.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];
}

/* ------------------------------------------------------------------ 写回 */

- (void)persist {
    if (self.creating) return;
    NSString *identifier = [self.targetIdentifier
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (identifier.length == 0) return;

    NSMutableDictionary *prefs = [MCPrefs readPrefs];
    NSMutableDictionary *apps = [prefs[@"AppConfigs"] mutableCopy] ?: [NSMutableDictionary dictionary];
    [apps removeObjectForKey:self.originalIdentifier];
    self.targetIdentifier = identifier;
    self.originalIdentifier = identifier;
    apps[identifier] = [self.config copy];
    prefs[@"AppConfigs"] = apps;
    /* 改完就叫醒守护进程：用户填完限额期待的是「立刻生效」，不是等下一轮巡检。 */
    [MCPrefs writePrefs:prefs wakeDaemon:YES];
}

- (void)commitTextForRow:(MCEditRow *)row text:(NSString *)text {
    if ([row.key isEqualToString:@"__identifier"]) {
        self.targetIdentifier = text;
        [self persist];
        self.title = self.creating ? @"添加进程" : @"编辑进程";
        return;
    }
    if ([row.key isEqualToString:@"Remark"]) { self.config[row.key] = text ?: @""; [self persist]; return; }

    NSScanner *scanner = [NSScanner scannerWithString:text ?: @""];
    NSInteger parsed = 0;
    if ([scanner scanInteger:&parsed] && scanner.isAtEnd) {
        /* nice 合法区间只有 -20..19，越界到了守护进程那边就是一条 EINVAL 失败日志，
           在输入处夹住比让它报错有用。 */
        if ([row.key isEqualToString:@"NiceValue"])
            parsed = MAX((NSInteger)PRIO_MIN, MIN((NSInteger)PRIO_MAX - 1, parsed));
        if ([row.key isEqualToString:@"CPUThreshold"] && parsed != 0 && (parsed < 2 || parsed > 1000)) parsed = 0;
        if ([row.key isEqualToString:@"CPUDuration"] && (parsed < 1 || parsed > 3600)) parsed = 10;
        self.config[row.key] = @(parsed);
    } else {
        self.config[row.key] = @0;   /* 解析不动就按「不设置」处理，避免误填把限额改成 0 以外的值 */
    }
    [self persist];
}

/* ------------------------------------------------------------------ 数据源 */

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return self.sections.count; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.sections[s].count; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return self.sectionTitles[s];
}

- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s {
    return UITableViewAutomaticDimension;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)path {
    MCEditRow *row = self.sections[path.section][path.row];
    __weak typeof(self) ws = self;

    if (row.kind == MCEditRowSwitch) {
        MCSwitchCell *c = [tv dequeueReusableCellWithIdentifier:@"switch" forIndexPath:path];
        c.textLabel.text = row.title;
        c.textLabel.numberOfLines = 0;
        c.sw.on = [self.config[row.key] boolValue];
        c.onToggle = ^(BOOL on) { ws.config[row.key] = @(on); [ws persist]; };
        return c;
    }

    if (row.kind == MCEditRowText || row.kind == MCEditRowNumber) {
        MCFieldCell *c = [tv dequeueReusableCellWithIdentifier:@"field" forIndexPath:path];
        c.textLabel.text = row.title;
        id value = [row.key isEqualToString:@"__identifier"] ? ws.targetIdentifier : ws.config[row.key];
        c.field.text = value ? [NSString stringWithFormat:@"%@", value] : @"";
        c.field.placeholder = row.title;
        /* 限额与 nice 都可能是负数，必须用允许负号的数字键盘，不能走 UIKeyboardTypeNumberPad。 */
        c.field.keyboardType = row.kind == MCEditRowNumber ? UIKeyboardTypeNumbersAndPunctuation
                                                          : UIKeyboardTypeDefault;
        if ([row.key isEqualToString:@"__identifier"] && self.creating) {
            UIButton *choose = [UIButton buttonWithType:UIButtonTypeSystem];
            [choose setTitle:@"选择" forState:UIControlStateNormal];
            choose.frame = CGRectMake(0, 0, 42, 30);
            [choose addTarget:self action:@selector(chooseIdentifier)
                forControlEvents:UIControlEventTouchUpInside];
            c.field.rightView = choose;
            c.field.rightViewMode = UITextFieldViewModeAlways;
        } else {
            c.field.rightView = nil;
        }
        c.onCommit = ^(NSString *text) { [ws commitTextForRow:row text:text]; };
        return c;
    }

    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"plain" forIndexPath:path];
    c.textLabel.text = row.title;
    c.textLabel.numberOfLines = 0;
    if (row.kind == MCEditRowOption) {
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        c.detailTextLabel.text = [NSString stringWithFormat:@"%d", [self.config[row.key] intValue]];
    }
    return c;
}

/* ------------------------------------------------------------------ footer */

- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)s {
    NSArray<MCEditRow *> *rows = self.sections[s];
    NSMutableArray *lines = [NSMutableArray array];
    for (MCEditRow *r in rows) if (r.footer.length) [lines addObject:[NSString stringWithFormat:@"%@\n%@", r.footer, @""]];

    UILabel *label = [UILabel new];
    label.numberOfLines = 0;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];
    label.textColor = [UIColor secondaryLabelColor];
    label.text = [lines componentsJoinedByString:@"\n"];

    UIView *container = [[UIView alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [label.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
        [label.topAnchor constraintEqualToAnchor:container.topAnchor constant:6],
        [label.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-6],
    ]];
    return container;
}

- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)s {
    return UITableViewAutomaticDimension;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tv deselectRowAtIndexPath:path animated:YES];
    MCEditRow *row = self.sections[path.section][path.row];

    if (row.kind != MCEditRowOption) return;

    UIAlertController *menu = [UIAlertController alertControllerWithTitle:row.title
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray<NSNumber *> *values = MCPriorityBands();
    NSArray<NSString *> *titles = MCPriorityNames();
    __weak typeof(self) ws = self;
    for (NSUInteger i = 0; i < values.count; i++) {
        NSNumber *value = values[i];
        NSString *title = [self.config[row.key] isEqual:value]
            ? [titles[i] stringByAppendingString:@" ✓"] : titles[i];
        [menu addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *action) {
                ws.config[row.key] = value;
                [ws persist];
                [ws.table reloadData];
            }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:menu animated:YES completion:nil];
}

@end
