#import "MCPrefs.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/sysctl.h>

NSArray<NSNumber *> *MCPriorityBands(void) {
    return @[@(-1), @(0), @(10), @(20), @(30), @(40), @(50), @(80), @(90),
             @(100), @(120), @(130), @(150), @(160), @(170), @(180), @(190), @(210)];
}

NSArray<NSString *> *MCPriorityNames(void) {
    return @[
        @"-1 让插件不要设置",
        @"0 重新让系统接管",
        @"10 空闲延迟 IDLE_DEFERRED",
        @"20 后台机遇性 BACKGROUND_OPPORTUNISTIC",
        @"30 后台 BACKGROUND",
        @"40 邮件提升的非活跃 ELEVATED_INACTIVE",
        @"50 电话相关 PHONE",
        @"80 UI支持 UI_SUPPORT",
        @"90 前台支持 FOREGROUND_SUPPORT",
        @"100 前台 FOREGROUND",
        @"120 音频配件 AUDIO_AND_ACCESSORY",
        @"130 管理协调进程 CONDUCTOR",
        @"150 Apple驱动 DRIVER_APPLE",
        @"160 主屏主界面相关 HOME",
        @"170 系统执行级 EXECUTIVE",
        @"180 重要 DEFAULT",
        @"190 关键电话 TELEPHONY",
        @"210 最大优先级 MAX",
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
                if (name.length && ![names containsObject:name]) [names addObject:name];
            }
        }
        free(procs);
    }
    return [names sortedArrayUsingSelector:@selector(compare:)];
}

+ (NSString *)subtitleForIdentifier:(NSString *)key config:(NSDictionary *)cfg {
    pid_t pid = 0;
    for (NSNumber *p in MCPidsForIdentifier(key)) { pid = p.intValue; break; }

    NSMutableArray *parts = [NSMutableArray array];
    [parts addObject:pid ? [NSString stringWithFormat:@"PID %d", pid] : @"进程未运行"];

    NSInteger prio = [cfg[@"JetsamPriority"] integerValue];
    NSInteger nice = [cfg[@"NiceValue"] integerValue];
    if (prio != -1) [parts addObject:[NSString stringWithFormat:@"Jetsam %d", (int)prio]];
    if (nice != 0)  [parts addObject:[NSString stringWithFormat:@"Nice %d", (int)nice]];

    NSInteger act = [cfg[@"MemLimitActive"] integerValue];
    NSInteger inact = [cfg[@"MemLimitInactive"] integerValue];
    if (act || inact) [parts addObject:[NSString stringWithFormat:@"%@/%@MB",
                                        [@(act) stringValue], [@(inact) stringValue]]];

    int locks = 0;
    for (NSString *k in cfg.allKeys)
        if ([k hasSuffix:@"Lock"] && [cfg[k] boolValue]) locks++;
    if (locks) [parts addObject:[NSString stringWithFormat:@"%d 项强锁", locks]];

    return [parts componentsJoinedByString:@" · "];
}

@end
