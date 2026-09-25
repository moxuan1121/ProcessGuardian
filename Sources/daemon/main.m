/**
 * main.m —— memorycontrolre 守护进程（root LaunchDaemon）。
 *
 * 职责划分与原版一致：注入 SpringBoard 的 dylib 只负责在切前台时发一个 Darwin
 * 通知，所有配置读取、进程枚举和特权内核调用都在这里完成。这样做的直接好处是
 * 特权 API 只需要授予一个带 entitlement 的二进制，而不是每个被注入的进程。
 *
 * 运行结构：
 *   启动 -> 初始化配置 -> 自我保护 -> 全量应用 -> 1800s 兜底巡检
 *   Darwin 通知 -> debounce 队列（合并抖动）-> worker 队列（实际应用）
 *
 * 所有实际应用都汇聚到串行的 worker 队列，因此 sApplied 不需要
 * 额外加锁也不会被并发访问。
 */
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <notify.h>
#import <os/log.h>
#import <pthread.h>
#import <sys/resource.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <pwd.h>
#import <errno.h>
#import <string.h>
#import <signal.h>

#import "../MCCommon.h"
#import "../MCCPUGuard.h"

/* ------------------------------------------------------------------ 日志 */

static NSString *sLogFile;
/* C 里 extern const 不是常量表达式，不能作文件级初始化器，在 main 里赋值。 */
static double    sLogSizeLimitMB;
static pthread_mutex_t sLogLock = PTHREAD_MUTEX_INITIALIZER;

/** 时间戳由 MCLog 统一补齐，调用方只写业务部分。 */
__attribute__((format(NSString, 1, 2)))
static void MCLog(NSString *format, ...) {
    va_list ap;
    va_start(ap, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);

    NSString *line = [NSString stringWithFormat:@"[%@] %@", [MCCommon timestampString], body];

    pthread_mutex_lock(&sLogLock);
    @autoreleasepool {
        int fd = open([sLogFile fileSystemRepresentation], O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            /* 面板以 mobile 身份运行，「清空日志」要能截断这个文件，所以权限放到位。 */
            fchmod(fd, 0666);
            struct stat st;
            if (fstat(fd, &st) == 0 && sLogSizeLimitMB > 0 &&
                (double)st.st_size > sLogSizeLimitMB * 1024.0 * 1024.0) {
                ftruncate(fd, 0);
                lseek(fd, 0, SEEK_SET);
                NSString *rot = [NSString stringWithFormat:@"[%@] [守护] 日志大小超过设定限制(%.1fMB)，已自动清空。\n",
                                 [MCCommon timestampString], sLogSizeLimitMB];
                ssize_t w = write(fd, rot.UTF8String, strlen(rot.UTF8String)); (void)w;
            }
            const char *utf8 = line.UTF8String;
            ssize_t w1 = write(fd, utf8, strlen(utf8)); (void)w1;
            ssize_t w2 = write(fd, "\n", 1); (void)w2;
            close(fd);
        }
    }
    pthread_mutex_unlock(&sLogLock);

    os_log(OS_LOG_DEFAULT, "%{public}@", line);
}

/* ------------------------------------------------------------------ 状态 */

/**
 * 已应用配置的进程：key -> @{ @"pid", @"name", @"cfg" }。
 * 存 cfg 是因为「恢复默认」必须知道当初动过哪些开关，否则无从撤销。
 */
static NSMutableDictionary<NSString *, NSDictionary *> *sApplied;
static BOOL MCReadKernelPriority(pid_t pid, int32_t *priority);

static void MCForgetKey(NSString *key) {
    [sApplied removeObjectForKey:key];
}

static void MCRememberKey(NSString *key, pid_t pid, MCProcessConfig *cfg) {
    sApplied[key] = @{ @"pid": @(pid),
                       @"name": MCProcessNameForPid(pid) ?: key,
                       @"cfg": [cfg dictionaryValue] };
}

