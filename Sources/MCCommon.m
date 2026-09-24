#import "MCCommon.h"
#import <dlfcn.h>
#import <libproc.h>
#import <libproc_internal.h>
#import <sys/sysctl.h>
#import <unistd.h>

NSString *const MCDomain                 = @"com.moxuan.processguardian";
NSString *const MCApplyLimitsNotification = @"com.moxuan.processguardian/ApplyLimits";
NSString *const MCStatusFileName          = @"com.moxuan.processguardian.status.plist";
NSString *const MCLogFileName             = @"ProcessGuardian.log";

const NSInteger MCDefaultCheckInterval = 1800;
const double    MCDefaultLogSizeLimitMB = 2.0;

/* ---------------------------------------------------------------- 配置模型 */

@implementation MCProcessConfig

+ (instancetype)configWithDictionary:(NSDictionary *)dict key:(NSString *)key {
    MCProcessConfig *c = [MCProcessConfig new];
    c.key = key ?: @"";
    if (![dict isKindOfClass:[NSDictionary class]]) return c;

    c.memLimitActive      = [dict[@"MemLimitActive"] integerValue];
    c.memLimitInactive    = [dict[@"MemLimitInactive"] integerValue];
    c.jetsamPriority      = dict[@"JetsamPriority"] ? [dict[@"JetsamPriority"] integerValue] : -1;
    c.niceValue           = dict[@"NiceValue"] ? [dict[@"NiceValue"] integerValue] : 0;
    c.checkInterval       = [dict[@"CheckInterval"] integerValue];
    c.cpuThreshold        = [dict[@"CPUThreshold"] integerValue];
    c.cpuDuration         = [dict[@"CPUDuration"] integerValue];
    c.keepAlive           = [dict[@"KeepAlive"] boolValue];
    c.relaunchAfterRespring = [dict[@"RelaunchAfterRespring"] boolValue];

    c.stripManaged          = [dict[@"StripManaged"] boolValue];
    c.dirtyTrackStrongLock  = [dict[@"DirtyTrackStrongLock"] boolValue];
    c.machForegroundLock    = [dict[@"MachForegroundLock"] boolValue];
    c.gpuRenderLock         = [dict[@"GPURenderLock"] boolValue];
    c.ioBoostLock           = [dict[@"IOBoostLock"] boolValue];
    c.highWaterMarkLock     = [dict[@"HighWaterMarkLock"] boolValue];
    c.coalitionSwappableLock = [dict[@"CoalitionSwappableLock"] boolValue];
    c.wakeupsMonitorLock    = [dict[@"WakeupsMonitorLock"] boolValue];
    c.cpuUsageMonitorLock   = [dict[@"CPUUsageMonitorLock"] boolValue];
    c.throughputQosLock     = [dict[@"ThroughputQoSLock"] boolValue];
    c.suppressionPolicyLock = [dict[@"SuppressionPolicyLock"] boolValue];
    c.baseQosLock           = [dict[@"BaseQoSLock"] boolValue];

    c.remark = [dict[@"Remark"] isKindOfClass:[NSString class]] ? dict[@"Remark"] : @"";
    return c;
}

+ (instancetype)defaultConfigForIdentifier:(NSString *)key {
    MCProcessConfig *c = [MCProcessConfig new];
    c.key = key ?: @"";
    c.jetsamPriority = -1;              /* -1 = 交还系统，不要设置 */
    c.remark = key ?: @"";
    return c;
}

- (NSDictionary *)dictionaryValue {
    return @{
        @"MemLimitActive":         @(self.memLimitActive),
        @"MemLimitInactive":       @(self.memLimitInactive),
        @"JetsamPriority":         @(self.jetsamPriority),
        @"NiceValue":              @(self.niceValue),
        @"CheckInterval":          @(self.checkInterval),
        @"CPUThreshold":           @(self.cpuThreshold),
        @"CPUDuration":            @(self.cpuDuration),
        @"KeepAlive":              @(self.keepAlive),
        @"RelaunchAfterRespring":   @(self.relaunchAfterRespring),
        @"StripManaged":           @(self.stripManaged),
        @"DirtyTrackStrongLock":   @(self.dirtyTrackStrongLock),
        @"MachForegroundLock":     @(self.machForegroundLock),
        @"GPURenderLock":          @(self.gpuRenderLock),
        @"IOBoostLock":            @(self.ioBoostLock),
        @"HighWaterMarkLock":      @(self.highWaterMarkLock),
        @"CoalitionSwappableLock": @(self.coalitionSwappableLock),
        @"WakeupsMonitorLock":     @(self.wakeupsMonitorLock),
        @"CPUUsageMonitorLock":    @(self.cpuUsageMonitorLock),
        @"ThroughputQoSLock":      @(self.throughputQosLock),
        @"SuppressionPolicyLock":  @(self.suppressionPolicyLock),
        @"BaseQoSLock":            @(self.baseQosLock),
        @"Remark":                 self.remark ?: @"",
    };
}

