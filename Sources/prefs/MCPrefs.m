#import "MCPrefs.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/sysctl.h>
#import <libproc.h>
#import <sys/resource.h>
#import <errno.h>
#import "../MCKernel.h"

NSArray<NSNumber *> *MCPriorityBands(void) {
    return @[@(-1), @(0), @(10), @(20), @(30), @(40), @(50), @(80), @(90),
             @(100), @(120), @(130), @(150), @(160), @(170), @(180), @(190), @(210)];
}

NSArray<NSString *> *MCPriorityNames(void) {
    return @[
        @"-1 让插件不要设置",
        @"0 重新让系统接管",
        @"10 空闲延迟",
        @"20 后台机会性",
        @"30 后台",
        @"40 提升的非活跃进程",
        @"50 电话相关",
        @"80 界面支持",
        @"90 前台支持",
        @"100 前台",
        @"120 音频与配件",
        @"130 管理协调进程",
        @"150 系统驱动",
        @"160 主屏幕相关",
        @"170 系统执行级",
        @"180 重要进程",
        @"190 关键电话进程",
        @"210 最高优先级",
    ];
}

@implementation MCPrefs

+ (NSMutableDictionary *)readPrefs {
    NSMutableDictionary *d = [[MCCommon readPreferences] mutableCopy];
    if (![d[@"AppConfigs"] isKindOfClass:[NSDictionary class]]) d[@"AppConfigs"] = @{};
    return d;
}

+ (void)writePrefs:(NSDictionary *)prefs wakeDaemon:(BOOL)wake {
    /* 直接写文件而不是走 CFPreferences：守护进程以 root 身份读同一个路径，
       而 CFPreferences 的缓存属于 Preferences.app 进程，跨进程看不到。 */
    [(NSDictionary *)prefs writeToFile:[MCCommon preferencesPlistPath] atomically:YES];
    if (wake) notify_post(MCApplyLimitsNotification.UTF8String);
}

+ (NSDictionary *)readStatus { return [MCCommon readStatus]; }

+ (NSDictionary<NSString *, NSString *> *)installedApps {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];

    /* LSApplicationWorkspace 是 iOS 上唯一能拿到「显示名 + 包名」配对的正经入口。 */
    Class ws = objc_getClass("LSApplicationWorkspace");
    SEL allApps = sel_registerName("allApplications");
    SEL displayName = sel_registerName("displayName");
    SEL bundleId = sel_registerName("bundleIdentifier");
    id shared = nil;
    /* 这个类对面板完全不可见，performSelector: 会触发 ARC 的未知选择器告警，
       和下面几个调用一样统一走 objc_msgSend 强转。 */
    if (ws)
        shared = ((id (*)(id, SEL))objc_msgSend)(ws, sel_registerName("defaultWorkspace"));

    if (shared && allApps) {
        @try {
            NSArray *list = ((id (*)(id, SEL))objc_msgSend)(shared, allApps);
            for (id app in list) {
                NSString *bid = bundleId ? ((id (*)(id, SEL))objc_msgSend)(app, bundleId) : nil;
                NSString *name = displayName ? ((id (*)(id, SEL))objc_msgSend)(app, displayName) : nil;
                if ([bid isKindOfClass:[NSString class]])
                    out[bid] = [name isKindOfClass:[NSString class]] ? name : [bid lastPathComponent];
            }
        } @catch (NSException *e) { /* 拿不到就退回文件系统扫描 */ }
    }
    if (out.count) return out;

    NSString *root = @"/private/var/containers/Bundle/Application";
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *uuid in [fm contentsOfDirectoryAtPath:root error:nil]) {
        NSString *appDir = [root stringByAppendingPathComponent:uuid];
        for (NSString *bundle in [fm contentsOfDirectoryAtPath:appDir error:nil]) {
            if (![bundle hasSuffix:@".app"]) continue;
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                [appDir stringByAppendingPathComponent:
                    [bundle stringByAppendingPathComponent:@"Info.plist"]]];
            NSString *bid = info[@"CFBundleIdentifier"];
            if (![bid isKindOfClass:[NSString class]]) continue;
            NSString *name = ([info[@"CFBundleDisplayName"] isKindOfClass:[NSString class]]
                              && [info[@"CFBundleDisplayName"] length])
                             ? info[@"CFBundleDisplayName"] : info[@"CFBundleName"];
            out[bid] = [name isKindOfClass:[NSString class]] ? name : [bundle stringByDeletingPathExtension];
        }
    }
    return out;
}

