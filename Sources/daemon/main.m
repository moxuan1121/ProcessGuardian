/**
 * main.m —— memorycontrolre 守护进程（root LaunchDaemon）。
 *
 * 职责划分与原版一致：注入 SpringBoard 的 dylib 只负责在切前台时发一个 Darwin
 * 通知，所有配置读取、进程枚举和特权内核调用都在这里完成。这样做的直接好处是
 * 特权 API 只需要授予一个带 entitlement 的二进制，而不是每个被注入的进程。
 *
 * 运行结构：
 *   启动 -> 生成默认预设 -> 自我保护 -> 全量应用 -> 1800s 周期巡检
 *   Darwin 通知 -> debounce 队列（合并抖动）-> worker 队列（实际应用）
 *
 * 所有实际应用都汇聚到串行的 worker 队列，因此 sApplied / sLastApply 不需要
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
#import <mach/mach.h>

#import "../MCCommon.h"

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
/** key -> 最近一次应用时间（秒），实现 per-process CheckInterval 节流。 */
static NSMutableDictionary<NSString *, NSNumber *> *sLastApply;

static void MCForgetKey(NSString *key) {
    [sApplied removeObjectForKey:key];
    [sLastApply removeObjectForKey:key];
}

static void MCRememberKey(NSString *key, pid_t pid, MCProcessConfig *cfg) {
    sApplied[key] = @{ @"pid": @(pid),
                       @"name": MCProcessNameForPid(pid) ?: key,
                       @"cfg": [cfg dictionaryValue] };
    sLastApply[key] = @((long long)[[NSDate date] timeIntervalSince1970]);
}

static BOOL MCThrottledByKey(NSString *key, NSInteger interval) {
    if (interval <= 0) return NO;
    NSNumber *last = sLastApply[key];
    if (!last) return NO;
    return ((long long)[[NSDate date] timeIntervalSince1970] - last.longLongValue) < interval;
}

static void MCPublishStatus(BOOL enabled) {
    [MCCommon writeStatus:@{
        @"Enabled":     @(enabled),
        @"PID":         @((int)getpid()),
        @"LastUpdate":  [MCCommon timestampString],
        @"Processes":   [sApplied copy],
    }];
}

/* ------------------------------------------------------------ 内核调用封装 */

/**
 * 回读内核对某 PID 的真实 jetsam 优先级。
 *
 * 原版遍历 GET_PRIORITY_LIST 返回的整张链表；这里改用同一条命令的单 PID 形式
 * （pid != 0 时内核只回填一条 entry），少一次全表拷贝，判定结果一致。
 */
static BOOL MCReadKernelPriority(pid_t pid, int32_t *priority) {
    memorystatus_priority_entry_t entry;
    memset(&entry, 0, sizeof(entry));
    if (memorystatus_control(MEMORYSTATUS_CMD_GET_PRIORITY_LIST, pid, 0,
                             &entry, sizeof(entry)) != 0)
        return NO;                                  /* ESRCH：不在优先级表中 */
    if (priority) *priority = entry.priority;
    return YES;
}

/** 取目标进程的 task port。失败时 kr 回传给调用方写日志。 */
static BOOL MCCopyTaskForPid(pid_t pid, mach_port_t *task, kern_return_t *kr) {
    mach_port_t t = MACH_PORT_NULL;
    kern_return_t r = task_for_pid(mach_task_self(), pid, &t);
    *kr = r;
    if (r != KERN_SUCCESS || t == MACH_PORT_NULL) return NO;
    *task = t;
    return YES;
}

/** 三个 Mach 策略强锁共用的失败日志。 */
static void MCLogTaskPortFailure(NSString *tag, kern_return_t kr) {
    MCLog(@"[%@] 获取 task_port 失败 -> kr:%d (请检查 daemon.entitlements)", tag, kr);
}

/* ------------------------------------------------------------------ 恢复 */

/**
 * 把一个进程交还系统。用于「开关关闭」「配置里移除该进程」两种场景。
 * 只撤销当时确实开过的开关 —— 所以依赖 sApplied 里存的 cfg 快照。
 */