- (BOOL)hasAnythingToApply {
    if (self.memLimitActive != 0 || self.memLimitInactive != 0) return YES;
    if (self.jetsamPriority != -1) return YES;
    if (self.niceValue != 0) return YES;
    return self.stripManaged || self.dirtyTrackStrongLock || self.machForegroundLock ||
           self.gpuRenderLock || self.ioBoostLock || self.highWaterMarkLock ||
           self.coalitionSwappableLock || self.wakeupsMonitorLock ||
           self.cpuUsageMonitorLock || self.throughputQosLock ||
           self.suppressionPolicyLock || self.baseQosLock;
}

- (id)copyWithZone:(NSZone *)zone {
    MCProcessConfig *c = [MCProcessConfig new];
    c.key = [self.key copy];
    c.memLimitActive = _memLimitActive;
    c.memLimitInactive = _memLimitInactive;
    c.jetsamPriority = _jetsamPriority;
    c.niceValue = _niceValue;
    c.checkInterval = _checkInterval;
    c.cpuThreshold = _cpuThreshold;
    c.cpuDuration = _cpuDuration;
    c.keepAlive = _keepAlive;
    c.relaunchAfterRespring = _relaunchAfterRespring;
    c.stripManaged = _stripManaged;
    c.dirtyTrackStrongLock = _dirtyTrackStrongLock;
    c.machForegroundLock = _machForegroundLock;
    c.gpuRenderLock = _gpuRenderLock;
    c.ioBoostLock = _ioBoostLock;
    c.highWaterMarkLock = _highWaterMarkLock;
    c.coalitionSwappableLock = _coalitionSwappableLock;
    c.wakeupsMonitorLock = _wakeupsMonitorLock;
    c.cpuUsageMonitorLock = _cpuUsageMonitorLock;
    c.throughputQosLock = _throughputQosLock;
    c.suppressionPolicyLock = _suppressionPolicyLock;
    c.baseQosLock = _baseQosLock;
    c.remark = [self.remark copy];
    return c;
}

- (BOOL)isEqual:(id)object {
    if (![object isKindOfClass:[MCProcessConfig class]]) return NO;
    return [[(MCProcessConfig *)object dictionaryValue] isEqualToDictionary:[self dictionaryValue]];
}

@end

/* ---------------------------------------------------------------- 路径解析 */

typedef const char *(*MCStringReturnFn)(void);

@implementation MCCommon

+ (NSString *)jbRoot {
    static NSString *cached;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        /* rootless / palera1n 把整个越狱栈挪到 jbroot 之下，硬编码 /Library 会写错位置。
           libroot 是各越狱工具共同导出的查询接口，优先用它。 */
        void *h = dlopen("@rpath/libroot.dylib", RTLD_LAZY);
        if (!h) h = dlopen("/usr/lib/libroot.dylib", RTLD_LAZY);
        if (!h) h = dlopen("/var/jb/usr/lib/libroot.dylib", RTLD_LAZY);
        if (h) {
            MCStringReturnFn fn = (MCStringReturnFn)dlsym(h, "libroot_get_jbroot_prefix");
            const char *p = fn ? fn() : NULL;
            if (p && p[0]) {
                cached = [NSString stringWithUTF8String:p];
            } else {
                MCStringReturnFn fn2 = (MCStringReturnFn)dlsym(h, "libroot_get_root_prefix");
                const char *p2 = fn2 ? fn2() : NULL;
                if (p2 && p2[0]) cached = [NSString stringWithUTF8String:p2];
            }
        }
        if (!cached) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"]) cached = @"/var/jb";
            else if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/LIY"]) cached = @"/var/LIY";
            else cached = @"";
        }
    });
    return cached;
}

+ (NSString *)preferencesDirectory {
    return @"/var/mobile/Library/Preferences";
}

+ (NSString *)preferencesPlistPath {
    return [[self preferencesDirectory] stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.plist", MCDomain]];
}

+ (NSString *)statusPlistPath {
    return [[self preferencesDirectory] stringByAppendingPathComponent:MCStatusFileName];
}

+ (NSString *)logFilePath {
    /* /var/mobile 在 rootless 下同样是共享目录，不在 jbroot 内，因此不加前缀。
       放在这里而不是 /var/jb 下，偏好面板（mobile 身份）才读得到。 */
    NSString *dir = @"/var/mobile/Library/Logs";
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return [dir stringByAppendingPathComponent:MCLogFileName];
}

+ (NSDictionary *)readPreferences {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:[self preferencesPlistPath]];
    return [d isKindOfClass:[NSDictionary class]] ? d : @{};
}

