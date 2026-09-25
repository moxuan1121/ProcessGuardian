#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <assert.h>
static void *PGTestSymbol(void *handle, const char *name);
#define dlsym PGTestSymbol
#include "../Sources/MCCPUGuard.m"
#undef dlsym

static BOOL apiAvailable = YES, failMonitor, failStop;
static int setCalls, stopCalls;
static uint64_t processStart = 123;
int proc_pidpath(int pid, void *buffer, uint32_t size) {
    strlcpy(buffer, "/Example.app/Example", size);
    return (int)strlen(buffer);
}
int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int size) {
    struct vdt_proc_bsdinfo *info = buffer;
    memset(info, 0, sizeof(*info));
    info->pbi_start_tvsec = processStart;
    info->pbi_status = 2;
    return sizeof(*info);
}
static int SetMonitor(int pid, int percent, int seconds) {
    assert((pid == 900101 || pid == 900102) && percent == 85 && seconds == 5);
    setCalls++;
    if (failMonitor) { errno = EPERM; return -1; }
    return 0;
}
static int StopMonitor(int pid) {
    stopCalls++;
    if (failStop) { errno = EPERM; return -1; }
    return 0;
}
static void *PGTestSymbol(void *handle, const char *name) {
    if (!apiAvailable) return NULL;
    return strcmp(name, "proc_set_cpumon_params_fatal") == 0 ? (void *)SetMonitor : (void *)StopMonitor;
}
static NSDictionary *Configs(NSInteger threshold) {
    NSDictionary *cfg = @{@"CPUThreshold": @(threshold), @"CPUDuration": @5};
    return @{@"com.example.a": cfg, @"com.example.b": cfg};
}
int main(void) {
    @autoreleasepool {
        NSDictionary *pids = @{@"com.example.a": @[@900101], @"com.example.b": @[@900102]};
        void (^log)(NSString *) = ^(NSString *message) {};
        MCCPUGuardUpdate(Configs(85), pids, YES, log);
        assert(sMonitors.count == 2 && setCalls == 2); // Simultaneous monitors, no foreground-only selection.
        MCCPUGuardUpdate(Configs(85), pids, YES, log);
        assert(setCalls == 2 && stopCalls == 0); // App switches/lifecycle events do not reset monitoring windows.
        MCCPUGuardUpdate(@{}, @{}, NO, log);
        assert(!sMonitors.count && stopCalls == 2);
        failMonitor = YES;
        MCCPUGuardUpdate(Configs(85), pids, YES, log);
        assert(!sMonitors.count && setCalls == 4);
        failMonitor = NO; apiAvailable = NO;
        MCCPUGuardUpdate(Configs(85), pids, YES, log);
        assert(!sMonitors.count && setCalls == 4);
        apiAvailable = YES;
        MCCPUGuardUpdate(Configs(150), pids, YES, log);
        assert(!sMonitors.count && setCalls == 4);
        MCCPUGuardUpdate(Configs(85), pids, YES, log);
        processStart++;
        MCCPUGuardUpdate(@{}, @{}, NO, log);
        assert(!sMonitors.count && stopCalls == 2); // Never disable a reused PID's new process.
        MCCPUGuardUpdate(Configs(85), pids, YES, log);
        failStop = YES;
        MCCPUGuardUpdate(@{}, @{}, NO, log);
        assert(sMonitors.count == 2);
        failStop = NO;
        MCCPUGuardUpdate(@{}, @{}, NO, log);
        assert(!sMonitors.count);
        MCCPUGuardUpdate(Configs(0), pids, YES, log);
        assert(!sMonitors.count);
        puts("Kernel CPU checks passed: background persistence, failure, API absence, range, PID reuse and stop retry");
    }
    return 0;
}