static void MCRestoreProcess(MCProcessConfig *cfg, pid_t pid) {
    MCLog(@"[恢复] 目标: %@ PID: %d", cfg.key, pid);

    memorystatus_memlimit_properties_t ml = {
        .memlimit_active   = MC_MEMLIMIT_DEFAULT,
        .memlimit_inactive = MC_MEMLIMIT_DEFAULT,
    };
    memorystatus_control(MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES, pid, 0, &ml, sizeof(ml));

    memorystatus_priority_properties_t pp = {0};
    memorystatus_control(MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES, pid, 0, &pp, sizeof(pp));
    memorystatus_control(MEMORYSTATUS_CMD_ELEVATED_INACTIVEJETSAMPRIORITY_DISABLE, pid, 0, NULL, 0);
    memorystatus_control(MEMORYSTATUS_CMD_SET_PROCESS_IS_FREEZABLE, pid, 1, NULL, 0);

    if (cfg.niceValue != 0) setpriority(PRIO_PROCESS, pid, 0);
    if (cfg.stripManaged)   memorystatus_control(MEMORYSTATUS_CMD_SET_PROCESS_IS_MANAGED, pid, 1, NULL, 0);
    if (cfg.dirtyTrackStrongLock) proc_track_dirty(pid, 0);
    MCLog(@"[内核] ：已被系统恢复");
}

/* ------------------------------------------------------------------ 应用 */

/* 显式内存上限始终是 fatal；超限杀进程优先于保活。 */
static void MCApplyMemLimits(MCProcessConfig *cfg, pid_t pid) {
    if (cfg.memLimitActive == 0 && cfg.memLimitInactive == 0) return;

    memorystatus_memlimit_properties_t ml = {0};
    ml.memlimit_active   = (int32_t)cfg.memLimitActive;
    ml.memlimit_inactive = (int32_t)cfg.memLimitInactive;
    if (cfg.memLimitActive > 0 || cfg.memLimitInactive > 0 || !cfg.highWaterMarkLock) {
        ml.memlimit_active_attr   |= MEMORYSTATUS_MEMLIMIT_ATTR_FATAL;
        ml.memlimit_inactive_attr |= MEMORYSTATUS_MEMLIMIT_ATTR_FATAL;
    }

    int err = memorystatus_control(MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES, pid, 0,
                                   &ml, sizeof(ml));
    if (err != 0) {
        MCLog(@"[内存限制] 目标 Act:%d Inact:%d -> [失败] err:%d",
              ml.memlimit_active, ml.memlimit_inactive, err);
        return;
    }

    memorystatus_memlimit_properties_t back = {0};
    if (memorystatus_control(MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES, pid, 0,
                             &back, sizeof(back)) != 0)
        back = ml;

    MCLog(@"[内存限制] 目标 Act:%d Inact:%d | 最终 Act:%d Inact:%d -> [成功]",
          ml.memlimit_active, ml.memlimit_inactive,
          back.memlimit_active, back.memlimit_inactive);
    if (back.memlimit_active != ml.memlimit_active ||
        back.memlimit_inactive != ml.memlimit_inactive)
        MCLog(@"[内核] ：已被系统覆盖 (设置:%d 实际:%d)",
              ml.memlimit_active, back.memlimit_active);
}

/* 防内存溢出秒杀：把 fatal 限额降级成 high water mark（超限只回收，不立刻杀）。 */
static void MCApplyHighWaterMark(MCProcessConfig *cfg, pid_t pid) {
    if (!cfg.highWaterMarkLock || cfg.memLimitActive > 0 || cfg.memLimitInactive > 0) return;

    int32_t mb = (int32_t)(cfg.memLimitInactive ?: cfg.memLimitActive);
    if (mb <= 0) {
        /* 没有显式限额时用内核换算出的默认值，避免把 0/-1 直接塞进 flags。 */
        int32_t converted = 0;
        if (memorystatus_control(MEMORYSTATUS_CMD_CONVERT_MEMLIMIT_MB, pid, 0,
                                 &converted, sizeof(converted)) == 0)
            mb = converted;
    }
    if (mb <= 0) {
        MCLog(@"[防内存溢出秒杀] -> [跳过(无法确定限额)] err:0");
        return;
    }
    int err = memorystatus_control(MEMORYSTATUS_CMD_SET_JETSAM_HIGH_WATER_MARK, pid,
                                   (uint32_t)mb, NULL, 0);
    MCLog(@"[防内存溢出秒杀] -> [%s] err:%d", err == 0 ? "成功" : "失败", err);
}

