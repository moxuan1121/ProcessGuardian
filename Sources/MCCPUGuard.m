// CPU sampling and PID identity checks adapted from CPUOverloadKiller (GPL-3.0).
// Only an explicitly configured foreground application is monitored.
#import "MCCPUGuard.h"
#import "MCCommon.h"
#import <libproc.h>
#import <libproc_internal.h>
#import <mach/mach_time.h>
#import <notify.h>
#import <signal.h>
#import <time.h>

typedef struct {
    uint8_t uuid[16];
    uint64_t userTime, systemTime, packageIdleWakeups, interruptWakeups;
    uint64_t pageins, wiredSize, residentSize, physicalFootprint;
    uint64_t processStartAbsoluteTime, processExitAbsoluteTime;
} PGUsageV0;

static dispatch_queue_t sQueue;
static dispatch_source_t sTimer;
static NSString *sBundle, *sPath;
static pid_t sPID;
static uint64_t sStart, sOldCPU, sOldWall, sExceeded;
static BOOL sExceeding;
static NSInteger sThreshold, sDuration;
static int sNotifyToken = -1;

static uint64_t PGNow(void) {
    struct timespec t = {0};
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * NSEC_PER_SEC + t.tv_nsec;
}

static BOOL PGUsage(pid_t pid, uint64_t *cpu, uint64_t *start) {
    PGUsageV0 u = {0};
    if (pid <= 1 || proc_pid_rusage(pid, RUSAGE_INFO_V0, &u) != 0 || !u.processStartAbsoluteTime) return NO;
    if (cpu) *cpu = u.userTime + u.systemTime;
    if (start) *start = u.processStartAbsoluteTime;
    return YES;
}

static NSString *PGPath(pid_t pid) {
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    return proc_pidpath(pid, path, sizeof(path)) > 0 ? [NSString stringWithUTF8String:path] : nil;
}

static void PGReset(void) {
    sPID = 0; sPath = nil; sStart = sOldCPU = sOldWall = sExceeded = 0; sExceeding = NO;
}

static BOOL PGSameProcess(uint64_t *cpu) {
    uint64_t start = 0;
    return sPID > 1 && [PGPath(sPID) isEqualToString:sPath] &&
           PGUsage(sPID, cpu, &start) && start == sStart;
}

static void PGReload(void) {
    NSDictionary *prefs = [MCCommon readPreferences];
    NSDictionary *cfg = sBundle.length && [prefs[@"AppConfigs"] isKindOfClass:NSDictionary.class]
                        ? prefs[@"AppConfigs"][sBundle] : nil;
    NSInteger threshold = [cfg[@"CPUThreshold"] integerValue];
    NSInteger duration = [cfg[@"CPUDuration"] integerValue];
    sThreshold = [prefs[@"Enabled"] boolValue] && threshold >= 2 && threshold <= 1000 ? threshold : 0;
    sDuration = duration >= 1 && duration <= 3600 ? duration : 10;
    PGReset();
    dispatch_source_set_timer(sTimer, sThreshold ? dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC) : DISPATCH_TIME_FOREVER,
                              sThreshold ? NSEC_PER_SEC : DISPATCH_TIME_FOREVER, NSEC_PER_MSEC * 100);
}

static void PGSample(void) {
    if (!sThreshold || !sBundle.length) return;
    if (!sPID) {
        for (NSNumber *candidate in MCPidsForIdentifier(sBundle)) {
            pid_t pid = candidate.intValue;
            uint64_t start = 0;
            NSString *path = PGPath(pid);
            if (path.length && PGUsage(pid, NULL, &start) && [MCBundleIdForPid(pid) isEqualToString:sBundle]) {
                sPID = pid; sPath = path; sStart = start; break;
            }
        }
        return;
    }
    uint64_t cpu = 0;
    if (!PGSameProcess(&cpu)) { PGReset(); return; }
    uint64_t now = PGNow();
    if (!sOldWall || now <= sOldWall || cpu < sOldCPU) {
        sOldWall = now; sOldCPU = cpu; return;
    }
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&timebase); });
    if (!timebase.denom) return;
    uint64_t wall = now - sOldWall;
    double percent = (double)(cpu - sOldCPU) * timebase.numer / timebase.denom * 100.0 / wall;
    sOldWall = now; sOldCPU = cpu;
    if (percent < sThreshold) { sExceeding = NO; sExceeded = 0; return; }
    if (sExceeding) sExceeded += wall;
    else { sExceeding = YES; sExceeded = 0; }
    if (sExceeded >= (uint64_t)sDuration * NSEC_PER_SEC && PGSameProcess(NULL) &&
        [MCBundleIdForPid(sPID) isEqualToString:sBundle]) {
        // StayAlive receives the real process-death event and may launch a fresh PID.
        kill(sPID, SIGKILL);
        PGReset();
    }
}

void MCCPUGuardFrontmostChanged(NSString *bundleIdentifier) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sQueue = dispatch_queue_create("com.moxuan.processguardian.cpu", DISPATCH_QUEUE_SERIAL);
        sTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, sQueue);
        dispatch_source_set_event_handler(sTimer, ^{ @autoreleasepool { PGSample(); } });
        dispatch_resume(sTimer);
        notify_register_dispatch(MCApplyLimitsNotification.UTF8String, &sNotifyToken, sQueue, ^(int token) { PGReload(); });
    });
    dispatch_async(sQueue, ^{ sBundle = [bundleIdentifier copy]; PGReload(); });
}
