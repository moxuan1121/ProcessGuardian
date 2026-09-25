// Native fatal CPU limits, applied on the daemon's existing serial worker queue.
#import "MCCPUGuard.h"
#import <libproc.h>
#import <libproc_internal.h>
#import <errno.h>
#import <string.h>
#import <dlfcn.h>

static NSMutableDictionary<NSNumber *, NSDictionary *> *sMonitors;
static NSMutableDictionary<NSNumber *, NSDictionary *> *sFailures;

static void PGReportFailure(NSNumber *pid, NSDictionary *identity, NSDictionary *cfg,
                            NSString *message, void (^log)(NSString *)) {
    NSDictionary *failure = @{@"identity": identity ?: @{}, @"config": cfg ?: @{}, @"message": message};
    if (![sFailures[pid] isEqual:failure]) log(message);
    sFailures[pid] = failure;
}

static NSDictionary *PGIdentity(pid_t pid) {
    if (pid <= 1) return nil;
    struct vdt_proc_bsdinfo info = {0};
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidinfo(pid, VDT_PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)
        || info.pbi_status == 5 || proc_pidpath(pid, path, sizeof(path)) <= 0) return nil;
    return @{@"path": @(path), @"seconds": @(info.pbi_start_tvsec), @"micros": @(info.pbi_start_tvusec)};
}

void MCCPUGuardUpdate(NSDictionary *configs, NSDictionary *pidSnapshot, BOOL enabled,
                      void (^log)(NSString *)) {
    if (!sMonitors) sMonitors = [NSMutableDictionary dictionary];
    if (!sFailures) sFailures = [NSMutableDictionary dictionary];
    NSMutableDictionary *targets = [NSMutableDictionary dictionary];
    if (enabled) {
        for (NSString *key in [configs.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            NSDictionary *cfg = configs[key];
            NSInteger threshold = [cfg[@"CPUThreshold"] integerValue];
            if (!threshold) continue;
            if (threshold < 2 || threshold > 100) {
                log([NSString stringWithFormat:@"[CPU] %@ 阈值:%ld 无效，内核支持 2～100%%", key, (long)threshold]);
                continue;
            }
            NSInteger duration = [cfg[@"CPUDuration"] integerValue];
            if (duration < 1 || duration > 3600) duration = 10;
            NSNumber *pid = [pidSnapshot[key] firstObject];
            if (pid.intValue <= 1) continue;
            targets[pid] = @{@"threshold": @(threshold), @"duration": @(duration)};
        }
    }
    int (*setMonitor)(int, int, int) = dlsym(RTLD_DEFAULT, "proc_set_cpumon_params_fatal");
    int (*disableMonitor)(int) = dlsym(RTLD_DEFAULT, "proc_disable_cpumon");
    int (*getMonitor)(int, int *, int *) = dlsym(RTLD_DEFAULT, "proc_get_cpumon_params");
    int (*restoreMonitor)(int, int, int) = dlsym(RTLD_DEFAULT, "proc_set_cpumon_params");
    for (NSNumber *pid in [sFailures.allKeys copy])
        if (!targets[pid] && !sMonitors[pid]) [sFailures removeObjectForKey:pid];
    for (NSNumber *pid in [sMonitors.allKeys copy]) {
        NSDictionary *record = sMonitors[pid];
        BOOL sameProcess = [record[@"identity"] isEqual:PGIdentity(pid.intValue)];
        if (sameProcess && [record[@"config"] isEqual:targets[pid]]) continue;
        if (sameProcess) {
            NSDictionary *pendingRestore = record[@"restore"];
            int result = -1;
            errno = ENOSYS;
            if (pendingRestore && restoreMonitor)
                result = restoreMonitor(pid.intValue, [pendingRestore[@"threshold"] intValue], [pendingRestore[@"duration"] intValue]);
            else if (!pendingRestore && disableMonitor) result = disableMonitor(pid.intValue);
            if (result != 0) {
                int error = errno;
                PGReportFailure(pid, record[@"identity"], targets[pid],
                    [NSString stringWithFormat:@"[CPU] %@失败 PID:%@ errno:%d (%s)，保留记录等待重试", pendingRestore ? @"恢复原参数" : @"停用", pid, error, strerror(error)], log);
                continue;
            }
            log([NSString stringWithFormat:@"[CPU] %@ PID:%@", pendingRestore ? @"已恢复原参数" : @"已停用", pid]);
        }
        [sMonitors removeObjectForKey:pid];
    }
    for (NSNumber *pid in targets) {
        if (sMonitors[pid]) continue;
        NSDictionary *identity = PGIdentity(pid.intValue);
        if (!identity) continue;
        if (!setMonitor || !disableMonitor || !getMonitor || !restoreMonitor) {
            PGReportFailure(pid, identity, targets[pid], @"[CPU] 内核接口不可用，未启用 CPU 检测", log);
            break;
        }
        NSDictionary *cfg = targets[pid];
        int result = setMonitor(pid.intValue, [cfg[@"threshold"] intValue], [cfg[@"duration"] intValue]);
        if (result != 0 && errno == EBUSY) {
            // libproc's fatal wrapper rejects an existing monitor before writing anything.
            // Replace only an explicitly configured target, after saving its old parameters.
            int oldThreshold = 0, oldDuration = 0;
            if (getMonitor(pid.intValue, &oldThreshold, &oldDuration) == 0 &&
                oldThreshold > 0 && oldDuration > 0 &&
                [identity isEqual:PGIdentity(pid.intValue)] && disableMonitor(pid.intValue) == 0) {
                result = setMonitor(pid.intValue, [cfg[@"threshold"] intValue], [cfg[@"duration"] intValue]);
                if (result != 0) {
                    int error = errno;
                    if ([identity isEqual:PGIdentity(pid.intValue)] &&
                        restoreMonitor(pid.intValue, oldThreshold, oldDuration) != 0) {
                        sMonitors[pid] = @{@"identity": identity, @"config": @{},
                            @"restore": @{@"threshold": @(oldThreshold), @"duration": @(oldDuration)}};
                        PGReportFailure(pid, identity, cfg,
                            [NSString stringWithFormat:@"[CPU] 替换失败且原参数恢复失败 PID:%@，保留原参数等待重试", pid], log);
                        continue;
                    }
                    errno = error;
                }
            }
        }
        if (result != 0) {
            int error = errno;
            PGReportFailure(pid, identity, cfg,
                [NSString stringWithFormat:@"[CPU] 内核设置失败 PID:%@ errno:%d (%s)", pid, error, strerror(error)], log);
            continue;
        }
        sMonitors[pid] = @{@"identity": identity, @"config": cfg};
        int actualThreshold = 0, actualDuration = 0;
        if (getMonitor(pid.intValue, &actualThreshold, &actualDuration) != 0 ||
            actualThreshold != [cfg[@"threshold"] intValue] || actualDuration != [cfg[@"duration"] intValue]) {
            PGReportFailure(pid, identity, cfg,
                [NSString stringWithFormat:@"[CPU] 致命限额已接受但回读未确认 PID:%@ 实际:%d%%/%d秒", pid, actualThreshold, actualDuration], log);
            continue;
        }
        [sFailures removeObjectForKey:pid];
        log([NSString stringWithFormat:@"[CPU] 内核致命限额已接受并回读一致 PID:%@ 阈值:%@%% 窗口:%@秒（前后台生效）", pid, cfg[@"threshold"], cfg[@"duration"]]);
    }
}