static void MCPublishStatus(BOOL enabled, NSDictionary *configs, NSDictionary *pidSnapshot) {
    NSMutableDictionary *processes = [NSMutableDictionary dictionary];
    for (NSString *key in configs) {
        NSMutableDictionary *entry = [sApplied[key] mutableCopy];
        if (!entry) {
            pid_t pid = [[pidSnapshot[key] firstObject] intValue];
            if (pid <= 0) continue;
            entry = [@{ @"pid": @(pid) } mutableCopy];
        }
        pid_t pid = [entry[@"pid"] intValue];
        int32_t priority = 0;
        if (pid > 0 && MCReadKernelPriority(pid, &priority)) entry[@"ActualJetsam"] = @(priority);
        errno = 0;
        int nice = pid > 0 ? getpriority(PRIO_PROCESS, pid) : 0;
        if (pid > 0 && errno == 0) entry[@"ActualNice"] = @(nice);
        processes[key] = entry;
    }
    [MCCommon writeStatus:@{
        @"Enabled":     @(enabled),
        @"PID":         @((int)getpid()),
        @"LastUpdate":  [MCCommon timestampString],
        @"Processes":   processes,
    }];
}

/* ------------------------------------------------------------ 内核调用封装 */

static int32_t MCTargetJetsamPriority(NSInteger configured) {
    return MCNativeJetsamPriority(configured,
        (int)[NSProcessInfo processInfo].operatingSystemVersion.majorVersion);
}

/**
 * 回读内核对某 PID 的真实 jetsam 优先级。
 *
 * 原版遍历 GET_PRIORITY_LIST 返回的整张链表；这里改用同一条命令的单 PID 形式
 * （pid != 0 时内核只回填一条 entry），少一次全表拷贝，判定结果一致。
 */
static BOOL MCReadKernelPriority(pid_t pid, int32_t *priority) {
    if (MCGetKernelPriority(pid, priority)) return YES;
    int error = errno;
    MCLog(@"[内存优先级] 读取失败 PID:%d errno:%d (%s)", pid, error, strerror(error));
    return NO;
}

/* ------------------------------------------------------------------ 恢复 */

/**
 * 把一个进程交还系统。用于「开关关闭」「配置里移除该进程」两种场景。
 * 只撤销当时确实开过的开关 —— 所以依赖 sApplied 里存的 cfg 快照。
 */
static void MCRestoreProcess(MCProcessConfig *cfg, pid_t pid) {
    MCLog(@"[恢复] 目标: %@ PID: %d", cfg.key, pid);

    if (cfg.memLimitActive || cfg.memLimitInactive) {
        memorystatus_memlimit_properties_t ml = {
            .memlimit_active = MC_MEMLIMIT_DEFAULT,
            .memlimit_inactive = MC_MEMLIMIT_DEFAULT,
        };
        memorystatus_control(MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES, pid, 0, &ml, sizeof(ml));
    }
    if (cfg.jetsamPriority != -1) {
        memorystatus_priority_properties_t pp = {0};
        memorystatus_control(MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES, pid, 0, &pp, sizeof(pp));
        if (cfg.jetsamPriority > 0) {
            memorystatus_control(MEMORYSTATUS_CMD_ELEVATED_INACTIVEJETSAMPRIORITY_DISABLE, pid, 0, NULL, 0);
            memorystatus_control(MEMORYSTATUS_CMD_SET_PROCESS_IS_FREEZABLE, pid, 1, NULL, 0);
        }
    }

    if (cfg.niceValue != 0) setpriority(PRIO_PROCESS, pid, 0);
    MCLog(@"[内核] ：已被系统恢复");
}

/* ------------------------------------------------------------------ 应用 */

