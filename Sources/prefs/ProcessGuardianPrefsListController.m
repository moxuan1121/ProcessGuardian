/**
 * ProcessGuardianPrefsListController.m —— 偏好面板根页。
 *
 * 使用 PSListController 的 specifiers 入口创建菜单，避免页面重进时读取到空菜单。
 *
 * 之所以绕开 CFPreferences：守护进程以 root 身份直接读那个 plist，而偏好域的缓存归
 * mobile 用户的 cfprefsd 所有。两套写入路径并存时，面板显示的值和守护进程读到的值
 * 会长期不一致，索性只留一条路。
 */
#import "MCPrefsClasses.h"

static NSString *const kSortKey     = @"SortMode";
static NSString *const kLogLimitKey = @"LogSizeLimit";

@interface ProcessGuardianPrefsListController () <UIDocumentPickerDelegate>
@end

@implementation ProcessGuardianPrefsListController

/* ---------------------------------------------------- 读写（单一走文件） */

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    return @([[MCPrefs readPrefs][key] boolValue]);
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key.length) return;

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
    MCProcessEditViewController *editor = [MCProcessEditViewController new];
    editor.creating = YES;
    [self presentProcessSheet:editor];
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

/** 用按钮 + 动作面板选择日志限额。 */
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

/* ---------------------------------------------------------------- 菜单 */

- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;
    NSMutableArray *items = [NSMutableArray array];

    PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"生效设置"];
    [group setProperty:@"关闭后停止应用配置，并恢复已接管进程的优先级和内存限制。" forKey:@"footerText"];
    [items addObject:group];
    for (NSArray *entry in @[ @[@"生效开关", @"Enabled"], @[@"后台刷新", @"BackgroundRefresh"] ]) {
        PSSpecifier *item = [PSSpecifier preferenceSpecifierNamed:entry[0] target:self
            set:@selector(setPreferenceValue:specifier:) get:@selector(readPreferenceValue:)
            detail:nil cell:PSSwitchCell edit:nil];
        [item setProperty:entry[1] forKey:@"key"];
        [item setProperty:@NO forKey:@"default"];
        [items addObject:item];
    }

    [items addObject:[PSSpecifier groupSpecifierWithName:@"日志配置"]];
    NSArray *buttons = @[
        @[@"查看日志", NSStringFromSelector(@selector(showLog))],
        @[@"清空日志", NSStringFromSelector(@selector(clearLog))],
        @[@"自动清理日志", NSStringFromSelector(@selector(chooseLogLimit))],
        @[@"进程排序", NSStringFromSelector(@selector(sortProcessList))],
        @[@"添加进程", NSStringFromSelector(@selector(addNewProcess))],
        @[@"进程列表", NSStringFromSelector(@selector(showProcessList))],
    ];
    for (NSArray *entry in buttons) {
        PSSpecifier *item = [PSSpecifier preferenceSpecifierNamed:entry[0] target:self
            set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
        [item setButtonAction:NSSelectorFromString(entry[1])];
        [items addObject:item];
    }

    group = [PSSpecifier groupSpecifierWithName:@"配置维护"];
    [group setProperty:@"导入/导出的是 AppConfigs 整段，可跨设备迁移；「跳转配置」用 Filza 打开原始 plist。" forKey:@"footerText"];
    [items addObject:group];
    for (NSArray *entry in @[
        @[@"跳转配置", NSStringFromSelector(@selector(jumpToConfig))],
        @[@"导入配置", NSStringFromSelector(@selector(importConfig))],
        @[@"导出配置", NSStringFromSelector(@selector(exportConfig))],
        @[@"恢复配置", NSStringFromSelector(@selector(restoreConfig))],
    ]) {
        PSSpecifier *item = [PSSpecifier preferenceSpecifierNamed:entry[0] target:self
            set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
        [item setButtonAction:NSSelectorFromString(entry[1])];
        [items addObject:item];
    }
    _specifiers = items;
    return _specifiers;
}

@end
