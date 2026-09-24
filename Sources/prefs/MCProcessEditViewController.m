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
    MCEditRowNumber,   /* 数字（限额 / nice / 检测周期） */
    MCEditRowSwitch,   /* 开关 */
    MCEditRowOption,   /* 跳子页选择 */
    MCEditRowAction,   /* 按钮（删除） */
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
            [_field.widthAnchor constraintEqualToConstant:130],
            [_field.heightAnchor constraintEqualToConstant:30],
        ]];
        __weak typeof(self) ws = self;
        [_field addTarget:self action:@selector(commit) forControlEvents:UIControlEventEditingDidEnd];
        (void)ws;
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

/* ------------------------------------------------------------------  Jetsam 选择子页 */

@interface MCIntOptionPicker : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSString *pageTitle;
@property (nonatomic, strong) NSArray<NSNumber *> *values;
@property (nonatomic, strong) NSArray<NSString *> *titles;
@property (nonatomic, assign) NSInteger currentValue;
@property (nonatomic, copy) void (^onPick)(NSInteger value);
@end

/* ------------------------------------------------------------------  编辑器 */

@interface MCProcessEditViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray<NSArray<MCEditRow *> *> *sections;
@property (nonatomic, strong) NSMutableArray<NSString *> *sectionTitles;
@property (nonatomic, strong) NSMutableDictionary *config;
@end

@implementation MCProcessEditViewController

static NSString *const kWarningShownKey = @"MemoryControlRe.WarningShown";

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"编辑进程";

    NSDictionary *stored = [MCPrefs readPrefs][@"AppConfigs"][self.targetIdentifier];
    self.config = [stored isKindOfClass:[NSDictionary class]]
                  ? [stored mutableCopy]
                  : [[[MCProcessConfig defaultConfigForIdentifier:self.targetIdentifier] dictionaryValue] mutableCopy];

    [self buildRows];
    [self setupTable];
    [self showFirstRunWarningIfNeeded];
}

/**
 * 重量级强锁对大型 App 有实际风险（改坏内存生命周期会让它自杀），
 * 所以第一次进这一页必须把这段提示完整说完，而不是塞在小字 footer 里。
 */