/* 显式内存上限始终是 fatal；超限杀进程优先于保活。 */
static void MCApplyMemLimits(MCProcessConfig *cfg, pid_t pid) {
    if (cfg.memLimitActive == 0 && cfg.memLimitInactive == 0) return;

    memorystatus_memlimit_properties_t ml = {0};
    ml.memlimit_active   = (int32_t)cfg.memLimitActive;
    ml.memlimit_inactive = (int32_t)cfg.memLimitInactive;
    ml.memlimit_active_attr = MEMORYSTATUS_MEMLIMIT_ATTR_FATAL;
    ml.memlimit_inactive_attr = MEMORYSTATUS_MEMLIMIT_ATTR_FATAL;

    int err = memorystatus_control(MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES, pid, 0,
                                   &ml, sizeof(ml));
    if (err != 0) {
        int error = errno;
        MCLog(@"[内存限制] PID:%d 目标 Act:%d Inact:%d -> [失败] errno:%d (%s)",
              pid, ml.memlimit_active, ml.memlimit_inactive, error, strerror(error));
        return;
    }

    memorystatus_memlimit_properties_t back = {0};
    if (memorystatus_control(MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES, pid, 0,
                             &back, sizeof(back)) != 0) {
        int error = errno;
        MCLog(@"[内存限制] 写入已接受，但回读失败 PID:%d errno:%d (%s)", pid, error, strerror(error));
        return;
    }

    MCLog(@"[内存限制] 目标 Act:%d Inact:%d | 回读 Act:%d Inact:%d",
          ml.memlimit_active, ml.memlimit_inactive,
          back.memlimit_active, back.memlimit_inactive);
    if (back.memlimit_active != ml.memlimit_active ||
        back.memlimit_inactive != ml.memlimit_inactive)
        MCLog(@"[内核] ：已被系统覆盖 (设置:%d 实际:%d)",
              ml.memlimit_active, back.memlimit_active);
}

/* jetsam 优先级。-1=不动，0=交还系统接管，其余=强设。 */
static void MCApplyJetsamPriority(MCProcessConfig *cfg, pid_t pid) {
    if (cfg.jetsamPriority == -1) {
        MCLog(@"[内存优先级] 目标:-1 -> 未设置, 跳过");
        return;
    }
    if (cfg.jetsamPriority == 0)
        MCLog(@"[内存优先级] 目标:0 -> [恢复默认, 系统接管]");

    int32_t target = MCTargetJetsamPriority(cfg.jetsamPriority);
    if (target < 0) {
        MCLog(@"[内存优先级] 无效配置 PID:%d 配置:%ld，未写入", pid, (long)cfg.jetsamPriority);
        return;
    }
    if (target != cfg.jetsamPriority)
        MCLog(@"[内存优先级] 档位转换 PID:%d 配置:%ld -> 内核目标:%d", pid, (long)cfg.jetsamPriority, target);
    memorystatus_priority_properties_t pp = { .priority = target };
    int err = memorystatus_control(MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES, pid, 0,
                                   &pp, sizeof(pp));
    if (err != 0) {
        int error = errno;
        MCLog(@"[内存优先级] 写入失败 PID:%d 目标:%d 返回:%d errno:%d (%s)",
              pid, pp.priority, err, error, strerror(error));
        return;
    }

    int32_t actual = 0;
    if (!MCReadKernelPriority(pid, &actual)) {
        MCLog(@"[内存优先级] 写入已接受，但回读失败，无法确认生效 PID:%d", pid);
        return;
    }
    if (actual != pp.priority) {
        MCLog(@"[内存优先级] 回读不一致 PID:%d 目标:%d 实际:%d（内核策略或系统断言影响）",
              pid, pp.priority, actual);
    } else {
        MCLog(@"[内存优先级] 写入并回读一致 PID:%d 目标:%d 实际:%d", pid, pp.priority, actual);
    }
}

/* nice 值。先读当前值，已经是目标值就不重复设置。 */
static void MCApplyNice(MCProcessConfig *cfg, pid_t pid) {
    if (cfg.niceValue == 0) return;

    errno = 0;
    int cur = getpriority(PRIO_PROCESS, pid);
    if (errno != 0) {
        MCLog(@"[进程优先级] 读取状态失败 err:%d", errno);
        return;
    }
    if (cur == (int)cfg.niceValue) {
        MCLog(@"[进程优先级] 目标已是 %d", (int)cfg.niceValue);
        return;
    }

    errno = 0;
    if (setpriority(PRIO_PROCESS, pid, (int)cfg.niceValue) != 0) {
        MCLog(@"[进程优先级] 当前:%d 目标:%d -> [失败] err:%d", cur, (int)cfg.niceValue, errno);
        return;
    }
    MCLog(@"[进程优先级] 当前:%d 目标:%d -> [成功]", cur, (int)cfg.niceValue);
    errno = 0;
    int back = getpriority(PRIO_PROCESS, pid);
    if (errno == 0 && back != (int)cfg.niceValue)
        MCLog(@"[内核] ：已被系统恢复 (实际: %d)", back);
}

