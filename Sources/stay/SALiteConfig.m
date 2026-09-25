//
//  SALiteConfig.m
//  StayAlive Lite —— 偏好读写层
//

#import "SALiteConfig.h"
#import <roothide.h>


NSString *const SALitePrefsPlistPath     = @"/var/mobile/Library/Preferences/com.moxuan.processguardian.plist";
NSString *const SALiteRuntimePlistPath   = @"/var/mobile/Library/Preferences/com.moxuan.processguardian.runtime.plist";


static NSString *const kKeyGlobalEnabled   = @"globalEnabled";
static NSString *const kKeyGlobal          = @"global";

static NSString *const kKeyEnabled              = @"enabled";
static NSString *const kKeyRunMode              = @"runMode";
static NSString *const kKeyStartMinute          = @"startMinute";
static NSString *const kKeyEndMinute            = @"endMinute";
static NSString *const kKeyWifiOnly             = @"wifiOnly";
static NSString *const kKeyChargingOnly         = @"chargingOnly";
static NSString *const kKeyStopOnLowBattery     = @"stopOnLowBattery";
static NSString *const kKeyRelaunchOnCrash      = @"relaunchOnCrash";
static NSString *const kKeyRelaunchAfterRespring = @"relaunchAfterRespring";

static NSString *const kKeyCrashLoopProtection  = @"crashLoopProtection";
static NSString *const kKeyCrashWakeInterval    = @"crashWakeInterval";
static NSString *const kKeyLongPressEnabled     = @"longPressEnabled";

static const NSInteger SALiteMinutesPerDay = 1439; // 24*60-1

/// SpringBoard 只读共享配置；写入统一由设置页处理。
static NSDictionary *SALiteReadPlist(NSString *path)
{
    return [NSDictionary dictionaryWithContentsOfFile:jbroot(path)];
}

@implementation SALiteConfig

+ (NSDictionary *)defaultPolicy
{
    static NSDictionary *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = @{ kKeyEnabled              : @NO,
               kKeyRunMode              : @"always",
               kKeyStartMinute          : @60,    // 01:00
               kKeyEndMinute            : @360,   // 06:00
               kKeyRelaunchOnCrash      : @YES,
               kKeyRelaunchAfterRespring: @NO,
               kKeyWifiOnly             : @NO,
               kKeyChargingOnly         : @NO,
               kKeyStopOnLowBattery     : @NO };
    });
    return d;
}

+ (NSDictionary *)defaultGlobalSettings
{
    static NSDictionary *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = @{ kKeyCrashLoopProtection : @YES,
               kKeyCrashWakeInterval   : @60,
               kKeyGlobalEnabled       : @YES,
               kKeyLongPressEnabled    : @NO };
    });
    return d;
}

+ (NSDictionary *)rootDictionary
{
    NSDictionary *dict = SALiteReadPlist(SALitePrefsPlistPath);
    return dict ?: @{};
}

/// 以 defaults 兜底、文件内容覆盖
+ (NSDictionary *)normalizedDictionary:(id)dict defaults:(NSDictionary *)defaults
{
    NSMutableDictionary *m = [defaults mutableCopy];
    if ([dict isKindOfClass:[NSDictionary class]]) {
        [m addEntriesFromDictionary:dict];
    }
    return [m copy];
}

// MARK: - 单 App 策略

+ (NSDictionary<NSString *, NSDictionary *> *)allPolicies
{
    id apps = [[self rootDictionary] objectForKey:@"AppConfigs"];
    if (![apps isKindOfClass:[NSDictionary class]]) apps = @{};

    NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:[(NSDictionary *)apps count]];
    [(NSDictionary *)apps enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        if (![key isKindOfClass:[NSString class]] || ![obj isKindOfClass:[NSDictionary class]]) return;
        // Only app bundle identifiers can be launched by SpringBoard. Process names stay daemon-only.
        if ([(NSString *)key rangeOfString:@"."].location == NSNotFound) return;
        NSMutableDictionary *policy = [[self defaultPolicy] mutableCopy];
        policy[kKeyEnabled] = @([obj[@"KeepAlive"] boolValue]);
        policy[kKeyRelaunchAfterRespring] = @([obj[@"RelaunchAfterRespring"] boolValue]);
        out[key] = policy;
    }];
    return [out copy];
}

+ (NSDictionary *)policyForBundleIdentifier:(NSString *)bundleIdentifier
{
    if (bundleIdentifier.length == 0) return [self defaultPolicy];

    return [self allPolicies][bundleIdentifier] ?: [self defaultPolicy];
}

// MARK: - 全局设置

+ (NSDictionary *)globalSettings
{
    id global = [[self rootDictionary] objectForKey:kKeyGlobal];
    return [self normalizedDictionary:global defaults:[self defaultGlobalSettings]];
}

+ (id)globalValueForKey:(NSString *)key
{
    if (key.length == 0) return nil;
    return [[self globalSettings] objectForKey:key];
}

+ (BOOL)globalBoolForKey:(NSString *)key
{
    return [[self globalValueForKey:key] boolValue];
}

+ (NSInteger)globalIntegerForKey:(NSString *)key
{
    return [[self globalValueForKey:key] integerValue];
}

+ (BOOL)isGlobalEnabled
{
    return [[[self rootDictionary] objectForKey:@"Enabled"] boolValue];
}

// MARK: - 定时运行

+ (NSInteger)minuteOfDayForDate:(NSDate *)date
{
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *c = [cal components:(NSCalendarUnitHour | NSCalendarUnitMinute) fromDate:date];
    return c.hour * 60 + c.minute;
}

+ (BOOL)isScheduleActiveForPolicy:(NSDictionary *)policy date:(NSDate *)date
{
    id mode = policy[kKeyRunMode];
    NSString *runMode = [mode isKindOfClass:[NSString class]] ? mode : @"always";
    if (![runMode isEqualToString:@"scheduled"]) return YES;

    // 二进制里是 min(max(v,0),1439)，不是取绝对值
    NSInteger startRaw = [policy[kKeyStartMinute] integerValue];
    NSInteger endRaw   = [policy[kKeyEndMinute] integerValue];
    NSInteger startPos = MAX(startRaw, 0);
    NSInteger endPos   = MAX(endRaw, 0);
    NSInteger start = MIN(startPos, SALiteMinutesPerDay);
    NSInteger end   = MIN(endPos, SALiteMinutesPerDay);
    if (start == end) return YES;

    NSInteger now = [self minuteOfDayForDate:date];
    BOOL crossMidnight = (now >= start) || (now < end);
    BOOL inWindow      = (now >= start) && (now < end);
    // 分支条件用的是未做上限截断的 startPos
    return (startPos >= end) ? crossMidnight : inWindow;
}

// MARK: - 路径

+ (NSString *)sharedPathForPath:(NSString *)path
{
    return jbroot(path);
}

@end
