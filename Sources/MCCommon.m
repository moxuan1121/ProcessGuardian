#import "MCCommon.h"
#import <libproc.h>
#import <libproc_internal.h>
#import <sys/sysctl.h>
#import <unistd.h>
#import <roothide.h>

NSString *const MCDomain                 = @"com.moxuan.processguardian";
NSString *const MCApplyLimitsNotification = @"com.moxuan.processguardian/ApplyLimits";
NSString *const MCProcessChangedNotification = @"com.moxuan.processguardian/ProcessChanged";
NSString *const MCStatusFileName          = @"com.moxuan.processguardian.status.plist";
NSString *const MCLogFileName             = @"ProcessGuardian.log";

const NSInteger MCSweepInterval = 1800;
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
    c.cpuThreshold        = [dict[@"CPUThreshold"] integerValue];
    c.cpuDuration         = [dict[@"CPUDuration"] integerValue];
    c.keepAlive           = [dict[@"KeepAlive"] boolValue];
    c.relaunchAfterRespring = [dict[@"RelaunchAfterRespring"] boolValue];

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
        @"CPUThreshold":           @(self.cpuThreshold),
        @"CPUDuration":            @(self.cpuDuration),
        @"KeepAlive":              @(self.keepAlive),
        @"RelaunchAfterRespring":   @(self.relaunchAfterRespring),
        @"Remark":                 self.remark ?: @"",
    };
}

- (BOOL)hasAnythingToApply {
    if (self.memLimitActive != 0 || self.memLimitInactive != 0) return YES;
    if (self.jetsamPriority != -1) return YES;
    if (self.niceValue != 0) return YES;
    return NO;
}

- (id)copyWithZone:(NSZone *)zone {
    MCProcessConfig *c = [MCProcessConfig new];
    c.key = [self.key copy];
    c.memLimitActive = _memLimitActive;
    c.memLimitInactive = _memLimitInactive;
    c.jetsamPriority = _jetsamPriority;
    c.niceValue = _niceValue;
    c.cpuThreshold = _cpuThreshold;
    c.cpuDuration = _cpuDuration;
    c.keepAlive = _keepAlive;
    c.relaunchAfterRespring = _relaunchAfterRespring;
    c.remark = [self.remark copy];
    return c;
}

- (BOOL)isEqual:(id)object {
    if (![object isKindOfClass:[MCProcessConfig class]]) return NO;
    return [[(MCProcessConfig *)object dictionaryValue] isEqualToDictionary:[self dictionaryValue]];
}

@end

/* ---------------------------------------------------------------- 路径解析 */

@implementation MCCommon

+ (NSString *)preferencesDirectory {
    return jbroot(@"/var/mobile/Library/Preferences");
}

+ (NSString *)preferencesPlistPath {
    return [[self preferencesDirectory] stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.plist", MCDomain]];
}

+ (NSString *)statusPlistPath {
    return [[self preferencesDirectory] stringByAppendingPathComponent:MCStatusFileName];
}

+ (NSString *)logFilePath {
    /* RootHide 中守护进程与设置面板共用此目录。 */
    NSString *dir = jbroot(@"/var/mobile/Library/Logs");
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
    return [self parsedAppConfigsFromPreferences:[self readPreferences]];
}

+ (NSDictionary<NSString *, MCProcessConfig *> *)parsedAppConfigsFromPreferences:(NSDictionary *)raw {
    NSDictionary *apps = [raw[@"AppConfigs"] isKindOfClass:[NSDictionary class]] ? raw[@"AppConfigs"] : @{};
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    [apps enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *cfg, BOOL *stop) {
        out[key] = [MCProcessConfig configWithDictionary:cfg key:key];
    }];
    return out;
}

+ (NSDictionary *)defaultAppConfigs { return @{}; }

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
    if (!buf) return @[];
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

static NSString *MCBundlePathForExecutable(NSString *exe) {
    /* 主程序在 Foo.app/Foo，扩展在 Foo.app/PlugIns/Bar.appex/Bar —— 都要向上找到 .app */
    NSRange app = [exe rangeOfString:@".app" options:NSBackwardsSearch];
    if (app.location == NSNotFound) return nil;
    NSString *appBundle = [exe substringToIndex:app.location + app.length];
    return appBundle;
}

static NSString *MCBundleIdAtPath(NSString *bundlePath) {
    NSString *info = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:info];
    id bid = d[@"CFBundleIdentifier"];
    return [bid isKindOfClass:[NSString class]] ? bid : nil;
}

NSString *MCBundleIdForPid(pid_t pid) {
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidpath(pid, path, sizeof(path)) <= 0) return nil;
    NSString *bundlePath = MCBundlePathForExecutable(@(path));
    return bundlePath ? MCBundleIdAtPath(bundlePath) : nil;
}

NSArray<NSNumber *> *MCPidsForIdentifier(NSString *identifier) {
    if (identifier.length == 0) return @[];
    return MCPidsForIdentifiers(@[identifier])[identifier] ?: @[];
}

NSDictionary<NSString *, NSArray<NSNumber *> *> *MCPidsForIdentifiers(NSArray<NSString *> *identifiers) {
    if (!identifiers.count) return @{};
    NSSet *targets = [NSSet setWithArray:identifiers];
    NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *out = [NSMutableDictionary dictionary];
    NSMutableDictionary *bundleIds = [NSMutableDictionary dictionary];
    for (NSNumber *pn in MCAllPids()) {
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (proc_pidpath(pn.intValue, path, sizeof(path)) <= 0) continue;
        NSString *exe = @(path), *name = exe.lastPathComponent;
        NSString *bundlePath = MCBundlePathForExecutable(exe);
        id bid = bundlePath ? bundleIds[bundlePath] : nil;
        if (bundlePath && !bid) {
            bid = MCBundleIdAtPath(bundlePath) ?: [NSNull null];
            bundleIds[bundlePath] = bid;
        }
        NSArray *matches = [bid isEqual:name] ? @[name] : @[name, bid ?: [NSNull null]];
        for (id key in matches) {
            if (![targets containsObject:key]) continue;
            if (!out[key]) out[key] = [NSMutableArray array];
            [out[key] addObject:pn];
        }
    }
    return out;
}
