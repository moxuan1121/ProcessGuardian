// Native fatal CPU limits, applied on the daemon's existing serial worker queue.
#import "MCCPUGuard.h"
#import <libproc.h>
#import <libproc_internal.h>
#import <errno.h>
#import <string.h>
#import <dlfcn.h>

static NSMutableDictionary<NSNumber *, NSDictionary *> *sMonitors;

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
    for (NSNumber *pid in [sMonitors.allKeys copy]) {
        NSDictionary *record = sMonitors[pid];
        BOOL sameProcess = [record[@"identity"] isEqual:PGIdentity(pid.intValue)];
        if (sameProcess && [record[@"config"] isEqual:targets[pid]]) continue;
        if (sameProcess) {
            if (!disableMonitor || disableMonitor(pid.intValue) != 0) {
                int error = disableMonitor ? errno : ENOSYS;
                log([NSString stringWithFormat:@"[CPU] 停用失败 PID:%@ errno:%d (%s)，保留记录等待重试", pid, error, strerror(error)]);
                continue;
            }
            log([NSString stringWithFormat:@"[CPU] 已停用 PID:%@", pid]);
        }
        [sMonitors removeObjectForKey:pid];
    }
    for (NSNumber *pid in targets) {
        if (sMonitors[pid]) continue;
        NSDictionary *identity = PGIdentity(pid.intValue);
        if (!identity) continue;
        if (!setMonitor || !disableMonitor) {
            log(@"[CPU] 内核接口不可用，未启用 CPU 检测");
            break;
        }
        NSDictionary *cfg = targets[pid];
        if (setMonitor(pid.intValue, [cfg[@"threshold"] intValue], [cfg[@"duration"] intValue]) != 0) {
            int error = errno;
            log([NSString stringWithFormat:@"[CPU] 内核设置失败 PID:%@ errno:%d (%s)", pid, error, strerror(error)]);
            continue;
        }
        sMonitors[pid] = @{@"identity": identity, @"config": cfg};
        log([NSString stringWithFormat:@"[CPU] 内核致命限额已接受 PID:%@ 阈值:%@%% 窗口:%@秒（前后台生效）", pid, cfg[@"threshold"], cfg[@"duration"]]);
    }
}