+ (NSArray<NSString *> *)runningProcessNames {
    NSMutableSet<NSString *> *appExecutables = [NSMutableSet set];
    Class workspace = objc_getClass("LSApplicationWorkspace");
    id shared = workspace ? ((id (*)(id, SEL))objc_msgSend)(workspace, sel_registerName("defaultWorkspace")) : nil;
    @try {
        NSArray *apps = shared ? ((id (*)(id, SEL))objc_msgSend)(shared, sel_registerName("allApplications")) : @[];
        for (id app in apps) {
            NSString *exe = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("bundleExecutable"));
            if ([exe isKindOfClass:[NSString class]] && exe.length) [appExecutables addObject:exe];
        }
    } @catch (NSException *e) { /* 仍可按 .app 路径过滤 */ }
    size_t size = 0;
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    if (sysctl(mib, 4, NULL, &size, NULL, 0) < 0) return @[];
    struct kinfo_proc *procs = malloc(size);
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if (procs) {
        if (sysctl(mib, 4, procs, &size, NULL, 0) == 0) {
            int n = (int)(size / sizeof(struct kinfo_proc));
            for (int i = 0; i < n; i++) {
                NSString *name = @(procs[i].kp_proc.p_comm);
                BOOL appExecutable = NO;
                for (NSString *exe in appExecutables)
                    if ([exe hasPrefix:name] && (name.length == exe.length || name.length == 15)) {
                        appExecutable = YES;
                        break;
                    }
                if (name.length && !appExecutable && !MCBundleIdForPid(procs[i].kp_proc.p_pid)
                    && ![names containsObject:name]) [names addObject:name];
            }
        }
        free(procs);
    }
    return [names sortedArrayUsingSelector:@selector(compare:)];
}

+ (NSString *)subtitleForIdentifier:(NSString *)key config:(NSDictionary *)cfg {
    pid_t pid = 0;
    for (NSNumber *p in MCPidsForIdentifier(key)) { pid = p.intValue; break; }
    NSString *actualPriority = @"?", *actualNice = @"?";
    if (pid > 0) {
        memorystatus_priority_entry_t entry = {0};
        if (memorystatus_control(MEMORYSTATUS_CMD_GET_PRIORITY_LIST, pid, 0,
                                 &entry, sizeof(entry)) == 0)
            actualPriority = [@(entry.priority) stringValue];
        errno = 0;
        int nice = getpriority(PRIO_PROCESS, pid);
        if (errno == 0) actualNice = [@(nice) stringValue];
        if ([actualPriority isEqualToString:@"?"] || [actualNice isEqualToString:@"?"]) {
            id processes = [MCPrefs readStatus][@"Processes"];
            id status = [processes isKindOfClass:[NSDictionary class]] ? processes[key] : nil;
            if (![status isKindOfClass:[NSDictionary class]]) status = nil;
            if ([status[@"pid"] intValue] == pid) {
                if ([actualPriority isEqualToString:@"?"] && [status[@"ActualJetsam"] isKindOfClass:[NSNumber class]])
                    actualPriority = [status[@"ActualJetsam"] stringValue];
                if ([actualNice isEqualToString:@"?"] && [status[@"ActualNice"] isKindOfClass:[NSNumber class]])
                    actualNice = [status[@"ActualNice"] stringValue];
            }
        }
    }
    NSInteger configuredPriority = cfg[@"JetsamPriority"] ? [cfg[@"JetsamPriority"] integerValue] : -1;
    return [NSString stringWithFormat:@"p=%@、n=%@、pid=%@\np=%ld、a=%ld、i=%ld、n=%ld、s=%d",
        actualPriority, actualNice, pid ? [@(pid) stringValue] : @"?",
        (long)configuredPriority, (long)[cfg[@"MemLimitActive"] integerValue],
        (long)[cfg[@"MemLimitInactive"] integerValue], (long)[cfg[@"NiceValue"] integerValue],
        [cfg[@"KeepAlive"] boolValue] ? 1 : 0];
}

@end
