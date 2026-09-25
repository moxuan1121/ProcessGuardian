#import <Foundation/Foundation.h>
#import <assert.h>
#import <string.h>
#define main PGDaemonMain
#include "../Sources/daemon/main.m"
#undef main

static NSDictionary *paths;
static int enumerations, pathReads, priorityWrites;
static int32_t actualPriority;

int proc_listpids(uint32_t type, uint32_t info, void *buffer, int size) {
    pid_t pids[] = {900102, 900101, 900103}; // Extension appears before the main app in the OS list.
    if (!buffer) { enumerations++; return sizeof(pids); }
    assert(size >= (int)sizeof(pids));
    memcpy(buffer, pids, sizeof(pids));
    return sizeof(pids);
}
int proc_pidpath(int pid, void *buffer, uint32_t size) {
    pathReads++;
    NSString *path = paths[@(pid)];
    if (!path) return 0;
    strlcpy(buffer, path.UTF8String, size);
    return (int)strlen(buffer);
}
int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t size) {
    if (command == MEMORYSTATUS_CMD_GET_PRIORITY_LIST) {
        memorystatus_priority_entry_t *entry = buffer;
        entry->pid = pid; entry->priority = actualPriority;
        return sizeof(*entry);
    }
    if (command == MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES) {
        priorityWrites++;
        actualPriority = ((memorystatus_priority_properties_t *)buffer)->priority;
    }
    return 0;
}

int main(void) {
  @autoreleasepool {
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    setenv("PG_TEST_ROOT", root.UTF8String, 1);
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *app = [root stringByAppendingPathComponent:@"Example.app"];
    assert([fm createDirectoryAtPath:app withIntermediateDirectories:YES attributes:nil error:nil]);
    assert([@{@"CFBundleIdentifier": @"com.example.app"} writeToFile:[app stringByAppendingPathComponent:@"Info.plist"] atomically:YES]);
    paths = @{@900101: [app stringByAppendingPathComponent:@"Example"],
              @900102: [app stringByAppendingPathComponent:@"PlugIns/Widget.appex/Widget"],
              @900103: @"/System/Library/CoreServices/SpringBoard.app/SpringBoard"};
    NSArray *keys = @[@"Example", @"com.example.app", @"Widget", @"SpringBoard", @"absent"];
    NSDictionary *batch = MCPidsForIdentifiers(keys);
    assert(enumerations == 1 && pathReads == 3);
    assert([batch[@"Example"] isEqual:@[@900101]]);
    assert([batch[@"com.example.app"] isEqual:(@[@900101, @900102])]);
    assert([batch[@"Widget"] isEqual:@[@900102]]);
    assert([batch[@"SpringBoard"] isEqual:@[@900103]]);
    assert(!batch[@"absent"]);
    for (NSString *key in keys) assert([MCPidsForIdentifier(key) isEqual:batch[key] ?: @[]]);
    assert(enumerations == 6); // Five separate lookups versus one batch.
    int previous = enumerations;
    assert(!MCPidsForIdentifiers(@[]).count && enumerations == previous);
    paths = @{@900103: @"/usr/libexec/replacement"};
    assert(!MCPidsForIdentifiers(keys).count); // No stale PID/bundle cache.

    assert([fm createDirectoryAtPath:[MCCommon preferencesDirectory] withIntermediateDirectories:YES attributes:nil error:nil]);
    NSDictionary *legacy = @{@"Enabled": @YES, @"AppConfigs": @{@"com.example.app":
        @{@"KeepAlive": @YES, @"RelaunchAfterRespring": @YES, @"CPUThreshold": @85,
          @"CPUDuration": @5, @"MemLimitInactive": @512, @"JetsamPriority": @160,
          @"NiceValue": @(-1), @"Remark": @"Example"}}};
    assert([legacy writeToFile:[MCCommon preferencesPlistPath] atomically:YES]);
    NSDictionary *cleaned = [MCCommon readPreferences][@"AppConfigs"][@"com.example.app"];
    assert(!cleaned[@"KeepAlive"] && !cleaned[@"RelaunchAfterRespring"]);
    NSMutableDictionary *expected = [legacy[@"AppConfigs"][@"com.example.app"] mutableCopy];
    [expected removeObjectsForKeys:@[@"KeepAlive", @"RelaunchAfterRespring"]];
    assert([cleaned isEqual:expected]);
    MCProcessConfig *legacyConfig = [MCProcessConfig configWithDictionary:legacy[@"AppConfigs"][@"com.example.app"] key:@"com.example.app"];
    assert(legacyConfig.cpuThreshold == 85 && legacyConfig.cpuDuration == 5);
    assert(![legacyConfig dictionaryValue][@"KeepAlive"]);
    paths = @{@900101: [app stringByAppendingPathComponent:@"Example"]};
    sLogFile = [MCCommon logFilePath]; sLogSizeLimitMB = 2; sApplied = [NSMutableDictionary dictionary];
    NSDictionary *prefs = @{@"Enabled": @YES, @"AppConfigs": @{@"com.example.app": @{@"JetsamPriority": @150}}};
    assert([prefs writeToFile:[MCCommon preferencesPlistPath] atomically:YES]);
    enumerations = pathReads = 0;
    MCRunSweep(NO);
    assert(enumerations == 1 && priorityWrites == 1 && sApplied.count == 1);
    MCRunSweep(NO);
    assert(enumerations == 2 && priorityWrites == 1); // Unchanged target is not rewritten.
    assert(([@{@"Enabled": @YES, @"AppConfigs": @{@"com.example.app": @{@"JetsamPriority": @-1}}}
        writeToFile:[MCCommon preferencesPlistPath] atomically:YES]));
    MCRunSweep(NO);
    assert(priorityWrites == 2 && actualPriority == 0 && !sApplied.count); // Reset releases old settings.
    assert(([@{@"Enabled": @NO, @"AppConfigs": @{}} writeToFile:[MCCommon preferencesPlistPath] atomically:YES]));
    MCRunSweep(NO);
    previous = enumerations;
    MCRunSweep(NO);
    assert(enumerations == previous); // Disabled/unchanged events do no process scan.
    assert([fm removeItemAtPath:root error:nil]);
    puts("Runtime checks passed: batch lookup equivalence, fresh snapshots, sweep reuse, reset and disabled idle");
  }
  return 0;
}