/* jetsam 优先级。-1=不动，0=交还系统接管，其余=强设。 */
static void MCApplyJetsamPriority(MCProcessConfig *cfg, pid_t pid) {
    if (cfg.jetsamPriority == -1) {
        MCLog(@"[内存优先级] 目标:-1 -> 未设置, 跳过");
        return;
    }
    if (cfg.jetsamPriority == 0)
        MCLog(@"[内存优先级] 目标:0 -> [恢复默认, 系统接管]");

    /* 托管进程的设置会被 assertiond 随时覆写，先剥离再设值才有意义。 */
    if (cfg.stripManaged)
        memorystatus_control(MEMORYSTATUS_CMD_SET_PROCESS_IS_MANAGED, pid, 0, NULL, 0);

    memorystatus_priority_properties_t pp = { .priority = (int32_t)cfg.jetsamPriority };
    int err = memorystatus_control(MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES, pid, 0,
                                   &pp, sizeof(pp));
    if (err != 0) {
        MCLog(@"[系统] 内存优先级:%d -> [内核: 失败] err:%d", pp.priority, err);
        return;
    }
    MCLog(@"[系统] 设定进程优先级 -> [内核: 成功]");

    int32_t actual = 0;
    if (!MCReadKernelPriority(pid, &actual)) {
        MCLog(@"[内存优先级] 未在内核优先级列表中找到 PID:%d", pid);
        return;
    }
    if (actual != pp.priority) {
        MCLog(@"[内核] ：已被系统覆盖 (设置:%d 实际:%d)", pp.priority, actual);
        MCLog(@"[环境适配] 目标 %d -> 实际 %d", pp.priority, actual);
    } else {
        MCLog(@"[内核] ：系统接管并分配真实优先级为 %d", actual);
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

/*
 * 脏数据强锁：置 TRACK、清掉 ALLOW_IDLE_EXIT，阻止系统在后台把进程直接空闲退出。
 * 必须读-改-写：直接 proc_track_dirty(pid, PROC_DIRTY_TRACK) 会覆盖掉
 * DEFER / LAUNCH_IN_PROGRESS 等由内核自己维护的位。
 */
static void MCApplyDirtyTrack(MCProcessConfig *cfg, pid_t pid) {
    if (!cfg.dirtyTrackStrongLock) return;

    int state = 0;
    if (proc_dirty_details(pid, &state) != 0) {
        MCLog(@"[脏数据强锁] 阻止 Idle Exit -> [内核:失败] err:%d", errno);
        return;
    }
    int next = (state & ~(PROC_DIRTY_ALLOW_IDLE_EXIT | PROC_DIRTY_TRACK)) | PROC_DIRTY_TRACK;
    if (proc_track_dirty(pid, (uint32_t)next) != 0) {
        MCLog(@"[脏数据强锁] 阻止 Idle Exit -> [内核:失败] err:%d", errno);
        return;
    }
    MCLog(@"[脏数据强锁] 阻止 Idle Exit -> [内核:成功] err:0");
}

/* Mach 调度强锁：让内核把该进程按前台应用调度。 */
static void MCApplyMachForeground(MCProcessConfig *cfg, pid_t pid) {
    if (!cfg.machForegroundLock) return;

    mach_port_t task = MACH_PORT_NULL;
    kern_return_t kr = KERN_FAILURE;
    if (!MCCopyTaskForPid(pid, &task, &kr)) {
        MCLogTaskPortFailure(@"Mach调度强锁", kr);
        return;
    }
    integer_t role = TASK_FOREGROUND_APPLICATION;
    kern_return_t r = task_policy_set(task, TASK_CATEGORY_POLICY, (task_policy_t)&role,
                                      MC_TASK_CATEGORY_POLICY_COUNT);
    MCLog(@"[Mach调度强锁] 注入前台应用身份 -> [%s] kr:%d",
          r == KERN_SUCCESS ? "内核:成功" : "内核:失败", r);

    /* Mach category 与 Darwin role 是两条独立通路，两条都打才算钉住前台身份。 */
    setpriority(PRIO_DARWIN_ROLE, pid, PRIO_DARWIN_ROLE_UI_FOCAL);
    mach_port_deallocate(mach_task_self(), task);
}

/* GPU 保活：允许后台渲染，否则一切到后台就掉帧。 */
static void MCApplyGPURender(MCProcessConfig *cfg, pid_t pid) {
    if (!cfg.gpuRenderLock) return;
    int err = setpriority(PRIO_DARWIN_GPU, pid, PRIO_DARWIN_GPU_ALLOW);
    MCLog(@"[GPU保活强锁] 后台渲染 -> [%s] err:%d",
          err == 0 ? "内核:成功" : "内核:失败", err);
}

/* I/O 提权：解除 Darwin BG 节流 + 磁盘策略升到 IMPORTANT。 */
static void MCApplyIOBoost(MCProcessConfig *cfg, pid_t pid) {
    if (!cfg.ioBoostLock) return;
    int e1 = setpriority(PRIO_DARWIN_PROCESS, pid, 0);   /* 清掉 PRIO_DARWIN_BG */
    int e2 = setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, IOPOL_IMPORTANT);
    MCLog(@"[I/O提权] 解除后台资源节流 -> [Darwin:%s Disk:%s] err1:%d err2:%d",
          e1 == 0 ? "成功" : "失败", e2 == 0 ? "成功" : "失败", e1, e2);
}

/* 允许 coalition 的脏内存换出到磁盘，等价于给后台腾出更多可用内存。 */
static void MCApplyCoalitionSwappable(MCProcessConfig *cfg, pid_t pid) {
    if (!cfg.coalitionSwappableLock) return;

    int32_t swappable = 0;
    if (memorystatus_control(MEMORYSTATUS_CMD_GET_PROCESS_COALITION_IS_SWAPPABLE, pid, 0,
                             &swappable, sizeof(swappable)) == 0 && swappable) {
        MCLog(@"[虚拟内存Swap] 允许脏内存交换 -> [内核:已开启(系统默认)]");
        return;
    }
    int err = memorystatus_control(MEMORYSTATUS_CMD_MARK_PROCESS_COALITION_SWAPPABLE,
                                   pid, 0, NULL, 0);
    if (err == 0)           MCLog(@"[虚拟内存Swap] 允许脏内存交换 -> [内核:成功] err:0");
    else if (err == EINVAL) MCLog(@"[虚拟内存Swap] 允许脏内存交换 -> [内核:跳过(非进程组Leader)] err:%d", err);
    else if (err == ENOTSUP)MCLog(@"[虚拟内存Swap] 允许脏内存交换 -> [内核:跳过(设备不支持Swap)] err:%d", err);
    else                    MCLog(@"[虚拟内存Swap] 允许脏内存交换 -> [内核:失败] err:%d", err);
}

/* 关掉 wakeups / CPU 的 EXC_RESOURCE 监控，避免被系统以资源超标为名杀掉。 */
static void MCApplyResourceMonitors(MCProcessConfig *cfg, pid_t pid) {
    if (cfg.wakeupsMonitorLock) {
        struct mc_rlimit_control_wakeupmon wm = { .wm_flags = WAKEMON_DISABLE, .wm_rate = 0 };
        int err = proc_rlimit_control(pid, RLIMIT_WAKEUPS_MONITOR, &wm);
        MCLog(@"[禁用 EXC_RESOURCE](WAKEUPS) -> [%s] err:%d",
              err == 0 ? "内核:成功" : "内核:失败", err);
    }
    if (cfg.cpuUsageMonitorLock) {
        uint32_t flags = 0;                        /* 0 = 取消已注册的 CPU 监控 */
        int err = proc_rlimit_control(pid, RLIMIT_CPU_USAGE_MONITOR, &flags);
        if (err == 0)           MCLog(@"[禁用 EXC_RESOURCE](CPU) -> [内核:成功] err:0");
        else if (err == EINVAL) MCLog(@"[禁用 EXC_RESOURCE](CPU) -> [内核:跳过(进程默认无CPU限制)] err:%d", err);
        else                    MCLog(@"[禁用 EXC_RESOURCE](CPU) -> [内核:失败] err:%d", err);
    }
}

/* 吞吐量提权：OVERRIDE_QOS 拉高网络/磁盘吞吐，不改动 base QoS。 */
static void MCApplyThroughput(MCProcessConfig *cfg, pid_t pid) {
    if (!cfg.throughputQosLock) return;

    mach_port_t task = MACH_PORT_NULL;
    kern_return_t kr = KERN_FAILURE;
    if (!MCCopyTaskForPid(pid, &task, &kr)) {
        MCLogTaskPortFailure(@"Mach策略强锁", kr);
        return;
    }
    mc_task_qos_policy_t qos = {
        .task_latency_qos_tier   = MC_LATENCY_QOS_TIER_0,
        .task_throughput_qos_tier = MC_THROUGHPUT_QOS_TIER_0,
    };
    kern_return_t r = task_policy_set(task, TASK_OVERRIDE_QOS_POLICY, (task_policy_t)&qos,
                                      MC_TASK_QOS_POLICY_COUNT);
    MCLog(@"[吞吐量提权] 强制网络/磁盘最高吞吐 -> [%s] kr:%d",
          r == KERN_SUCCESS ? "内核:成功" : "内核:失败", r);
    mach_port_deallocate(mach_task_self(), task);
}

/* App Nap 会把长时间无 UI 交互的进程降到极慢，这里直接关掉。 */
static void MCApplySuppression(MCProcessConfig *cfg, pid_t pid) {
    if (!cfg.suppressionPolicyLock) return;

    mach_port_t task = MACH_PORT_NULL;
    kern_return_t kr = KERN_FAILURE;
    if (!MCCopyTaskForPid(pid, &task, &kr)) {
        MCLogTaskPortFailure(@"Mach策略强锁", kr);
        return;
    }
    mc_task_suppression_policy_t sp = { .suppression_status = 0 };
    kern_return_t r = task_policy_set(task, TASK_SUPPRESSION_POLICY, (task_policy_t)&sp,
                                      MC_TASK_SUPPRESSION_POLICY_COUNT);
    MCLog(@"[禁用 App Nap] 禁用 App Nap -> [%s] kr:%d",
          r == KERN_SUCCESS ? "内核:成功" : "内核:失败", r);
    mach_port_deallocate(mach_task_self(), task);
}

/*
 * Base QoS 提权。flavor 8 收 struct task_qos_policy（2 个 int），
 * 10/11 各收一个 tier。三条都设才不会被系统按 base 拉回。
 */
static void MCApplyBaseQoS(MCProcessConfig *cfg, pid_t pid) {
    if (!cfg.baseQosLock) return;

    mach_port_t task = MACH_PORT_NULL;
    kern_return_t kr = KERN_FAILURE;
    if (!MCCopyTaskForPid(pid, &task, &kr)) {
        MCLogTaskPortFailure(@"QoS提权", kr);
        return;
    }
    mc_task_qos_policy_t base = {
        .task_latency_qos_tier   = MC_LATENCY_QOS_TIER_0,
        .task_throughput_qos_tier = MC_THROUGHPUT_QOS_TIER_0,
    };
    int r8 = task_policy_set(task, TASK_BASE_QOS_POLICY, (task_policy_t)&base,
                             MC_TASK_QOS_POLICY_COUNT);
    integer_t lat = MC_LATENCY_QOS_TIER_0;
    int r10 = task_policy_set(task, TASK_BASE_LATENCY_QOS_POLICY, (task_policy_t)&lat, 1);
    integer_t thr = MC_THROUGHPUT_QOS_TIER_0;
    int r11 = task_policy_set(task, TASK_BASE_THROUGHPUT_QOS_POLICY, (task_policy_t)&thr, 1);

    MCLog(@"[QoS提权] 设定 Base QoS 为最高 -> [内核:%s] 8:%d 10:%d 11:%d",
          (r8 == 0 && r10 == 0 && r11 == 0) ? "成功" : "失败", r8, r10, r11);
    mach_port_deallocate(mach_task_self(), task);
}

/* 剥离系统托管标记。开启后系统不再有权随时改写我们的设置。 */
static void MCApplyStripManaged(MCProcessConfig *cfg, pid_t pid) {
    if (!cfg.stripManaged) return;
    int err = memorystatus_control(MEMORYSTATUS_CMD_SET_PROCESS_IS_MANAGED, pid, 0, NULL, 0);
    MCLog(@"[状态剥离] 目标: 剥离系统托管并开启强锁 -> [操作: %s] err: %d",
          err == 0 ? "内核:成功" : "内核:失败", err);
}

/* 后台保活的最后一环：inactive band 升到 ELEVATED_INACTIVE 并退出冻结候选。 */
static void MCApplyElevatedInactive(MCProcessConfig *cfg, pid_t pid) {
    if (cfg.jetsamPriority <= 0) return;
    memorystatus_control(MEMORYSTATUS_CMD_ELEVATED_INACTIVEJETSAMPRIORITY_ENABLE, pid, 0, NULL, 0);
    memorystatus_control(MEMORYSTATUS_CMD_SET_PROCESS_IS_FREEZABLE, pid, 0, NULL, 0);
}

static void MCApplyOne(MCProcessConfig *cfg, pid_t pid) {
    MCApplyStripManaged(cfg, pid);
    MCApplyMemLimits(cfg, pid);
    MCApplyHighWaterMark(cfg, pid);
    MCApplyJetsamPriority(cfg, pid);
    MCApplyNice(cfg, pid);
    MCApplyDirtyTrack(cfg, pid);
    MCApplyMachForeground(cfg, pid);
    MCApplyGPURender(cfg, pid);
    MCApplyIOBoost(cfg, pid);
    MCApplyCoalitionSwappable(cfg, pid);
    MCApplyResourceMonitors(cfg, pid);
    MCApplyThroughput(cfg, pid);
    MCApplySuppression(cfg, pid);
    MCApplyBaseQoS(cfg, pid);
    MCApplyElevatedInactive(cfg, pid);
}

/* ------------------------------------------------------------------ 主扫描 */

static void MCRefreshRuntimeLimits(void) {
    NSNumber *ls = [MCCommon readPreferences][@"LogSizeLimit"];
    if ([ls isKindOfClass:[NSNumber class]] && ls.doubleValue > 0)
        sLogSizeLimitMB = ls.doubleValue;
}

static MCProcessConfig *MCSnapshotConfigFor(NSString *key) {
    NSDictionary *rec = sApplied[key];
    return [MCProcessConfig configWithDictionary:rec[@"cfg"] key:key];
}

/**
 * 一轮全量巡检：
 *   1. 开关关闭 -> 全部恢复默认并挂起
 *   2. 配置里已移除的 key -> 恢复默认
 *   3. 每个 key 解析 PID；进程退出则 forget
 *   4. 存活进程按 CheckInterval 节流后应用
 */
static void MCRunSweep(void) {
    NSDictionary *prefs = [MCCommon readPreferences];
    BOOL enabled = [prefs[@"Enabled"] boolValue];

    if (!enabled) {
        for (NSString *key in [sApplied allKeys]) {
            pid_t pid = [sApplied[key][@"pid"] intValue];
            if (pid > 0) MCRestoreProcess(MCSnapshotConfigFor(key), pid);
            MCForgetKey(key);
        }
        MCPublishStatus(NO);
        MCLog(@"[配置] 生效开关已关闭，已挂起守护进程并还原默认状态");
        return;
    }

    NSDictionary<NSString *, MCProcessConfig *> *configs = [MCCommon parsedAppConfigs];

    for (NSString *key in [sApplied allKeys]) {
        if (configs[key]) continue;
        pid_t pid = [sApplied[key][@"pid"] intValue];
        MCLog(@"[配置] 已有进程从列表移除，已恢复默认");
        if (pid > 0) MCRestoreProcess(MCSnapshotConfigFor(key), pid);
        MCForgetKey(key);
    }

    for (NSString *key in configs) {
        MCProcessConfig *cfg = configs[key];
        if (![cfg hasAnythingToApply]) continue;

        NSArray<NSNumber *> *pids = MCPidsForIdentifier(key);
        NSNumber *tracked = sApplied[key][@"pid"];

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

        if (tracked.intValue == pid && MCThrottledByKey(key, cfg.checkInterval)) continue;

        MCLog(@"[守护] 目标: %@ | 检测: %lds | PID: %d", key,
              (long)(cfg.checkInterval ?: MCDefaultCheckInterval), pid);
        MCApplyOne(cfg, pid);
        MCRememberKey(key, pid, cfg);
        MCLog(@"[守护] %@ PID:%d 完成", key, pid);
    }

    MCPublishStatus(YES);
}

/* ------------------------------------------------------------------ 队列与事件 */

static dispatch_queue_t sWorkerQueue;    /* 串行：所有实际应用都在这里，天然互斥 */
static dispatch_source_t sDebounceTimer; /* 合并短时间内重复的前台切换通知 */

static void MCScheduleSweepAfter(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sDebounceTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, sWorkerQueue);
        dispatch_source_set_event_handler(sDebounceTimer, ^{ MCRunSweep(); });
        dispatch_resume(sDebounceTimer);
    });
    /* SpringBoard 连续切前台会产生一串通知；600ms 内的重复请求只留最后一次。 */
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
    memorystatus_priority_properties_t pp = { .priority = JETSAM_PRIORITY_MAX };
    int err = memorystatus_control(MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES, getpid(), 0,
                                   &pp, sizeof(pp));
    MCLog(@"[系统] 设定进程优先级 -> [内核:%s] err:%d",
          err == 0 ? "成功" : "失败", err);

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
    if (apps.count == 0) {
        prefs[@"AppConfigs"] = [MCCommon defaultAppConfigs];
        dirty = YES;
        MCLog(@"[配置] 已生成默认预设参数");
    }
    if (prefs[@"CheckInterval"] == nil) { prefs[@"CheckInterval"] = @(MCDefaultCheckInterval); dirty = YES; }
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
        sLastApply = [NSMutableDictionary dictionary];

        MCRefreshRuntimeLimits();
        MCLog(@"[守护] ProcessGuardian 后台守护进程初始化完成");
        MCLog(@"========================================");

        MCCheckAndGenerateDefaultConfig();
        MCProtectDaemonItself();

        sWorkerQueue = dispatch_queue_create("com.moxuan.processguardian.worker", NULL);

        int token = 0;
        if (notify_register_dispatch(MCApplyLimitsNotification.UTF8String, &token,
                                     sWorkerQueue, ^(int t) { MCScheduleSweepAfter(); }) != 0)
            MCLog(@"[守护] 通知注册失败，仅依赖周期巡检");

        MCRunSweep();

        /* 1800s 兜底巡检：即使没有前台切换事件，被系统悄悄覆写的设置也会被拉回来。 */
        dispatch_source_t sweep = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, sWorkerQueue);
        dispatch_source_set_timer(sweep, dispatch_time(DISPATCH_TIME_NOW,
                                                       (int64_t)MCDefaultCheckInterval * NSEC_PER_SEC),
                                  (uint64_t)MCDefaultCheckInterval * NSEC_PER_SEC, 60 * NSEC_PER_SEC);
        dispatch_source_set_event_handler(sweep, ^{
            MCRefreshRuntimeLimits();
            MCLog(@"[守护] 开始执行 %ds", (int)MCDefaultCheckInterval);
            MCRunSweep();
            MCLog(@"[全局守护] %ds 周期巡检完成。", (int)MCDefaultCheckInterval);
        });
        dispatch_resume(sweep);

        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