/* 后台保活的最后一环：inactive band 升到 ELEVATED_INACTIVE 并退出冻结候选。 */
static void MCApplyElevatedInactive(MCProcessConfig *cfg, pid_t pid) {
    if (cfg.jetsamPriority <= 0) return;
    memorystatus_control(MEMORYSTATUS_CMD_ELEVATED_INACTIVEJETSAMPRIORITY_ENABLE, pid, 0, NULL, 0);
    memorystatus_control(MEMORYSTATUS_CMD_SET_PROCESS_IS_FREEZABLE, pid, 0, NULL, 0);
}

static void MCApplyOne(MCProcessConfig *cfg, pid_t pid) {
    MCApplyMemLimits(cfg, pid);
    MCApplyJetsamPriority(cfg, pid);
    MCApplyNice(cfg, pid);
    MCApplyElevatedInactive(cfg, pid);
}

/* ------------------------------------------------------------------ 主扫描 */

static MCProcessConfig *MCSnapshotConfigFor(NSString *key) {
    NSDictionary *rec = sApplied[key];
    return [MCProcessConfig configWithDictionary:rec[@"cfg"] key:key];
}

/**
 * 一轮全量巡检：
 *   1. 开关关闭 -> 全部恢复默认并挂起
 *   2. 配置里已移除的 key -> 恢复默认
 *   3. 每个 key 解析 PID；进程退出则 forget
 *   4. 新 PID 或配置变化立即应用，定时兜底时强制复核
 */
static void MCRunSweep(BOOL force) {
  @autoreleasepool {
    NSDictionary *prefs = [MCCommon readPreferences];
    BOOL enabled = [prefs[@"Enabled"] boolValue];
    NSNumber *limit = prefs[@"LogSizeLimit"];
    if ([limit isKindOfClass:NSNumber.class] && limit.doubleValue > 0) sLogSizeLimitMB = limit.doubleValue;
    static NSDictionary *lastDisabledPreferences;
    if (!enabled) MCCPUGuardUpdate(@{}, @{}, NO, ^(NSString *message) { MCLog(@"%@", message); });
    if (!enabled && !force && !sApplied.count && [lastDisabledPreferences isEqual:prefs]) return;
    lastDisabledPreferences = enabled ? nil : prefs;
    NSDictionary *configs = [MCCommon parsedAppConfigsFromPreferences:prefs];
    NSMutableSet *keys = [NSMutableSet setWithArray:[configs allKeys]];
    [keys addObjectsFromArray:sApplied.allKeys];
    NSDictionary *pidSnapshot = MCPidsForIdentifiers(keys.allObjects);
    if (enabled) {
        NSMutableDictionary *cpuConfigs = [NSMutableDictionary dictionary];
        for (NSString *key in configs) cpuConfigs[key] = [configs[key] dictionaryValue];
        MCCPUGuardUpdate(cpuConfigs, pidSnapshot, YES, ^(NSString *message) { MCLog(@"%@", message); });
    }

    if (!enabled) {
        for (NSString *key in [sApplied allKeys]) {
            pid_t pid = [sApplied[key][@"pid"] intValue];
            if (pid > 0 && [pidSnapshot[key] containsObject:@(pid)]) MCRestoreProcess(MCSnapshotConfigFor(key), pid);
            MCForgetKey(key);
        }
        MCPublishStatus(NO, configs, pidSnapshot);
        MCLog(@"[配置] 生效开关已关闭，已挂起守护进程并还原默认状态");
        return;
    }

    for (NSString *key in [sApplied allKeys]) {
        if (configs[key]) continue;
        pid_t pid = [sApplied[key][@"pid"] intValue];
        MCLog(@"[配置] 已有进程从列表移除，已恢复默认");
        if (pid > 0 && [pidSnapshot[key] containsObject:@(pid)]) MCRestoreProcess(MCSnapshotConfigFor(key), pid);
        MCForgetKey(key);
    }

    for (NSString *key in configs) {
        MCProcessConfig *cfg = configs[key];
        NSArray<NSNumber *> *pids = pidSnapshot[key] ?: @[];
        NSNumber *tracked = sApplied[key][@"pid"];
        if (![cfg hasAnythingToApply]) {
            if (tracked && [pids containsObject:tracked]) MCRestoreProcess(MCSnapshotConfigFor(key), tracked.intValue);
            MCForgetKey(key);
            continue;
        }

        if (pids.count == 0) {
            if (tracked) {
                MCLog(@"[进程] 目标: %@ 已退出", key);
                MCForgetKey(key);
            }
            continue;
        }

        pid_t pid = pids.firstObject.intValue;
        if (tracked && tracked.intValue != pid)
            MCLog(@"[进程] 目标: %@ 已启动 PID: %d", key, pid);

        if (!force && tracked.intValue == pid &&
            [sApplied[key][@"cfg"] isEqual:[cfg dictionaryValue]]) {
            /* Lifecycle events must repair priority changes even when PID/config are unchanged. */
            int32_t actual = 0;
            if (cfg.jetsamPriority <= 0 ||
                (MCGetKernelPriority(pid, &actual) && actual == MCTargetJetsamPriority(cfg.jetsamPriority))) continue;
        }

        if (tracked.intValue == pid) {
            MCProcessConfig *previous = MCSnapshotConfigFor(key);
            if ((previous.niceValue && !cfg.niceValue) ||
                (previous.jetsamPriority != -1 && cfg.jetsamPriority == -1) ||
                (previous.memLimitActive && !cfg.memLimitActive) ||
                (previous.memLimitInactive && !cfg.memLimitInactive)) MCRestoreProcess(previous, pid);
        }
        MCLog(@"[守护] 目标: %@ | PID: %d", key, pid);
        MCApplyOne(cfg, pid);
        MCRememberKey(key, pid, cfg);
        MCLog(@"[守护] %@ PID:%d 完成", key, pid);
    }

    MCPublishStatus(YES, configs, pidSnapshot);
  }
}

