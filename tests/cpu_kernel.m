#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <assert.h>
static void *PGTestSymbol(void *handle, const char *name);
#define dlsym PGTestSymbol
#include "../Sources/MCCPUGuard.m"
#undef dlsym

static BOOL apiAvailable = YES, failMonitor, failStop, failRestore;
static int setCalls, stopCalls;
static uint64_t processStart = 123;
static NSMutableDictionary *kernelSettings;
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
    if (kernelSettings[@(pid)]) { errno = EBUSY; return -1; }
    if (failMonitor) { errno = EPERM; return -1; }
    kernelSettings[@(pid)] = @[@(percent), @(seconds)];
    return 0;
}
static int StopMonitor(int pid) {
    stopCalls++;
    if (failStop) { errno = EPERM; return -1; }
    [kernelSettings removeObjectForKey:@(pid)];
    return 0;
}
static int GetMonitor(int pid, int *percent, int *seconds) {
    NSArray *settings = kernelSettings[@(pid)];
    *percent = [settings.firstObject intValue];
    *seconds = [settings.lastObject intValue];
    return 0;
}
static int RestoreMonitor(int pid, int percent, int seconds) {
    if (failRestore) { errno = EPERM; return -1; }
    kernelSettings[@(pid)] = @[@(percent), @(seconds)];
    return 0;
}
static void *PGTestSymbol(void *handle, const char *name) {
    if (!apiAvailable) return NULL;
    if (strcmp(name, "proc_set_cpumon_params_fatal") == 0) return (void *)SetMonitor;
    if (strcmp(name, "proc_disable_cpumon") == 0) return (void *)StopMonitor;
    if (strcmp(name, "proc_get_cpumon_params") == 0) return (void *)GetMonitor;
    if (strcmp(name, "proc_set_cpumon_params") == 0) return (void *)RestoreMonitor;
    return NULL;
}
static NSDictionary *Configs(NSInteger threshold) {
    NSDictionary *cfg = @{@"CPUThreshold": @(threshold), @"CPUDuration": @5};
    return @{@"com.example.a": cfg, @"com.example.b": cfg};
}
int main(void) {
    @autoreleasepool {
        NSDictionary *pids = @{@"com.example.a": @[@900101], @"com.example.b": @[@900102]};
        kernelSettings = [NSMutableDictionary dictionary];
        NSMutableArray *messages = [NSMutableArray array];
        void (^log)(NSString *) = ^(NSString *message) { [messages addObject:message]; };
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
        [kernelSettings removeAllObjects]; // The new process inherits no old CPU policy.
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
        NSDictionary *oldSettings = @{@900101: @[@50, @60], @900102: @[@60, @120]};
        [kernelSettings addEntriesFromDictionary:oldSettings];
        int before = setCalls;
        MCCPUGuardUpdate(Configs(85), pids, YES, log);
        assert(sMonitors.count == 2 && setCalls == before + 4); // EBUSY -> stop -> fatal setter.
        assert(([kernelSettings[@900101] isEqual:@[@85, @5]]));
        before = setCalls;
        MCCPUGuardUpdate(Configs(85), pids, YES, log);
        assert(setCalls == before); // Successful takeover does not reset the monitor on every event.
        MCCPUGuardUpdate(@{}, @{}, NO, log);
        [kernelSettings addEntriesFromDictionary:oldSettings];
        failMonitor = YES;
        MCCPUGuardUpdate(Configs(85), pids, YES, log);
        assert(!sMonitors.count && [kernelSettings isEqual:oldSettings]); // Roll back if fatal setup fails.
        NSUInteger messageCount = messages.count;
        MCCPUGuardUpdate(Configs(85), pids, YES, log);
        assert(messages.count == messageCount); // Same PID/config/error is logged once.
        failRestore = YES;
        MCCPUGuardUpdate(Configs(85), pids, YES, log);
        assert(sMonitors.count == 2 && sMonitors[@900101][@"restore"]);
        failRestore = failMonitor = NO;
        MCCPUGuardUpdate(@{}, @{}, NO, log);
        assert(!sMonitors.count && [kernelSettings isEqual:oldSettings]); // Pending rollback survives failure.
        failStop = YES;
        MCCPUGuardUpdate(Configs(85), pids, YES, log);
        assert(!sMonitors.count && [kernelSettings isEqual:oldSettings]); // Failed stop cannot change policy.
        failStop = NO;
        puts("Kernel CPU checks passed: EBUSY takeover, readback, rollback, duplicate logs, background persistence and PID reuse");
    }
    return 0;
}
