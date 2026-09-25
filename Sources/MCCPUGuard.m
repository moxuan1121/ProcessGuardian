// PID identity checks adapted from CPUOverloadKiller (GPL-3.0).
// Only an explicitly configured foreground application is monitored.
#import "MCCPUGuard.h"
#import "MCCommon.h"
#import <libproc.h>
#import <libproc_internal.h>
#import <notify.h>
#import <os/log.h>
#import <errno.h>
#import <string.h>
#import <dlfcn.h>

typedef struct {
    uint8_t uuid[16];
    uint64_t userTime, systemTime, packageIdleWakeups, interruptWakeups;
    uint64_t pageins, wiredSize, residentSize, physicalFootprint;
    uint64_t processStartAbsoluteTime, processExitAbsoluteTime;
} PGUsageV0;

static dispatch_queue_t sQueue;
static NSString *sBundle, *sPath;
static pid_t sPID;
static uint64_t sStart, sGeneration;
static BOOL sKernelActive;
static NSInteger sThreshold, sDuration;
static int sNotifyToken = -1;
static int (*sDisableCPUMonitor)(int);

static BOOL PGIdentity(pid_t pid, uint64_t *start) {
    PGUsageV0 u = {0};
    if (pid <= 1 || proc_pid_rusage(pid, RUSAGE_INFO_V0, &u) != 0 || !u.processStartAbsoluteTime) return NO;
    if (start) *start = u.processStartAbsoluteTime;
    return YES;
}

static NSString *PGPath(pid_t pid) {
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    return proc_pidpath(pid, path, sizeof(path)) > 0 ? [NSString stringWithUTF8String:path] : nil;
}

static void PGReset(void) {
    sPID = 0; sPath = nil; sStart = 0;
    sKernelActive = NO;
}

static BOOL PGSameProcess(void) {
    uint64_t start = 0;
    return sPID > 1 && [PGPath(sPID) isEqualToString:sPath] &&
           PGIdentity(sPID, &start) && start == sStart;
}

static void PGStopKernel(void) {
    if (sKernelActive && PGSameProcess() && sDisableCPUMonitor(sPID) != 0)
        os_log_error(OS_LOG_DEFAULT, "ProcessGuardian: disable CPU monitor PID %{public}d failed: %{public}d", sPID, errno);
    sKernelActive = NO;
}

static void PGApply(unsigned attempt);

static void PGReload(void) {
    ++sGeneration; // Cancel pending PID discovery from an earlier foreground/configuration.
    NSDictionary *prefs = [MCCommon readPreferences];
    NSDictionary *cfg = sBundle.length && [prefs[@"AppConfigs"] isKindOfClass:NSDictionary.class]
                        ? prefs[@"AppConfigs"][sBundle] : nil;
    NSInteger threshold = [cfg[@"CPUThreshold"] integerValue];
    NSInteger duration = [cfg[@"CPUDuration"] integerValue];
    sThreshold = [prefs[@"Enabled"] boolValue] && threshold >= 2 && threshold <= 100 ? threshold : 0;
    if ([prefs[@"Enabled"] boolValue] && threshold != 0 && !sThreshold)
        os_log_error(OS_LOG_DEFAULT, "ProcessGuardian: CPU threshold %{public}ld outside kernel range 2-100; monitor not enabled", (long)threshold);
    sDuration = duration >= 1 && duration <= 3600 ? duration : 10;
    PGStopKernel();
    PGReset();
    PGApply(0);
}

static void PGApply(unsigned attempt) {
    if (!sThreshold || !sBundle.length) return;
    if (!sPID) {
        for (NSNumber *candidate in MCPidsForIdentifier(sBundle)) {
            pid_t pid = candidate.intValue;
            uint64_t start = 0;
            NSString *path = PGPath(pid);
            if (path.length && PGIdentity(pid, &start) && [MCBundleIdForPid(pid) isEqualToString:sBundle]) {
                sPID = pid; sPath = path; sStart = start; break;
            }
        }
    }
    if (!PGSameProcess()) {
        PGReset();
        if (attempt < 3) {
            uint64_t generation = sGeneration;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), sQueue, ^{
                @autoreleasepool {
                    if (generation == sGeneration) PGApply(attempt + 1);
                }
            });
        }
        return;
    }
    int (*setMonitor)(int, int, int) = dlsym(RTLD_DEFAULT, "proc_set_cpumon_params_fatal");
    sDisableCPUMonitor = dlsym(RTLD_DEFAULT, "proc_disable_cpumon");
    if (!setMonitor || !sDisableCPUMonitor) {
        os_log_error(OS_LOG_DEFAULT, "ProcessGuardian: kernel CPU monitor API unavailable; monitor not enabled");
        return;
    }
    if (setMonitor(sPID, (int)sThreshold, (int)sDuration) != 0) {
        os_log_error(OS_LOG_DEFAULT, "ProcessGuardian: kernel CPU monitor PID %{public}d failed: %{public}d (%{public}s)", sPID, errno, strerror(errno));
        return;
    }
    sKernelActive = YES;
    os_log(OS_LOG_DEFAULT, "ProcessGuardian: kernel CPU monitor PID %{public}d: %{public}ld%% / %{public}lds", sPID, (long)sThreshold, (long)sDuration);
}

void MCCPUGuardFrontmostChanged(NSString *bundleIdentifier) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sQueue = dispatch_queue_create("com.moxuan.processguardian.cpu", DISPATCH_QUEUE_SERIAL);
        notify_register_dispatch(MCApplyLimitsNotification.UTF8String, &sNotifyToken, sQueue, ^(int token) { PGReload(); });
    });
    dispatch_async(sQueue, ^{ sBundle = [bundleIdentifier copy]; PGReload(); });
}

void MCCPUGuardProcessStarted(void) {
    if (!sQueue) return;
    dispatch_async(sQueue, ^{
        if (!sKernelActive || !PGSameProcess()) PGReload();
    });
}