/* ------------------------------------------------------------------ 队列与事件 */

static dispatch_queue_t sWorkerQueue;    /* 串行：所有实际应用都在这里，天然互斥 */
static dispatch_source_t sDebounceTimer; /* 合并短时间内重复的前台切换通知 */
static dispatch_source_t sLaunchdForkSource;
static dispatch_source_t sTerminationSource;
static BOOL sSweepPending;

static void MCScheduleSweepAfter(void) {
    if (sSweepPending) return;
    sSweepPending = YES;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sDebounceTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, sWorkerQueue);
        dispatch_source_set_event_handler(sDebounceTimer, ^{ sSweepPending = NO; MCRunSweep(NO); });
        dispatch_resume(sDebounceTimer);
    });
    /* 首次事件后 600ms 执行一次；后续事件合并，持续事件不会推迟巡检。 */
    dispatch_source_set_timer(sDebounceTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER, 0);
}

/* ------------------------------------------------------------------ 守护自身 */

/**
 * 把自己钉在回收队列最后。守护进程一旦被 jetsam 回收，所有锁定就没人维护，
 * 表现为「用着用着就失效」，所以这一步必须早于任何其它工作。
 */
static void MCProtectDaemonItself(void) {
    memorystatus_priority_properties_t pp = { .priority = MCTargetJetsamPriority(JETSAM_PRIORITY_MAX) };
    int err = memorystatus_control(MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES, getpid(), 0,
                                   &pp, sizeof(pp));
    int error = err == 0 ? 0 : errno;
    MCLog(@"[守护] 自身内存优先级 目标:%d 写入:%s errno:%d",
          pp.priority, err == 0 ? "已接受" : "失败", error);

    errno = 0;
    if (setpriority(PRIO_PROCESS, getpid(), PRIO_MIN) == 0)
        MCLog(@"[守护] 自身 nice 已设为最高 PID:%d", getpid());
    else
        MCLog(@"[守护] 自身 nice 设置失败 err:%d", errno);
}

/* ------------------------------------------------------------------ 配置初始化 */

