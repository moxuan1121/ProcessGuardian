// Adaptive sampling based on CPUOverloadKiller's policy (GPL-3.0).
// The root daemon owns one timer and serializes all updates and samples.
#import "MCCPUGuard.h"
#import "MCCommon.h"
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
static uint64_t sFrontmostHash;

static uint64_t PGNow(void) {
    struct timespec time = {0};
    clock_gettime(CLOCK_MONOTONIC, &time);
    return (uint64_t)time.tv_sec * NSEC_PER_SEC + time.tv_nsec;
}

static uint64_t PGHash(NSString *name) {
    uint64_t hash = 1469598103934665603ULL;
    const unsigned char *bytes = (const unsigned char *)name.UTF8String;
    for (; *bytes; bytes++) { hash ^= *bytes; hash *= 1099511628211ULL; }
    return hash;
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

static NSInteger PGValid(id value, NSInteger fallback, NSInteger low, NSInteger high) {
    NSInteger n = [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : fallback;
    return n < low || n > high ? fallback : n;
}

static BOOL PGAllowed(NSDictionary *target) {
    return ![target[@"app"] boolValue] || [target[@"background"] boolValue] ||
           [target[@"hash"] unsignedLongLongValue] == sFrontmostHash;
}

void MCCPUGuardSetFrontmostHash(uint64_t hash) {
    if (sFrontmostHash == hash) return;
    sFrontmostHash = hash;
    uint64_t now = PGNow();
    for (NSMutableDictionary *target in sTargets.allValues) {
        if (![target[@"app"] boolValue] || [target[@"background"] boolValue]) continue;
        target[@"cpu"] = @0; target[@"wall"] = @0;
        target[@"exceeded"] = @0; target[@"exceeding"] = @NO;
        target[@"due"] = PGAllowed(target) ? @(now) : @0;
    }
}

void MCCPUGuardUpdate(NSDictionary *configs, NSDictionary *pidSnapshot, BOOL enabled,
                      void (^log)(NSString *)) {
    if (!sTargets) sTargets = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSDictionary *> *wanted = [NSMutableDictionary dictionary];
    if (enabled) for (NSString *key in configs) {
        NSDictionary *cfg = configs[key];
        NSInteger threshold = [cfg[@"CPUThreshold"] integerValue];
        if (threshold < 2 || threshold > 1000) continue;
        NSInteger duration = PGValid(cfg[@"CPUDuration"], 10, 1, 3600);
        NSInteger idle = PGValid(cfg[@"CPUIdleSample"], 60, 1, 3600);
        NSInteger near = PGValid(cfg[@"CPUNearSample"], 15, 1, 3600);
        NSInteger ratio = PGValid(cfg[@"CPUNearRatio"], 67, 1, 99);
        NSInteger exceed = PGValid(cfg[@"CPUExceedSample"], 1, 1, duration);
        for (NSNumber *pid in pidSnapshot[key]) {
            if (pid.intValue <= 1 || pid.intValue == getpid()) continue;
            BOOL app = [MCBundleIdForPid(pid.intValue) isEqualToString:key];
            wanted[pid] = @{@"key": key, @"threshold": @(threshold), @"duration": @(duration),
                            @"idle": @(idle), @"near": @(near), @"ratio": @(ratio),
                            @"exceed": @(exceed), @"app": @(app),
                            @"background": @([cfg[@"CPUBackground"] boolValue]), @"hash": @(PGHash(key))};
        }
    }
    for (NSNumber *pid in [sTargets.allKeys copy])
        if (!wanted[pid]) [sTargets removeObjectForKey:pid];
    uint64_t now = PGNow();
    for (NSNumber *pid in wanted) {
        uint64_t start = 0;
        NSString *path = PGPath(pid.intValue);
        if (!path || !PGUsage(pid.intValue, NULL, &start)) {
            [sTargets removeObjectForKey:pid];
            continue;
        }
        NSDictionary *old = sTargets[pid];
        if ([old[@"config"] isEqual:wanted[pid]] && [old[@"path"] isEqual:path] &&
            [old[@"start"] unsignedLongLongValue] == start) continue;
        NSMutableDictionary *target = [wanted[pid] mutableCopy];
        target[@"config"] = wanted[pid]; target[@"path"] = path; target[@"start"] = @(start);
        target[@"cpu"] = @0; target[@"wall"] = @0; target[@"exceeded"] = @0;
        target[@"exceeding"] = @NO; target[@"due"] = PGAllowed(target) ? @(now) : @0;
        sTargets[pid] = target;
        log([NSString stringWithFormat:@"[CPU] 开始监测 %@ PID:%@ 阈值:%@%% 持续:%@秒", key, pid,
             target[@"threshold"], target[@"duration"]]);
    }
}

uint64_t MCCPUGuardNextDelay(void) {
    uint64_t now = PGNow(), next = UINT64_MAX;
    for (NSDictionary *target in sTargets.allValues) {
        uint64_t due = [target[@"due"] unsignedLongLongValue];
        if (due && due < next) next = due;
    }
    if (next == UINT64_MAX) return UINT64_MAX;
    return next > now ? next - now : NSEC_PER_MSEC * 100;
}

void MCCPUGuardSample(void (^log)(NSString *)) {
    uint64_t now = PGNow();
    static mach_timebase_info_data_t timebase;
    if (!timebase.denom) mach_timebase_info(&timebase);
    if (!timebase.denom) return;
    for (NSNumber *pid in [sTargets.allKeys copy]) {
        NSMutableDictionary *target = sTargets[pid];
        uint64_t due = [target[@"due"] unsignedLongLongValue];
        if (!due || due > now) continue;
        uint64_t cpu = 0, start = 0;
        if (![PGPath(pid.intValue) isEqual:target[@"path"]] ||
            !PGUsage(pid.intValue, &cpu, &start) || start != [target[@"start"] unsignedLongLongValue]) {
            [sTargets removeObjectForKey:pid];
            continue;
        }
        if (!PGAllowed(target)) {
            target[@"cpu"] = @0; target[@"wall"] = @0; target[@"exceeded"] = @0;
            target[@"exceeding"] = @NO; target[@"due"] = @0;
            continue;
        }
        uint64_t oldWall = [target[@"wall"] unsignedLongLongValue];
        uint64_t oldCPU = [target[@"cpu"] unsignedLongLongValue];
        if (!oldWall || now <= oldWall || cpu < oldCPU) {
            target[@"wall"] = @(now); target[@"cpu"] = @(cpu);
            target[@"due"] = @(now + NSEC_PER_SEC);
            continue;
        }
        uint64_t wall = now - oldWall;
        double percent = (double)(cpu - oldCPU) * timebase.numer / timebase.denom * 100.0 / wall;
        target[@"wall"] = @(now); target[@"cpu"] = @(cpu);
        if (percent >= [target[@"threshold"] doubleValue]) {
            uint64_t exceeded = [target[@"exceeding"] boolValue]
                ? [target[@"exceeded"] unsignedLongLongValue] + wall : 0;
            target[@"exceeding"] = @YES; target[@"exceeded"] = @(exceeded);
            if (exceeded >= [target[@"duration"] unsignedLongLongValue] * NSEC_PER_SEC) {
                NSString *key = target[@"key"];
                BOOL identity = [PGPath(pid.intValue) isEqual:target[@"path"]] &&
                    PGUsage(pid.intValue, NULL, &start) && start == [target[@"start"] unsignedLongLongValue] &&
                    ([target[@"app"] boolValue] ? [MCBundleIdForPid(pid.intValue) isEqualToString:key]
                                                : [MCProcessNameForPid(pid.intValue) isEqualToString:key]);
                if (identity && PGAllowed(target)) {
                    int result = kill(pid.intValue, SIGKILL);
                    log([NSString stringWithFormat:@"[CPU] %@ PID:%@ 连续超限 %.1f 秒，最近 %.1f%%，终止%@",
                         key, pid, (double)exceeded / NSEC_PER_SEC, percent, result == 0 ? @"成功" : @"失败"]);
                    [sTargets removeObjectForKey:pid];
                    continue;
                }
            }
            target[@"due"] = @(now + [target[@"exceed"] unsignedLongLongValue] * NSEC_PER_SEC);
        } else {
            target[@"exceeding"] = @NO; target[@"exceeded"] = @0;
            double boundary = [target[@"threshold"] doubleValue] * [target[@"ratio"] doubleValue] / 100.0;
            NSNumber *interval = percent >= boundary ? target[@"near"] : target[@"idle"];
            target[@"due"] = @(now + interval.unsignedLongLongValue * NSEC_PER_SEC);
        }
    }
}