+ (NSDictionary *)readStatus {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:[self statusPlistPath]];
    return [d isKindOfClass:[NSDictionary class]] ? d : @{};
}

+ (void)writeStatus:(NSDictionary *)status {
    [(status ?: @{}) writeToFile:[self statusPlistPath] atomically:YES];
}

+ (NSDictionary<NSString *, MCProcessConfig *> *)parsedAppConfigs {
    NSDictionary *raw = [self readPreferences];
    NSDictionary *apps = [raw[@"AppConfigs"] isKindOfClass:[NSDictionary class]] ? raw[@"AppConfigs"] : @{};
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    [apps enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *cfg, BOOL *stop) {
        out[key] = [MCProcessConfig configWithDictionary:cfg key:key];
    }];
    return out;
}

+ (NSDictionary *)defaultAppConfigs {
    /* 守护进程自身的邻居进程一旦被降级会牵连整个系统，因此默认预设只给最保守的组合。 */
    return @{
        @"SpringBoard": @{
            @"MemLimitActive": @0, @"MemLimitInactive": @0,
            @"JetsamPriority": @(-1), @"NiceValue": @(-10), @"CheckInterval": @0,
            @"StripManaged": @YES, @"DirtyTrackStrongLock": @YES,
            @"MachForegroundLock": @NO, @"GPURenderLock": @NO, @"IOBoostLock": @YES,
            @"HighWaterMarkLock": @NO, @"CoalitionSwappableLock": @NO,
            @"WakeupsMonitorLock": @YES, @"CPUUsageMonitorLock": @YES,
            @"ThroughputQoSLock": @NO, @"SuppressionPolicyLock": @NO, @"BaseQoSLock": @NO,
            @"Remark": @"桌面",
        },
        @"backboardd": @{
            @"MemLimitActive": @0, @"MemLimitInactive": @0,
            @"JetsamPriority": @(-1), @"NiceValue": @0, @"CheckInterval": @0,
            @"StripManaged": @YES, @"DirtyTrackStrongLock": @NO,
            @"MachForegroundLock": @NO, @"GPURenderLock": @NO, @"IOBoostLock": @NO,
            @"HighWaterMarkLock": @NO, @"CoalitionSwappableLock": @NO,
            @"WakeupsMonitorLock": @NO, @"CPUUsageMonitorLock": @NO,
            @"ThroughputQoSLock": @NO, @"SuppressionPolicyLock": @NO, @"BaseQoSLock": @NO,
            @"Remark": @"触摸服务",
        },
        @"runningboardd": @{
            @"MemLimitActive": @0, @"MemLimitInactive": @0,
            @"JetsamPriority": @(-1), @"NiceValue": @0, @"CheckInterval": @0,
            @"StripManaged": @YES, @"DirtyTrackStrongLock": @NO,
            @"MachForegroundLock": @NO, @"GPURenderLock": @NO, @"IOBoostLock": @NO,
            @"HighWaterMarkLock": @NO, @"CoalitionSwappableLock": @NO,
            @"WakeupsMonitorLock": @NO, @"CPUUsageMonitorLock": @NO,
            @"ThroughputQoSLock": @NO, @"SuppressionPolicyLock": @NO, @"BaseQoSLock": @NO,
            @"Remark": @"进程生命周期",
        },
        @"dasd": @{
            @"MemLimitActive": @0, @"MemLimitInactive": @0,
            @"JetsamPriority": @(-1), @"NiceValue": @0, @"CheckInterval": @0,
            @"StripManaged": @NO, @"DirtyTrackStrongLock": @NO,
            @"MachForegroundLock": @NO, @"GPURenderLock": @NO, @"IOBoostLock": @NO,
            @"HighWaterMarkLock": @NO, @"CoalitionSwappableLock": @NO,
            @"WakeupsMonitorLock": @NO, @"CPUUsageMonitorLock": @NO,
            @"ThroughputQoSLock": @NO, @"SuppressionPolicyLock": @NO, @"BaseQoSLock": @NO,
            @"Remark": @"调度守护",
        },
        @"kbd": @{
            @"MemLimitActive": @0, @"MemLimitInactive": @0,
            @"JetsamPriority": @(-1), @"NiceValue": @0, @"CheckInterval": @0,
            @"StripManaged": @NO, @"DirtyTrackStrongLock": @NO,
            @"MachForegroundLock": @NO, @"GPURenderLock": @NO, @"IOBoostLock": @NO,
            @"HighWaterMarkLock": @NO, @"CoalitionSwappableLock": @NO,
            @"WakeupsMonitorLock": @NO, @"CPUUsageMonitorLock": @NO,
            @"ThroughputQoSLock": @NO, @"SuppressionPolicyLock": @NO, @"BaseQoSLock": @NO,
            @"Remark": @"键盘",
        },
        @"sharingd": @{
            @"MemLimitActive": @0, @"MemLimitInactive": @0,
            @"JetsamPriority": @(-1), @"NiceValue": @0, @"CheckInterval": @0,
            @"StripManaged": @NO, @"DirtyTrackStrongLock": @NO,
            @"MachForegroundLock": @NO, @"GPURenderLock": @NO, @"IOBoostLock": @NO,
            @"HighWaterMarkLock": @NO, @"CoalitionSwappableLock": @NO,
            @"WakeupsMonitorLock": @NO, @"CPUUsageMonitorLock": @NO,
            @"ThroughputQoSLock": @NO, @"SuppressionPolicyLock": @NO, @"BaseQoSLock": @NO,
            @"Remark": @"共享服务",
        },
        @"com.tencent.xin": @{
            @"MemLimitActive": @0, @"MemLimitInactive": @0,
            @"JetsamPriority": @(-1), @"NiceValue": @0, @"CheckInterval": @0,
            @"StripManaged": @NO, @"DirtyTrackStrongLock": @NO,
            @"MachForegroundLock": @NO, @"GPURenderLock": @NO, @"IOBoostLock": @NO,
            @"HighWaterMarkLock": @NO, @"CoalitionSwappableLock": @NO,
            @"WakeupsMonitorLock": @NO, @"CPUUsageMonitorLock": @NO,
            @"ThroughputQoSLock": @NO, @"SuppressionPolicyLock": @NO, @"BaseQoSLock": @NO,
            @"Remark": @"微信",
        },
    };
}