- (void)showFirstRunWarningIfNeeded {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kWarningShownKey]) return;

    NSString *warning =
        @"提示：建议不要对微信、大型游戏或大型应用同时开启[脏数据强锁]、[Mach前台锁定]与"
        @"[GPU后台渲染保活]等重量级强锁，大型应用具备复杂的内存调度生命周期，修改状态可能会导致"
        @"其无法释放图片缓存与渲染上下文，最终可能会因 mach_vm_allocate_kernel 无法分配底层物理"
        @"内存而触发内部 SIGABRT 自杀或可能导致应用出现异常，出现应用异常可自行尝试排除关闭功能"
        @"并重启目标进程，如不懂也不要瞎勾八修改系统进程，使用默认配置即可";

    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"风险提示"
                                                              message:warning
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"我已了解" style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction *action) {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kWarningShownKey];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)buildRows {
    NSMutableArray *identity = [NSMutableArray array], *limits = [NSMutableArray array],
                   *switches = [NSMutableArray array], *timing = [NSMutableArray array];

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

    [switches addObject:[MCEditRow rowWithKind:MCEditRowSwitch title:@"剥离系统托管并强锁"
        footer:@"尝试剥离 P_MEMSTAT_MANAGED 内核标记，防止配置被系统恢复，并同时开启 ELEVATED_INACTIVE 非活跃提升保护"
        key:@"StripManaged"]];
    [switches addObject:[MCEditRow rowWithKind:MCEditRowSwitch title:@"脏数据强锁"
        footer:@"尝试向内核强制注册脏数据标记，并去除 PROC_DIRTY_ALLOW_IDLE_EXIT 权限。防止进程进入 Idle 休眠队列而被干掉"
        key:@"DirtyTrackStrongLock"]];
    [switches addObject:[MCEditRow rowWithKind:MCEditRowSwitch title:@"Mach 调度前台锁定"
        footer:@"调用 task_policy_set 尝试在 Mach 内核层将目标注入 TASK_FOREGROUND_APPLICATION 身份，对抗 CPU 后台挂起与 Throttle 机制"
        key:@"MachForegroundLock"]];
    [switches addObject:[MCEditRow rowWithKind:MCEditRowSwitch title:@"GPU 后台渲染保活"
        footer:@"设置 PRIO_DARWIN_GPU_ALLOW 权限，允许进程在后台持续调用硬件渲染资源，减少因违规调用 OpenGL/Metal 被系统终止的概率"
        key:@"GPURenderLock"]];
    [switches addObject:[MCEditRow rowWithKind:MCEditRowSwitch title:@"解除后台资源节流"
        footer:@"防止进程在后台进行大量磁盘 I/O 读写时，被内核标记为 IOPOL_THROTTLE 降级甚至杀死，提升后台读写优先级"
        key:@"IOBoostLock"]];
    [switches addObject:[MCEditRow rowWithKind:MCEditRowSwitch title:@"防内存溢出被杀"
        footer:@"仅在没有设置明确内存上限时生效；有上限时超限仍会杀进程"
        key:@"HighWaterMarkLock"]];
    [switches addObject:[MCEditRow rowWithKind:MCEditRowSwitch title:@"允许虚拟内存交换(Swap)"
        footer:@"允许内核将进程的脏内存压缩并交换到磁盘(Coalition Swappable)，可大幅降低物理内存不足时的闪退率"
        key:@"CoalitionSwappableLock"]];
    [switches addObject:[MCEditRow rowWithKind:MCEditRowSwitch title:@"禁用 EXC_RESOURCE(唤醒)"
        footer:@"解除系统对进程频繁唤醒的监控，防止日志中出现 WAKEUPS 异常强杀"
        key:@"WakeupsMonitorLock"]];
    [switches addObject:[MCEditRow rowWithKind:MCEditRowSwitch title:@"禁用 EXC_RESOURCE(CPU)"
        footer:@"解除系统对进程 CPU 占用过高的监控，防止因资源使用过多被强杀"
        key:@"CPUUsageMonitorLock"]];
    [switches addObject:[MCEditRow rowWithKind:MCEditRowSwitch title:@"网络/磁盘最高吞吐量"
        footer:@"强制设定网络和磁盘I/O为最高吞吐量级别(Tier 0)，防止后台下载或写入被系统降级限速"
        key:@"ThroughputQoSLock"]];
    [switches addObject:[MCEditRow rowWithKind:MCEditRowSwitch title:@"禁用 App Nap"
        footer:@"剥夺系统的 TASK_SUPPRESSION_POLICY 权限，可防止应用在后台被系统彻底剥夺CPU时间片而假死"
        key:@"SuppressionPolicyLock"]];
    [switches addObject:[MCEditRow rowWithKind:MCEditRowSwitch title:@"QoS 提权"
        footer:@"调用 TASK_BASE_QOS_POLICY 将进程提高层级(Tier 0)，从内核调度层面防止被分配到效能核心(E-Core)或被系统限速"
        key:@"BaseQoSLock"]];

    [timing addObject:[MCEditRow rowWithKind:MCEditRowNumber title:@"检测周期 (默认1800秒)"
        footer:@"写0或未写则默认为1800秒" key:@"CheckInterval"]];
    [timing addObject:[MCEditRow rowWithKind:MCEditRowAction title:@"删除此进程记录"
        footer:@"仅移除本面板的配置项；已生效的内核设置会在下一次巡检时恢复默认" key:@"__delete"]];

    self.sections = @[ identity, limits, switches, timing ];
    self.sectionTitles = [@[ @"目标说明:", @"内存限制:", @"强锁选项:", @"检测周期与备注:" ] mutableCopy];
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
    NSString *identifier = [self.targetIdentifier
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (identifier.length == 0) return;

    NSMutableDictionary *prefs = [MCPrefs readPrefs];
    NSMutableDictionary *apps = [prefs[@"AppConfigs"] mutableCopy] ?: [NSMutableDictionary dictionary];
    [apps removeObjectForKey:self.targetIdentifier];
    self.targetIdentifier = identifier;
    apps[identifier] = [self.config copy];
    prefs[@"AppConfigs"] = apps;
    /* 改完就叫醒守护进程：用户填完限额期待的是「立刻生效」，不是等下一轮巡检。 */
    [MCPrefs writePrefs:prefs wakeDaemon:YES];
}

- (void)deleteEntry {
    NSMutableDictionary *prefs = [MCPrefs readPrefs];
    NSMutableDictionary *apps = [prefs[@"AppConfigs"] mutableCopy];
    [apps removeObjectForKey:self.targetIdentifier];
    prefs[@"AppConfigs"] = apps;
    [MCPrefs writePrefs:prefs wakeDaemon:YES];
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)confirmDelete {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"删除此进程记录"
                                                              message:self.targetIdentifier
                                                       preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) ws = self;
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *x) { [ws deleteEntry]; }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)commitTextForRow:(MCEditRow *)row text:(NSString *)text {
    if ([row.key isEqualToString:@"__identifier"]) {
        self.targetIdentifier = text;
        [self persist];
        self.title = text.length ? @"编辑进程" : @"添加新进程";
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
        c.onCommit = ^(NSString *text) { [ws commitTextForRow:row text:text]; };
        return c;
    }

    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"plain" forIndexPath:path];
    c.textLabel.text = row.title;
    c.textLabel.numberOfLines = 0;
    if (row.kind == MCEditRowOption) {
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        c.detailTextLabel.text = [NSString stringWithFormat:@"%d", [self.config[row.key] intValue]];
    } else if (row.kind == MCEditRowAction) {
        c.textLabel.textColor = [UIColor systemRedColor];
        c.textLabel.textAlignment = NSTextAlignmentCenter;
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

    if (row.kind == MCEditRowAction) { [self confirmDelete]; return; }
    if (row.kind != MCEditRowOption) return;

    MCIntOptionPicker *picker = [MCIntOptionPicker new];
    picker.pageTitle = row.title;
    picker.values = MCPriorityBands();
    picker.titles = MCPriorityNames();
    picker.currentValue = [self.config[row.key] integerValue];
    __weak typeof(self) ws = self;
    picker.onPick = ^(NSInteger value) {
        ws.config[row.key] = @(value);
        [ws persist];
        [ws.table reloadData];
    };
    [self.navigationController pushViewController:picker animated:YES];
}

@end

/* ------------------------------------------------------------------ 选择子页实现 */

@implementation MCIntOptionPicker

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.pageTitle;
    UITableView *tv = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    tv.dataSource = self;
    tv.delegate = self;
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:tv];
    [NSLayoutConstraint activateConstraints:@[
        [tv.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [tv.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [tv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [tv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.titles.count; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"opt"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"opt"];
    c.textLabel.text = self.titles[path.row];
    c.textLabel.numberOfLines = 0;
    c.accessoryType = ([self.values[path.row] integerValue] == self.currentValue)
                      ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tv deselectRowAtIndexPath:path animated:YES];
    if (self.onPick) self.onPick([self.values[path.row] integerValue]);
    [self.navigationController popViewControllerAnimated:YES];
}

@end
