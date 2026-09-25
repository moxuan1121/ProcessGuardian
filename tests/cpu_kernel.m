#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <assert.h>
static void *PGTestSymbol(void *handle, const char *name);
#define dlsym PGTestSymbol
#include "../Sources/MCCPUGuard.m"
#undef dlsym

static NSDictionary *preferences;
static BOOL apiAvailable = YES, failMonitor;
static int setCalls, stopCalls;
static uint64_t processStart = 123;
NSString *const MCApplyLimitsNotification = @"com.example.cpu-test";
@implementation MCCommon
+ (NSDictionary *)readPreferences { return preferences; }
@end
NSArray *MCPidsForIdentifier(NSString *identifier) { return @[@900101]; }
NSString *MCBundleIdForPid(pid_t pid) { return @"com.example.app"; }
int proc_pidpath(int pid, void *buffer, uint32_t size) {
    strlcpy(buffer, "/Example.app/Example", size);
    return (int)strlen(buffer);
}
int proc_pid_rusage(int pid, int flavor, void *buffer) {
    ((PGUsageV0 *)buffer)->processStartAbsoluteTime = processStart;
    return 0;
}
static int SetMonitor(int pid, int percent, int seconds) {
    assert(pid == 900101 && percent == 85 && seconds == 5);
    setCalls++;
    if (failMonitor) { errno = EPERM; return -1; }
    return 0;
}
static int StopMonitor(int pid) { assert(pid == 900101); stopCalls++; return 0; }
static void *PGTestSymbol(void *handle, const char *name) {
    if (!apiAvailable) return NULL;
    return strcmp(name, "proc_set_cpumon_params_fatal") == 0 ? (void *)SetMonitor : (void *)StopMonitor;
}
static NSDictionary *Prefs(NSInteger threshold) {
    return @{@"Enabled": @YES, @"AppConfigs": @{@"com.example.app":
        @{@"CPUThreshold": @(threshold), @"CPUDuration": @5}}};
}
int main(void) {
    @autoreleasepool {
        sBundle = @"com.example.app";
        preferences = Prefs(85);
        PGReload();
        assert(sKernelActive && setCalls == 1);
        sBundle = nil; PGReload();
        assert(!sKernelActive && stopCalls == 1); // Foreground departure stops this monitor.
        sBundle = @"com.example.app";
        failMonitor = YES; PGReload();
        assert(!sKernelActive && setCalls == 2); // Failed native request cannot enable a fallback.
        failMonitor = NO; apiAvailable = NO; PGReload();
        assert(!sKernelActive && setCalls == 2);
        apiAvailable = YES; preferences = Prefs(150); PGReload();
        assert(!sKernelActive && !sThreshold && setCalls == 2);
        preferences = Prefs(85); PGReload();
        processStart++; PGStopKernel();
        assert(stopCalls == 1); // Reused PID must not receive a stop intended for its predecessor.
        preferences = Prefs(0); PGReload();
        assert(!sKernelActive && !sThreshold);
        puts("Kernel CPU checks passed: attach, foreground exit, failure, API absence, range and PID reuse");
    }
    return 0;
}
