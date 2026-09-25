#import <Foundation/Foundation.h>
#import <assert.h>
#import <mach/mach_time.h>
#import <time.h>
#import <signal.h>
static uint64_t testWall, testCPU, testStart = 123;
static int kills;
static int TestClock(int clock, struct timespec *time);
static kern_return_t TestTimebase(mach_timebase_info_t info);
static int TestKill(pid_t pid, int signal);
static int TestUsage(int pid, int flavor, void *buffer);
static int TestPath(int pid, void *buffer, uint32_t size);
#define clock_gettime TestClock
#define mach_timebase_info TestTimebase
#define kill TestKill
#define proc_pid_rusage TestUsage
#define proc_pidpath TestPath
#include "../Sources/MCCPUGuard.m"
#undef clock_gettime
#undef mach_timebase_info
#undef kill
#undef proc_pid_rusage
#undef proc_pidpath
NSString *MCBundleIdForPid(pid_t pid) { return @"com.example.a"; }
NSString *MCProcessNameForPid(pid_t pid) { return @"Example"; }
static int TestClock(int clock, struct timespec *time) {
    time->tv_sec = testWall / NSEC_PER_SEC;
    time->tv_nsec = testWall % NSEC_PER_SEC;
    return 0;
}
static kern_return_t TestTimebase(mach_timebase_info_t info) {
    info->numer = info->denom = 1;
    return KERN_SUCCESS;
}
static int TestUsage(int pid, int flavor, void *buffer) {
    PGUsageV0 *usage = buffer;
    memset(usage, 0, sizeof(*usage));
    usage->userTime = testCPU;
    usage->processStartAbsoluteTime = testStart;
    return 0;
}
static int TestPath(int pid, void *buffer, uint32_t size) {
    strlcpy(buffer, "/Example.app/Example", size);
    return (int)strlen(buffer);
}
static int TestKill(pid_t pid, int signal) {
    assert(pid == 900101 && signal == SIGKILL);
    kills++;
    return 0;
}
static void Advance(int seconds, int percent, void (^log)(NSString *)) {
    testWall += (uint64_t)seconds * NSEC_PER_SEC;
    testCPU += (uint64_t)seconds * percent * NSEC_PER_SEC / 100;
    MCCPUGuardSample(log);
}
int main(void) {
    @autoreleasepool {
        testWall = NSEC_PER_SEC;
        NSDictionary *cfg = @{@"com.example.a": @{@"CPUThreshold": @85, @"CPUDuration": @3,
                                       @"CPUIdleSample": @60, @"CPUNearRatio": @67,
                                       @"CPUNearSample": @15, @"CPUExceedSample": @1,
                                       @"CPUBackground": @NO}};
        NSDictionary *pids = @{@"com.example.a": @[@900101]};
        void (^log)(NSString *) = ^(NSString *message) {};
        MCCPUGuardUpdate(cfg, pids, YES, log);
        assert(MCCPUGuardNextDelay() == UINT64_MAX); // Foreground-only by default.
        MCCPUGuardSetFrontmostHash(PGHash(@"com.example.a"));
        MCCPUGuardSample(log); // Initial baseline.
        assert(MCCPUGuardNextDelay() == NSEC_PER_SEC);
        Advance(1, 10, log);
        assert(MCCPUGuardNextDelay() == 60 * NSEC_PER_SEC);
        Advance(60, 70, log);
        assert(MCCPUGuardNextDelay() == 15 * NSEC_PER_SEC);
        Advance(15, 90, log);
        assert(MCCPUGuardNextDelay() == NSEC_PER_SEC && kills == 0);
        Advance(1, 90, log);
        Advance(1, 10, log);
        assert(kills == 0); // Falling below the threshold resets the streak.
        Advance(60, 90, log);
        for (int n = 0; n < 3; n++) Advance(1, 90, log);
        assert(kills == 1);
        MCCPUGuardUpdate(cfg, pids, YES, log);
        MCCPUGuardSetFrontmostHash(0);
        assert(MCCPUGuardNextDelay() == UINT64_MAX);
        MCCPUGuardSetFrontmostHash(PGHash(@"com.example.a"));
        testStart++;
        Advance(1, 90, log);
        assert(kills == 1 && MCCPUGuardNextDelay() == UINT64_MAX);
        MCCPUGuardUpdate(@{}, @{}, NO, log);
        puts("Adaptive CPU intervals, reset, kill and PID reuse passed");
    }
    return 0;
}
