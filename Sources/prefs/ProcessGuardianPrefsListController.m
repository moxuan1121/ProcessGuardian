/**
 * ProcessGuardianPrefsListController.m —— 偏好面板根页。
 *
 * Root.plist 里每个可写项都带 Get/Set 两个键，指向本类的
 * preferenceValueForSpecifier: / setPreferenceValue:specifier:，于是不管开关还是
 * 输入框，读写都走同一个文件。
 *
 * 之所以绕开 CFPreferences：守护进程以 root 身份直接读那个 plist，而偏好域的缓存归
 * mobile 用户的 cfprefsd 所有。两套写入路径并存时，面板显示的值和守护进程读到的值
 * 会长期不一致，索性只留一条路。
 */
#import "MCPrefsClasses.h"

static NSString *const kSortKey     = @"SortMode";
static NSString *const kLogLimitKey = @"LogSizeLimit";
static NSString *const kTGChatURL   = @"https://t.me/iosdumpzzz";

@interface ProcessGuardianPrefsListController () <UIDocumentPickerDelegate>
@property (nonatomic, strong) NSArray<PSSpecifier *> *rootSpecifiers;
@end

@implementation ProcessGuardianPrefsListController

/* ---------------------------------------------------- 读写（单一走文件） */

- (id)preferenceValueForSpecifier:(PSSpecifier *)specifier {
    NSString *key = specifier.key;
    if (!key.length) return [super preferenceValueForSpecifier:specifier];
    id v = [MCPrefs readPrefs][key];
    /* 开关类取值必须回成 NSNumber，否则 PSSwitchCell 会拿 nil 当 0 又写回一次。 */
    if ([specifier.cellClass isSubclassOfClass:NSClassFromString(@"PSSwitchCell")])
        return v ? @([v boolValue]) : @NO;
    return v ?: @"";
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = specifier.key;
    if (!key.length) { [super setPreferenceValue:value specifier:specifier]; return; }

    NSMutableDictionary *prefs = [MCPrefs readPrefs];
    if (value == nil || [value isEqual:@""]) [prefs removeObjectForKey:key];
    else prefs[key] = value;

    /* 开关和强锁直接决定守护进程要不要动手，改完就叫醒它，不必等 1800s 巡检。 */
    BOOL wake = [key isEqualToString:@"Enabled"];
    [MCPrefs writePrefs:prefs wakeDaemon:wake];
}

/* ---------------------------------------------------------------- 动作 */

