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
int main(void) {
    @autoreleasepool {
        testWall = NSEC_PER_SEC;
        NSDictionary *cfg = @{@"a": @{@"CPUThreshold": @85, @"CPUDuration": @5}};
        NSDictionary *pids = @{@"a": @[@900101]};
        void (^log)(NSString *) = ^(NSString *message) {};
        MCCPUGuardUpdate(cfg, pids, YES, log);
        assert(MCCPUGuardHasTargets());
        for (int n = 0; n < 4; n++) {
            testWall += NSEC_PER_SEC;
            testCPU += 900000000;
            MCCPUGuardSample(log);
            assert(kills == 0);
        }
        testWall += NSEC_PER_SEC;
        testCPU += 900000000;
        MCCPUGuardSample(log);
        assert(kills == 1 && !MCCPUGuardHasTargets());
        MCCPUGuardUpdate(cfg, pids, YES, log);
        testWall += NSEC_PER_SEC; testCPU += 900000000;
        MCCPUGuardSample(log);
        testWall += NSEC_PER_SEC; testCPU += 100000000;
        MCCPUGuardSample(log);
        for (int n = 0; n < 4; n++) {
            testWall += NSEC_PER_SEC; testCPU += 900000000;
            MCCPUGuardSample(log);
        }
        assert(kills == 1); // A sub-threshold interval resets the streak.
        testStart++;
        testWall += NSEC_PER_SEC; testCPU += 900000000;
        MCCPUGuardSample(log);
        assert(kills == 1 && !MCCPUGuardHasTargets()); // PID reuse is never killed.
        MCCPUGuardUpdate(cfg, pids, YES, log);
        MCCPUGuardUpdate(@{}, @{}, NO, log);
        assert(!MCCPUGuardHasTargets());
        puts("Process-wide CPU duration, reset and PID reuse passed");
    }
    return 0;
}