+ (NSString *)timestampString {
    static NSDateFormatter *fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [NSDateFormatter new];
        fmt.dateFormat = @"MM-dd HH:mm:ss";
    });
    return [fmt stringFromDate:[NSDate date]];
}

@end

/* ---------------------------------------------------------------- 进程枚举 */

static NSArray<NSNumber *> *MCAllPids(void) {
    int n = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (n <= 0) return @[];
    NSMutableArray<NSNumber *> *pids = [NSMutableArray array];
    NSUInteger cap = n / sizeof(pid_t) * 2;
    pid_t *buf = calloc(cap, sizeof(pid_t));
    n = proc_listpids(PROC_ALL_PIDS, 0, buf, (int)(cap * sizeof(pid_t)));
    if (n > 0) {
        for (int i = 0; i < n / (int)sizeof(pid_t); i++)
            if (buf[i]) [pids addObject:@(buf[i])];
    }
    free(buf);
    return pids;
}

NSString *MCProcessNameForPid(pid_t pid) {
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidpath(pid, path, sizeof(path)) <= 0) return nil;
    return [@(path) lastPathComponent];
}

NSString *MCBundleIdForPid(pid_t pid) {
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidpath(pid, path, sizeof(path)) <= 0) return nil;
    NSString *exe = @(path);
    /* 主程序在 Foo.app/Foo，扩展在 Foo.app/PlugIns/Bar.appex/Bar —— 都要向上找到 .app */
    NSRange app = [exe rangeOfString:@".app" options:NSBackwardsSearch];
    if (app.location == NSNotFound) return nil;
    NSString *appBundle = [exe substringToIndex:app.location + app.length];
    if (![appBundle hasSuffix:@".app"]) {
        NSRange cut = [appBundle rangeOfString:@".app"];
        appBundle = [appBundle substringToIndex:cut.location + cut.length];
    }
    NSString *info = [appBundle stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:info];
    id bid = d[@"CFBundleIdentifier"];
    return [bid isKindOfClass:[NSString class]] ? bid : nil;
}

NSArray<NSNumber *> *MCPidsForIdentifier(NSString *identifier) {
    if (identifier.length == 0) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (NSNumber *pn in MCAllPids()) {
        pid_t pid = pn.intValue;
        NSString *name = MCProcessNameForPid(pid);
        if (name && [name isEqualToString:identifier]) { [out addObject:pn]; continue; }
        NSString *bid = MCBundleIdForPid(pid);
        if (bid && [bid isEqualToString:identifier]) [out addObject:pn];
    }
    return out;
}
