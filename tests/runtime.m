#import <Foundation/Foundation.h>
#import <assert.h>
#import <string.h>
#define main PGDaemonMain
#include "../Sources/daemon/main.m"
#undef main

static NSDictionary *paths;
static int enumerations, pathReads, priorityWrites, memWrites;
static int32_t actualPriority;
static memorystatus_memlimit_properties_t actualMem = {
    .memlimit_active = 768, .memlimit_inactive = 768,
    .memlimit_active_attr = MEMORYSTATUS_MEMLIMIT_ATTR_FATAL,
    .memlimit_inactive_attr = MEMORYSTATUS_MEMLIMIT_ATTR_FATAL,
};
static memorystatus_memlimit_properties_t lastMemWrite;

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
    if (command == MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES) {
        *(memorystatus_memlimit_properties_t *)buffer = actualMem;
    }
    if (command == MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES) {
        memWrites++;
        lastMemWrite = *(memorystatus_memlimit_properties_t *)buffer;
        actualMem = lastMemWrite;
        if (actualMem.memlimit_active <= 0) {
            actualMem.memlimit_active = 768;
            actualMem.memlimit_active_attr = MEMORYSTATUS_MEMLIMIT_ATTR_FATAL;
        }
        if (actualMem.memlimit_inactive <= 0) {
            actualMem.memlimit_inactive = 768;
            actualMem.memlimit_inactive_attr = MEMORYSTATUS_MEMLIMIT_ATTR_FATAL;
        }
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
    NSDictionary *shown = [MCCommon readStatus][@"Processes"][@"com.example.app"];
    assert([shown[@"JetsamState"] isEqual:@"已生效"] &&
           [shown[@"ActualJetsam"] intValue] == MCTargetJetsamPriority(150));
    MCRunSweep(NO);
    assert(enumerations == 2 && priorityWrites == 1); // Unchanged target is not rewritten.
    MCRunSweep(YES);
    assert(priorityWrites == 1); // Forced patrol also skips an unchanged Jetsam target.
    assert(([@{@"Enabled": @YES, @"AppConfigs": @{@"com.example.app": @{@"JetsamPriority": @-1}}}
        writeToFile:[MCCommon preferencesPlistPath] atomically:YES]));
    MCRunSweep(NO);
    assert(priorityWrites == 2 && actualPriority == 0 && !sApplied.count); // Reset releases old settings.
    assert(([@{@"Enabled": @NO, @"AppConfigs": @{}} writeToFile:[MCCommon preferencesPlistPath] atomically:YES]));
    MCRunSweep(NO);
    previous = enumerations;
    MCRunSweep(NO);
    assert(enumerations == previous); // Disabled/unchanged events do no process scan.
    NSDictionary *memoryPrefs = @{@"Enabled": @YES, @"AppConfigs": @{@"com.example.app":
        @{@"MemLimitActive": @0, @"MemLimitInactive": @1024}}};
    assert([memoryPrefs writeToFile:[MCCommon preferencesPlistPath] atomically:YES]);
    MCRunSweep(NO);
    assert(memWrites == 1 && lastMemWrite.memlimit_active == 768 &&
           lastMemWrite.memlimit_inactive == 1024);
    MCRunSweep(YES);
    assert(memWrites == 1); // Unchanged limits are not rewritten.
    actualMem.memlimit_inactive = 900;
    MCRunSweep(YES);
    assert(memWrites == 2 && actualMem.memlimit_inactive == 1024);
    assert(([@{@"Enabled": @NO, @"AppConfigs": @{}} writeToFile:[MCCommon preferencesPlistPath] atomically:YES]));
    MCRunSweep(NO);
    assert(memWrites == 3 && lastMemWrite.memlimit_active == 768 &&
           lastMemWrite.memlimit_inactive == MC_MEMLIMIT_DEFAULT);
    sLogSizeLimitMB = 0.0001;
    MCLog(@"A log entry longer than the configured limit must rotate the file before append.");
    NSString *rotated = [NSString stringWithContentsOfFile:sLogFile encoding:NSUTF8StringEncoding error:nil];
    assert([rotated containsString:@"已自动清空"]);
    assert([fm removeItemAtPath:root error:nil]);
    puts("Runtime checks passed: batch lookup equivalence, fresh snapshots, sweep reuse, reset and disabled idle");
  }
  return 0;
}