/** 首次运行（或 AppConfigs 被清空）时写入默认预设。 */
static void MCCheckAndGenerateDefaultConfig(void) {
    NSString *path = [MCCommon preferencesPlistPath];
    NSMutableDictionary *prefs = [[MCCommon readPreferences] mutableCopy];

    NSDictionary *apps = prefs[@"AppConfigs"];
    if (![apps isKindOfClass:[NSDictionary class]]) apps = nil;

    BOOL dirty = NO;
    if (prefs[@"BackgroundRefresh"] != nil) {
        [prefs removeObjectForKey:@"BackgroundRefresh"];
        dirty = YES;
    }
    if (!apps) {
        prefs[@"AppConfigs"] = [MCCommon defaultAppConfigs];
        dirty = YES;
        MCLog(@"[配置] 已初始化空进程列表");
    }
    if (prefs[@"LogSizeLimit"]  == nil) { prefs[@"LogSizeLimit"]  = @(MCDefaultLogSizeLimitMB); dirty = YES; }
    if (prefs[@"Enabled"]       == nil) { prefs[@"Enabled"]       = @NO; dirty = YES; }

    if (dirty) {
        if (![prefs writeToFile:path atomically:YES]) MCLog(@"[配置] 默认预设写入失败: %@", path);
        else {
            struct passwd *mobile = getpwnam("mobile");
            if (mobile) chown(path.fileSystemRepresentation, mobile->pw_uid, mobile->pw_gid);
            chmod(path.fileSystemRepresentation, 0644);
        }
    }
}

/* ------------------------------------------------------------------ main */

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        sLogFile   = [MCCommon logFilePath];
        sLogSizeLimitMB = MCDefaultLogSizeLimitMB;
        sApplied   = [NSMutableDictionary dictionary];

        MCLog(@"[守护] ProcessGuardian 后台守护进程初始化完成");
        MCLog(@"========================================");

        MCCheckAndGenerateDefaultConfig();
        MCProtectDaemonItself();

        sWorkerQueue = dispatch_queue_create("com.moxuan.processguardian.worker", NULL);
        signal(SIGTERM, SIG_IGN);
        sTerminationSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, sWorkerQueue);
        dispatch_source_set_event_handler(sTerminationSource, ^{
            MCCPUGuardUpdate(@{}, @{}, NO, ^(NSString *message) { MCLog(@"%@", message); });
            exit(0);
        });
        dispatch_resume(sTerminationSource);

        int token = 0;
        if (notify_register_dispatch(MCApplyLimitsNotification.UTF8String, &token,
                                     sWorkerQueue, ^(int t) { MCScheduleSweepAfter(); }) != 0)
            MCLog(@"[守护] 通知注册失败，仅依赖周期巡检");

        dispatch_sync(sWorkerQueue, ^{ MCRunSweep(NO); });

        int processToken = 0;
        if (notify_register_dispatch(MCProcessChangedNotification.UTF8String, &processToken,
                                     sWorkerQueue, ^(int t) { MCScheduleSweepAfter(); }) != 0)
            MCLog(@"[守护] 进程通知注册失败，仅依赖 launchd 事件和周期巡检");

        /* launchd 创建系统进程时立即复核；不对进程表做短周期轮询。 */
        sLaunchdForkSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, 1,
                                                     DISPATCH_PROC_FORK, sWorkerQueue);
        if (sLaunchdForkSource) {
            dispatch_source_set_event_handler(sLaunchdForkSource, ^{ MCScheduleSweepAfter(); });
            dispatch_resume(sLaunchdForkSource);
        } else {
            MCLog(@"[守护] launchd 启动事件不可用，依赖应用通知和兜底巡检");
        }

        /* 1800s 兜底巡检：即使没有前台切换事件，被系统悄悄覆写的设置也会被拉回来。 */
        dispatch_source_t sweep = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, sWorkerQueue);
        dispatch_source_set_timer(sweep, dispatch_time(DISPATCH_TIME_NOW,
                                                       (int64_t)MCSweepInterval * NSEC_PER_SEC),
                                  (uint64_t)MCSweepInterval * NSEC_PER_SEC, 60 * NSEC_PER_SEC);
        dispatch_source_set_event_handler(sweep, ^{
            MCLog(@"[守护] 开始执行 %ds", (int)MCSweepInterval);
            MCRunSweep(YES);
            MCLog(@"[全局守护] %ds 周期巡检完成。", (int)MCSweepInterval);
        });
        dispatch_resume(sweep);

        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