/** 排序方式记在偏好里，由列表页读取后应用，这样两个页面共用一份状态。 */
- (void)sortProcessList {
    NSArray *titles = @[@"默认排序", @"进程优先级高到低", @"内存优先级高到低"];
    NSInteger current = [[MCPrefs readPrefs][kSortKey] integerValue];

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"进程列表排序方式" message:nil
                  preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
        NSString *title = titles[i];
        if (i == current) title = [title stringByAppendingString:@" ✓"];
        __weak typeof(self) ws = self;
        [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
            NSMutableDictionary *p = [MCPrefs readPrefs];
            p[kSortKey] = @(i);
            [MCPrefs writePrefs:p wakeDaemon:NO];
            [ws alertWithMessage:@"排序已更新"];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showProcessList {
    [self presentProcessSheet:[MCProcessListViewController new]];
}

- (void)addNewProcess {
    MCAppListViewController *picker = [MCAppListViewController new];
    __weak typeof(self) ws = self;
    picker.onPick = ^(NSString *identifier) {
        [ws addProcessWithIdentifier:identifier];
    };
    [self presentProcessSheet:picker];
}

- (void)presentProcessSheet:(UIViewController *)controller {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:controller];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    nav.sheetPresentationController.detents = @[UISheetPresentationControllerDetent.largeDetent];
    controller.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(closeProcessSheet)];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)closeProcessSheet {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)addProcessWithIdentifier:(NSString *)identifier {
    if (identifier.length == 0) return;
    NSMutableDictionary *prefs = [MCPrefs readPrefs];
    NSMutableDictionary *apps = [prefs[@"AppConfigs"] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSString *clean = [identifier stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!apps[clean]) apps[clean] = [[MCProcessConfig defaultConfigForIdentifier:clean] dictionaryValue];
    prefs[@"AppConfigs"] = apps;
    [MCPrefs writePrefs:prefs wakeDaemon:YES];

    [self pushEditForIdentifier:clean];
}

- (void)pushEditForIdentifier:(NSString *)identifier {
    MCProcessEditViewController *vc = [MCProcessEditViewController new];
    vc.targetIdentifier = identifier;
    UINavigationController *nav = (UINavigationController *)self.presentedViewController;
    [nav pushViewController:vc animated:YES];
}

- (void)pushSection:(NSString *)className {
    UIViewController *vc = [[NSClassFromString(className) alloc] init];
    if (vc) [self.navigationController pushViewController:vc animated:YES];
}

/* ---------------------------------------------------------------- 日志 */

- (void)showLog {
    [self pushSection:@"MCLogViewController"];
}

- (void)clearLog {
    [@"" writeToFile:[MCCommon logFilePath] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self alertWithMessage:@"日志已清空！"];
}

/** 用按钮 + 动作面板而不是 plist 里的选项 cell：原版 Root.plist 只用到 PSGroup/PSSwitch/PSButton 三种 cell。 */
- (void)chooseLogLimit {
    NSArray *values  = @[@1, @2, @5, @10];
    NSArray *titles  = @[@"1 MB", @"2 MB(默认)", @"5 MB", @"10 MB"];
    NSInteger current = [[MCPrefs readPrefs][kLogLimitKey] integerValue];

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"自动清理日志" message:@"选择当日志达到多大时自动清空？"
                  preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSInteger i = 0; i < (NSInteger)values.count; i++) {
        NSString *title = titles[i];
        if ([values[i] integerValue] == current) title = [title stringByAppendingString:@" ✓"];
        NSNumber *value = values[i];
        [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
            NSMutableDictionary *p = [MCPrefs readPrefs];
            p[kLogLimitKey] = value;
            [MCPrefs writePrefs:p wakeDaemon:YES];   /* 守护进程每轮重读限额，叫醒它立刻生效 */
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)openTGChat {
    NSURL *url = [NSURL URLWithString:kTGChatURL];
    if ([[UIApplication sharedApplication] canOpenURL:url])
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    else
        [self alertWithMessage:@"无法打开链接"];
}

/* ------------------------------------------------------ 导入 / 导出 / 恢复 */

- (void)importConfig {
    UIDocumentPickerViewController *picker;
    picker = [[UIDocumentPickerViewController alloc]
                  initWithDocumentTypes:@[ @"public.property-list" ] inMode:UIDocumentPickerModeImport];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
     didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSData *data = [NSData dataWithContentsOfURL:urls.firstObject];
    NSDictionary *imported = data
        ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL]
        : nil;

    if (![imported[@"AppConfigs"] isKindOfClass:[NSDictionary class]]) {
        [self alertWithMessage:@"无效的配置文件"];
        return;
    }
    NSMutableDictionary *prefs = [MCPrefs readPrefs];
    prefs[@"AppConfigs"] = imported[@"AppConfigs"];
    [MCPrefs writePrefs:prefs wakeDaemon:YES];
    [self alertWithMessage:@"配置导入成功并已生效"];
}

- (void)exportConfig {
    NSDictionary *apps = [MCPrefs readPrefs][@"AppConfigs"];
    if (![apps isKindOfClass:[NSDictionary class]] || apps.count == 0) {
        [self alertWithMessage:@"当前配置为空"];
        return;
    }
    NSString *dest = [NSTemporaryDirectory() stringByAppendingPathComponent:@"MemoryControlRe.plist"];
    if (![@{ @"AppConfigs": apps } writeToFile:dest atomically:YES]) {
        [self alertWithMessage:@"导出失败"];
        return;
    }
    UIDocumentPickerViewController *share =
        [[UIDocumentPickerViewController alloc] initForExportingURLs:@[ [NSURL fileURLWithPath:dest] ]
                                                             asCopy:YES];
    share.delegate = self;
    [self presentViewController:share animated:YES completion:nil];
}

/** 用 Filza 打开偏好文件做手改；没装就直说，不要假装成功。 */
- (void)jumpToConfig {
    NSString *path = [MCCommon preferencesPlistPath];
    NSString *enc = [path stringByAddingPercentEncodingWithAllowedCharacters:
                        [NSCharacterSet URLPathAllowedCharacterSet]];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"filza://view%@", enc]];
    if (![[UIApplication sharedApplication] canOpenURL:url]) {
        [self alertWithMessage:@"未检测到 Filza，请先安装 Filza File Manager"];
        return;
    }
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

- (void)restoreConfig {
    UIAlertController *confirm = [UIAlertController
        alertControllerWithTitle:nil
                         message:@"恢复到默认配置？会覆盖现有配置"
                  preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) ws = self;
    [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"恢复" style:UIAlertActionStyleDestructive
                                              handler:^(UIAlertAction *a) {
        NSMutableDictionary *p = [MCPrefs readPrefs];
        p[@"AppConfigs"] = [MCCommon defaultAppConfigs];
        [MCPrefs writePrefs:p wakeDaemon:YES];
        [ws alertWithMessage:@"已恢复默认配置"];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)alertWithMessage:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:nil
                                                               message:message
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

/* ---------------------------------------------------------------- 生命周期 */

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"ProcessGuardian";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if ([[MCPrefs readPrefs][@"BackgroundRefresh"] boolValue])
        [self.tableview reloadData];
}

- (NSArray<PSSpecifier *> *)specifiers {
    if (!_rootSpecifiers) _rootSpecifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    return _rootSpecifiers;
}

@end
