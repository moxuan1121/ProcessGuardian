// Process-wide sustained CPU use. All calls run on the daemon's serial worker queue.
#import "MCCPUGuard.h"
#import <libproc.h>
#import <libproc_internal.h>
#import <mach/mach_time.h>
#import <signal.h>
#import <time.h>

typedef struct {
    uint8_t uuid[16];
    uint64_t userTime, systemTime, packageIdleWakeups, interruptWakeups;
    uint64_t pageins, wiredSize, residentSize, physicalFootprint;
    uint64_t processStartAbsoluteTime, processExitAbsoluteTime;
} PGUsageV0;

static NSMutableDictionary<NSNumber *, NSMutableDictionary *> *sTargets;

static uint64_t PGNow(void) {
    struct timespec time = {0};
    clock_gettime(CLOCK_MONOTONIC, &time);
    return (uint64_t)time.tv_sec * NSEC_PER_SEC + time.tv_nsec;
}

static BOOL PGUsage(pid_t pid, uint64_t *cpu, uint64_t *start) {
    PGUsageV0 usage = {0};
    if (pid <= 1 || proc_pid_rusage(pid, RUSAGE_INFO_V0, &usage) != 0 ||
        !usage.processStartAbsoluteTime) return NO;
    if (cpu) *cpu = usage.userTime + usage.systemTime;
    if (start) *start = usage.processStartAbsoluteTime;
    return YES;
}

static NSString *PGPath(pid_t pid) {
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    return proc_pidpath(pid, path, sizeof(path)) > 0 ? @(path) : nil;
}

void MCCPUGuardUpdate(NSDictionary *configs, NSDictionary *pidSnapshot, BOOL enabled,
                      void (^log)(NSString *)) {
    if (!sTargets) sTargets = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSDictionary *> *wanted = [NSMutableDictionary dictionary];
    if (enabled) for (NSString *key in configs) {
        NSDictionary *cfg = configs[key];
        NSInteger threshold = [cfg[@"CPUThreshold"] integerValue];
        if (threshold < 2 || threshold > 100) continue;
        NSInteger duration = [cfg[@"CPUDuration"] integerValue];
        if (duration < 1 || duration > 3600) duration = 10;
        for (NSNumber *pid in pidSnapshot[key]) {
            if (pid.intValue <= 1 || pid.intValue == getpid()) continue;
            wanted[pid] = @{@"threshold": @(threshold), @"duration": @(duration)};
        }
    }
    for (NSNumber *pid in [sTargets.allKeys copy])
        if (!wanted[pid]) [sTargets removeObjectForKey:pid];
    for (NSNumber *pid in wanted) {
        uint64_t cpu = 0, start = 0;
        NSString *path = PGPath(pid.intValue);
        if (!path || !PGUsage(pid.intValue, &cpu, &start)) {
            [sTargets removeObjectForKey:pid];
            continue;
        }
        NSDictionary *old = sTargets[pid];
        if ([old[@"config"] isEqual:wanted[pid]] && [old[@"path"] isEqual:path] &&
            [old[@"start"] unsignedLongLongValue] == start) continue;
        sTargets[pid] = [@{@"config": wanted[pid], @"path": path, @"start": @(start),
                           @"cpu": @(cpu), @"wall": @(PGNow()), @"exceeded": @0} mutableCopy];
        log([NSString stringWithFormat:@"[CPU] 开始监测 PID:%@ 阈值:%@%% 持续:%@秒", pid,
             wanted[pid][@"threshold"], wanted[pid][@"duration"]]);
    }
}

BOOL MCCPUGuardHasTargets(void) { return sTargets.count > 0; }

void MCCPUGuardSample(void (^log)(NSString *)) {
    uint64_t now = PGNow();
    static mach_timebase_info_data_t timebase;
    if (!timebase.denom) mach_timebase_info(&timebase);
    if (!timebase.denom) return;
    for (NSNumber *pid in [sTargets.allKeys copy]) {
        NSMutableDictionary *target = sTargets[pid];
        uint64_t cpu = 0, start = 0;
        if (![PGPath(pid.intValue) isEqual:target[@"path"]] ||
            !PGUsage(pid.intValue, &cpu, &start) || start != [target[@"start"] unsignedLongLongValue]) {
            [sTargets removeObjectForKey:pid];
            continue;
        }
        uint64_t oldWall = [target[@"wall"] unsignedLongLongValue];
        uint64_t oldCPU = [target[@"cpu"] unsignedLongLongValue];
        if (now <= oldWall || cpu < oldCPU) {
            target[@"wall"] = @(now); target[@"cpu"] = @(cpu); target[@"exceeded"] = @0;
            continue;
        }
        uint64_t wall = now - oldWall;
        double percent = (double)(cpu - oldCPU) * timebase.numer / timebase.denom * 100.0 / wall;
        target[@"wall"] = @(now); target[@"cpu"] = @(cpu);
        double exceeded = percent >= [target[@"config"][@"threshold"] doubleValue]
                          ? [target[@"exceeded"] doubleValue] + (double)wall / NSEC_PER_SEC : 0;
        target[@"exceeded"] = @(exceeded);
        if (exceeded < [target[@"config"][@"duration"] doubleValue]) continue;
        if (![PGPath(pid.intValue) isEqual:target[@"path"]] ||
            !PGUsage(pid.intValue, NULL, &start) || start != [target[@"start"] unsignedLongLongValue]) {
            [sTargets removeObjectForKey:pid];
            continue;
        }
        if (kill(pid.intValue, SIGKILL) == 0) {
            log([NSString stringWithFormat:@"[CPU] PID:%@ 连续 %.1f 秒超过 %@%%，已终止（最近 %.1f%%）",
                 pid, exceeded, target[@"config"][@"threshold"], percent]);
            [sTargets removeObjectForKey:pid];
        } else {
            target[@"exceeded"] = @0;
        }
    }
}
