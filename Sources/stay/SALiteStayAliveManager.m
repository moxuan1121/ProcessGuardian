//
//  SALiteStayAliveManager.m
//  StayAlive Lite —— SpringBoard 侧守护核心
//

#import "SALiteStayAliveManager.h"
#import "SALiteConfig.h"
#import "SALitePrivateAPI.h"
#import "../MCCommon.h"

#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <notify.h>
#import <sys/stat.h>
#import <arpa/inet.h>
#import <errno.h>
#import <signal.h>
#import <fcntl.h>
#import <unistd.h>
#import <string.h>
#import <UIKit/UIKit.h>
#import "../libproc/libproc_internal.h"

// MARK: - 常量

/// RBS / BKS 断言的 reason 与 flags（后台保活组合）
static const NSInteger  SALiteAssertionReason = 7;
static const NSUInteger SALiteAssertionFlags  = 0xf;

static NSString *const SALiteAssertionExplanation = @"StayAlive Lite:%@";
static NSString *const SALiteRBSDomainFrontboard  = @"com.apple.frontboard";
static NSString *const SALiteRBSDomainAttrName    = @"Workspace-BackgroundActive";

static const char *SALiteNotifyPreferencesChanged = "com.moxuan.processguardian/ApplyLimits";

static const int64_t SALiteCrashRelaunchDelay = 1500LL * NSEC_PER_MSEC;  // 崩溃后默认 1.5s 重拉
static const int64_t SALiteAutoLaunchTimeout  = 3LL * NSEC_PER_SEC;      // 拉起请求的 pending 窗口
static const int64_t SALitePostLaunchDelay    = 650LL * NSEC_PER_MSEC;   // 启动后复检
static const int64_t SALiteStartupRecoveryStep = 900LL * NSEC_PER_MSEC;  // 逐个恢复的间隔
static const double  SALiteCrashLoopWindow    = 12.0;                    // 崩溃风暴判定窗口
static const double  SALiteBoundaryEpsilon    = 0.5;                     // 边界是否已过期

static const NSInteger SALiteTimerLease       = 0x77359400;              // 2s，纳秒
static const NSInteger SALiteDefaultCrashWake = 60;                      // 崩溃唤醒间隔兜底（秒）

static void SALiteLog(NSString *message)
{
    NSString *path = [SALiteConfig sharedPathForPath:@"/var/mobile/Library/Logs/ProcessGuardian.log"];
    NSString *line = [NSString stringWithFormat:@"[%@] [后台守护] %@\n", [MCCommon timestampString], message];
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0666);
    if (fd >= 0) {
        const char *bytes = line.UTF8String;
        write(fd, bytes, strlen(bytes));
        close(fd);
    }
}

/// 拉起后补挂断言的轮询时刻
static NSArray<NSNumber *> *SALiteLaunchRetryDelays(void)
{
    static NSArray *delays;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ delays = @[@0.35, @0.8, @1.5]; });
    return delays;
}

// MARK: - KVC 安全取值（私有对象结构随系统版本变化）

id SALiteKVC(id object, NSString *key)
{
    if (!object || key.length == 0) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (NSException *exception) {
        return nil;
    }
}

NSString *SALiteKVCString(id object, NSString *key)
{
    id value = SALiteKVC(object, key);
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

// MARK: - 私有框架按需加载（0.1.7：从 -start 里挪到这里）

/// 断言相关：RunningBoardServices / AssertionServices
void SALiteLoadAssertionFrameworks(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!NSClassFromString(@"RBSAssertion") || !NSClassFromString(@"RBSConnection")) {
            dlopen("/System/Library/PrivateFrameworks/RunningBoardServices.framework/RunningBoardServices", RTLD_LAZY);
        }
        if (!NSClassFromString(@"BKSProcessAssertion")) {
            dlopen("/System/Library/PrivateFrameworks/AssertionServices.framework/AssertionServices", RTLD_LAZY);
        }
    });
}

/// 拉起相关：FrontBoardServices / SpringBoardServices
void SALiteLoadLaunchFrameworks(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!NSClassFromString(@"FBSSystemService")) {
            dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_LAZY);
        }
        if (!NSClassFromString(@"SBSApplicationShortcutItem")) {
            dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
        }
    });
}

// MARK: - reachability 回调

static void SALiteReachabilityCallback(SCNetworkReachabilityRef target,
                                       SCNetworkReachabilityFlags flags,
                                       void *info)
{
    SALiteStayAliveManager *manager = (__bridge SALiteStayAliveManager *)info;
    dispatch_async(dispatch_get_main_queue(), ^{
        [manager evaluateAll];
    });
}

@implementation SALiteStayAliveManager
{
    // 显式声明这三个 ivar，让它们占据 8/9/12，与二进制的实例布局一致
    BOOL _started;
    BOOL _startupRecoveryScheduled;
    int _preferencesToken;
}

+ (instancetype)sharedManager
{
    static SALiteStayAliveManager *manager;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ manager = [[SALiteStayAliveManager alloc] init]; });
    return manager;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _assertions       = [NSMutableDictionary dictionary];
        _assertionPIDs    = [NSMutableDictionary dictionary];
        _userBlocked      = [NSMutableSet set];
        _crashBlocked     = [NSMutableSet set];
        _startupBlocked   = [NSMutableSet set];
        _autoLaunchPending = [NSMutableSet set];
        _watchedPIDs      = [NSMutableSet set];
        _deathSources     = [NSMutableDictionary dictionary];
        _lastEligibility  = [NSMutableDictionary dictionary];
        _lastAutoLaunchAt = [NSMutableDictionary dictionary];
        _startupRecoveryQueue = [NSMutableArray array];
        [self loadRuntimeState];
    }
    return self;
}

- (void)dealloc
{
    // 二进制里这里显式向 super 派发 dealloc（源文件按 -fno-objc-arc 编译）
    @try {
        if (_reachability) {
            SCNetworkReachabilitySetDispatchQueue(_reachability, NULL);
            CFRelease(_reachability);
            _reachability = NULL;
        }
        if (_boundaryTimer) {
            dispatch_source_cancel(_boundaryTimer);
            _boundaryTimer = NULL;
        }
    } @catch (NSException *exception) {
    }
}

// MARK: - 运行时状态持久化

- (void)loadRuntimeState
{
    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:
                           [SALiteConfig sharedPathForPath:SALiteRuntimePlistPath]];
    id blocked = [state objectForKey:@"userBlocked"];
    NSArray *objects = [blocked isKindOfClass:[NSArray class]] ? blocked : @[];
    for (id object in objects) {
        if ([object isKindOfClass:[NSString class]]) {
            [self.userBlocked addObject:object];
        }
    }
}

- (void)saveRuntimeState
{
    NSArray *blocked = [self.userBlocked allObjects] ?: @[];
    NSDictionary *state = @{ @"userBlocked": blocked };
    NSString *path = [SALiteConfig sharedPathForPath:SALiteRuntimePlistPath];
    [state writeToFile:path atomically:YES];
    chmod([path fileSystemRepresentation], 0666);
}

// MARK: - 定时运行

/// 求出 minuteOfHour 在 now 之后（含次日）的第一个整点分钟
- (NSDate *)nextOccurrenceForMinute:(NSInteger)minute now:(NSDate *)now
{
    NSInteger m = MIN(MAX(minute, 0), 1439);

    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDateComponents *components = [calendar components:(NSCalendarUnitHour | NSCalendarUnitMinute)
                                                fromDate:now];
    components.hour = m / 60;
    components.minute = m % 60;
    components.second = 0;

    NSDate *date = [calendar dateFromComponents:components];
    if (date && [date timeIntervalSinceDate:now] <= SALiteBoundaryEpsilon) {
        date = [calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:date options:0];
    }
    return date;
}

- (void)scheduleNextBoundary
{
    if (self.boundaryTimer) {
        dispatch_source_cancel(self.boundaryTimer);
        self.boundaryTimer = NULL;
    }
    if (![SALiteConfig isGlobalEnabled]) return;

    NSDate *now = [NSDate date];
    __block NSDate *next = nil;
    NSDictionary *policies = [SALiteConfig allPolicies];
    [policies enumerateKeysAndObjectsUsingBlock:^(NSString *bid, NSDictionary *policy, BOOL *stop) {
        if (![policy[@"enabled"] boolValue]) return;
        if (![policy[@"runMode"] isEqualToString:@"scheduled"]) return;

        NSInteger start = [policy[@"startMinute"] integerValue];
        NSInteger end = [policy[@"endMinute"] integerValue];
        if (start == end) return;

        for (NSNumber *minute in @[ @(start), @(end) ]) {
            NSDate *occurrence = [self nextOccurrenceForMinute:[minute integerValue] now:now];
            if (!occurrence) continue;
            if (next && [occurrence compare:next] != NSOrderedAscending) continue;
            next = occurrence;
        }
    }];

    NSDate *fireDate = next;
    if (!fireDate) return;

    NSTimeInterval interval = MAX([fireDate timeIntervalSinceNow], 1.0);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
                                                     0, 0, dispatch_get_main_queue());
    self.boundaryTimer = timer;

    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER,
                              SALiteTimerLease);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self evaluateAll];
        [self scheduleNextBoundary];   // 重新排下一个边界
    });
    dispatch_resume(timer);
}

/// 注销（respring）后：只允许「开机自启」勾选过的 App 恢复守护
- (void)preparePostRespringLaunchState
{
    self.policies = [SALiteConfig allPolicies];
    [self.startupBlocked removeAllObjects];
    [self.startupRecoveryQueue removeAllObjects];

    __block BOOL changed = NO;
    [self.policies enumerateKeysAndObjectsUsingBlock:^(NSString *bid, NSDictionary *policy, BOOL *stop) {
        if (![policy[@"enabled"] boolValue]) return;
        if (bid.length == 0) return;
        if ([self pidForBundleIdentifier:bid] > 0) return;

        // 0.1.7：一律先屏蔽，再交给启动恢复队列按条件放行
        [self.startupBlocked addObject:bid];
        if (![policy[@"relaunchAfterRespring"] boolValue]) return;

        if ([self.userBlocked containsObject:bid]) {
            [self.userBlocked removeObject:bid];
            changed = YES;
        }
        [self.crashBlocked removeObject:bid];
        [self.startupRecoveryQueue addObject:bid];
    }];

    if (changed) [self saveRuntimeState];
}

// MARK: - 注销后的启动恢复（0.1.7 新增）

/// 每一个待恢复的 App 单独错峰处理，避免注销后瞬间并发起多个进程
- (void)scheduleStartupRecovery
{
    if (self.startupRecoveryScheduled) return;
    if (self.startupRecoveryQueue.count == 0) return;
    self.startupRecoveryScheduled = YES;

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, SALiteStartupRecoveryStep),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self recoverNextStartupApplication];
    });
}

- (void)recoverNextStartupApplication
{
    self.startupRecoveryScheduled = NO;
    if (self.startupRecoveryQueue.count == 0) {
        self.startupRecoveryScheduled = NO;   // 尾调用：排完即止
        return;
    }

    NSString *bid = self.startupRecoveryQueue.firstObject;
    [self.startupRecoveryQueue removeObjectAtIndex:0];

    NSDictionary *policy = [SALiteConfig policyForBundleIdentifier:bid];
    if (![policy[@"enabled"] boolValue]) {
        [self scheduleStartupRecovery];
        return;
    }
    if (![policy[@"relaunchAfterRespring"] boolValue]) {
        [self scheduleStartupRecovery];
        return;
    }

    [self.startupBlocked removeObject:bid];

    if (![self isPolicyEligible:policy]) {
        [self scheduleStartupRecovery];
        return;
    }

    pid_t pid = [self pidForBundleIdentifier:bid];
    if (pid < 1) {
        [self launchBundleIdentifierInBackground:bid];
    } else {
        [self ensureAssertionForBundleIdentifier:bid pid:pid];
    }
    [self scheduleStartupRecovery];
}

// MARK: - 启动

- (void)start
{
    if (self.started) return;
    self.started = YES;

    [UIDevice.currentDevice setBatteryMonitoringEnabled:YES];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(environmentChanged:)
                   name:UIDeviceBatteryStateDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(environmentChanged:)
                   name:UIDeviceBatteryLevelDidChangeNotification object:nil];

    struct sockaddr_in zeroAddress;
    bzero(&zeroAddress, sizeof(zeroAddress));
    zeroAddress.sin_len = sizeof(zeroAddress);
    zeroAddress.sin_family = AF_INET;

    self.reachability = SCNetworkReachabilityCreateWithAddress(kCFAllocatorDefault,
                                                               (struct sockaddr *)&zeroAddress);
    if (self.reachability) {
        SCNetworkReachabilityContext context = {0, (__bridge void *)self, NULL, NULL, NULL};
        SCNetworkReachabilitySetCallback(self.reachability, SALiteReachabilityCallback, &context);
        SCNetworkReachabilitySetDispatchQueue(self.reachability, dispatch_get_main_queue());
    }

    [self preparePostRespringLaunchState];

    __weak typeof(self) weakSelf = self;
    notify_register_dispatch(SALiteNotifyPreferencesChanged,
                             &_preferencesToken,
                             dispatch_get_main_queue(),
                             ^(int token) {
        __strong typeof(weakSelf) self = weakSelf;
        [self evaluateAll];
        [self scheduleNextBoundary];
    });

    [self evaluateAll];
    [self scheduleNextBoundary];
    [self scheduleStartupRecovery];
}

- (void)environmentChanged:(NSNotification *)notification
{
    [self evaluateAll];
}

// MARK: - 条件判断

- (BOOL)isWiFiReachable
{
    if (!self.reachability) return NO;

    SCNetworkReachabilityFlags flags = 0;
    if (!SCNetworkReachabilityGetFlags(self.reachability, &flags)) return NO;
    // 可达、且不需要建立连接
    return (flags & (kSCNetworkReachabilityFlagsConnectionRequired | 0x40000)) == 0
        && (flags & kSCNetworkReachabilityFlagsReachable) != 0;
}

- (BOOL)isCharging
{
    UIDeviceBatteryState state = UIDevice.currentDevice.batteryState;
    return state == UIDeviceBatteryStateCharging || state == UIDeviceBatteryStateFull;
}

- (BOOL)isLowBattery
{
    float level = UIDevice.currentDevice.batteryLevel;
    return level >= 0.0 && level <= 0.2;
}

- (BOOL)isPolicyEligible:(NSDictionary *)policy
{
    if (![SALiteConfig isGlobalEnabled]) return NO;
    if (![policy[@"enabled"] boolValue]) return NO;

    NSDate *now = [NSDate date];
    if (![SALiteConfig isScheduleActiveForPolicy:policy date:now]) return NO;
    if ([policy[@"wifiOnly"] boolValue] && ![self isWiFiReachable]) return NO;
    if ([policy[@"chargingOnly"] boolValue] && ![self isCharging]) return NO;
    if ([policy[@"stopOnLowBattery"] boolValue] && [self isLowBattery]) return NO;
    return YES;
}

- (pid_t)pidForBundleIdentifier:(NSString *)bundleIdentifier
{
    if (bundleIdentifier.length == 0) return 0;

    Class controllerClass = NSClassFromString(@"SBApplicationController");
    id controller = [(id)controllerClass sharedInstance];
    id application = [controller applicationWithBundleIdentifier:bundleIdentifier];

    // 读一次 processState：触发 SBApplication 刷新内部缓存
    SALiteKVC(application, @"processState");

    int pid = [SALiteKVC(application, @"pid") intValue];
    // SpringBoard's cached PID may be zero or dead until another app opens.
    BOOL alive = pid > 0 && !(kill(pid, 0) == -1 && errno == ESRCH);
    struct vdt_proc_bsdinfo info = {0};
    if (alive && proc_pidinfo(pid, VDT_PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info)
        && info.pbi_status == 5) alive = NO; // Darwin SZOMB
    if (alive) {
        NSString *actualBundle = MCBundleIdForPid(pid);
        if (!actualBundle || [actualBundle isEqualToString:bundleIdentifier]) return pid;
    }
    // The process table is authoritative even before SpringBoard refreshes SBApplication.
    for (NSNumber *candidate in MCPidsForIdentifier(bundleIdentifier)) {
        pid_t current = candidate.intValue;
        if (proc_pidinfo(current, VDT_PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info)
            && info.pbi_status != 5) return current;
    }
    return 0;
}

- (BOOL)isForegroundBundleIdentifier:(NSString *)bundleIdentifier
{
    Class controllerClass = NSClassFromString(@"SBApplicationController");
    id controller = [(id)controllerClass sharedInstance];
    id application = [controller applicationWithBundleIdentifier:bundleIdentifier];

    SALiteKVC(application, @"processState");
    id foreground = SALiteKVC(application, @"foreground");
    return [foreground respondsToSelector:@selector(boolValue)] ? [foreground boolValue] : NO;
}

// MARK: - 评估

- (void)evaluateAll
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self evaluateAll];
        });
        return;
    }

    self.policies = [SALiteConfig allPolicies];

    NSMutableSet *bundleIDs = [NSMutableSet setWithArray:self.policies.allKeys];
    [bundleIDs addObjectsFromArray:self.assertions.allKeys];

    if (![SALiteConfig isGlobalEnabled]) {
        for (NSString *bid in [self.assertions.allKeys copy]) {
            [self releaseAssertionForBundleIdentifier:bid];
        }
        return;
    }

    __block BOOL changed = NO;
    for (NSString *bid in bundleIDs) {
        NSDictionary *policy = self.policies[bid] ?: [SALiteConfig policyForBundleIdentifier:bid];
        BOOL enabled = [policy[@"enabled"] boolValue];
        BOOL eligible = [self isPolicyEligible:policy];
        BOOL previous = [self.lastEligibility[bid] boolValue];
        self.lastEligibility[bid] = @(eligible);

        if (enabled) {
            // 条件由不满足变为满足：清掉崩溃屏蔽，允许重新拉起
            if (eligible && !previous) {
                [self.crashBlocked removeObject:bid];
            }
            if (!eligible
                || [self.userBlocked containsObject:bid]
                || [self.crashBlocked containsObject:bid]
                || [self.startupBlocked containsObject:bid]) {
                [self releaseAssertionForBundleIdentifier:bid];
            } else {
                pid_t pid = [self pidForBundleIdentifier:bid];
                if (pid >= 1) {
                    [self ensureAssertionForBundleIdentifier:bid pid:pid];
                } else {
                    [self launchBundleIdentifierInBackground:bid];
                }
            }
        } else {
            if ([self.userBlocked containsObject:bid]) {
                [self.userBlocked removeObject:bid];
                changed = YES;
            }
            [self.crashBlocked removeObject:bid];
            [self.startupBlocked removeObject:bid];
            [self.lastAutoLaunchAt removeObjectForKey:bid];
            [self releaseAssertionForBundleIdentifier:bid];
        }
    }

    if (changed) [self saveRuntimeState];
}

// MARK: - 断言

- (id)acquiredAssertionForPID:(pid_t)pid attributes:(NSArray *)attributes bundleIdentifier:(NSString *)bundleIdentifier
{
    if (attributes.count == 0) return nil;

    Class targetClass = NSClassFromString(@"RBSTarget");
    Class assertionClass = NSClassFromString(@"RBSAssertion");
    if (!targetClass || !assertionClass) return nil;

    id target = [(id)targetClass targetWithPid:pid];
    RBSAssertion *assertion = [[(id)assertionClass alloc]
                               initWithExplanation:[NSString stringWithFormat:SALiteAssertionExplanation, bundleIdentifier]
                                            target:target
                                        attributes:attributes];
    NSError *error = nil;
    if ([assertion acquireWithError:&error]) return assertion;

    [assertion invalidate];
    return nil;
}

- (id)legacyProcessAssertionForPID:(pid_t)pid bundleIdentifier:(NSString *)bundleIdentifier
{
    Class assertionClass = NSClassFromString(@"BKSProcessAssertion");
    if (!assertionClass) return nil;

    BKSProcessAssertion *assertion = [[(id)assertionClass alloc]
                                      initWithPID:pid
                                      flags:SALiteAssertionFlags
                                      reason:SALiteAssertionReason
                                      name:[NSString stringWithFormat:SALiteAssertionExplanation, bundleIdentifier]];
    if ([assertion respondsToSelector:@selector(valid)] && ![assertion valid]) {
        [assertion invalidate];
        return nil;
    }
    return assertion;
}

- (void)ensureAssertionForBundleIdentifier:(NSString *)bundleIdentifier pid:(pid_t)pid
{
    [self subscribeToDeathForBundleIdentifier:bundleIdentifier pid:pid];

    NSNumber *currentPID = self.assertionPIDs[bundleIdentifier];
    id assertion = self.assertions[bundleIdentifier];
    if (assertion && currentPID && currentPID.intValue == pid) return;

    [self releaseAssertionForBundleIdentifier:bundleIdentifier];

    NSMutableArray *attributes = [NSMutableArray array];

    Class legacyClass = NSClassFromString(@"RBSLegacyAttribute");
    RBSLegacyAttribute *legacyAttribute = nil;
    if ([legacyClass respondsToSelector:@selector(attributeWithReason:flags:)]) {
        legacyAttribute = [(id)legacyClass attributeWithReason:SALiteAssertionReason flags:SALiteAssertionFlags];
        if (legacyAttribute) [attributes addObject:legacyAttribute];
    }

    Class domainClass = NSClassFromString(@"RBSDomainAttribute");
    RBSDomainAttribute *domainAttribute = nil;
    if ([domainClass respondsToSelector:@selector(attributeWithDomain:name:)]) {
        domainAttribute = [(id)domainClass attributeWithDomain:SALiteRBSDomainFrontboard
                                                          name:SALiteRBSDomainAttrName];
        if (domainAttribute) [attributes addObject:domainAttribute];
    }

    // 依次降级：组合属性 → 仅 Legacy → 仅 Domain → BKS
    id acquired = [self acquiredAssertionForPID:pid attributes:attributes bundleIdentifier:bundleIdentifier];
    if (!acquired && legacyAttribute) {
        acquired = [self acquiredAssertionForPID:pid attributes:@[legacyAttribute] bundleIdentifier:bundleIdentifier];
    }
    if (!acquired && domainAttribute) {
        acquired = [self acquiredAssertionForPID:pid attributes:@[domainAttribute] bundleIdentifier:bundleIdentifier];
    }
    if (!acquired) {
        acquired = [self legacyProcessAssertionForPID:pid bundleIdentifier:bundleIdentifier];
    }

    if (acquired) {
        self.assertions[bundleIdentifier] = acquired;
        self.assertionPIDs[bundleIdentifier] = @(pid);
    }
}

- (void)releaseAssertionForBundleIdentifier:(NSString *)bundleIdentifier
{
    id assertion = self.assertions[bundleIdentifier];
    if ([assertion respondsToSelector:@selector(invalidate)]) {
        [assertion invalidate];
    }
    [self.assertions removeObjectForKey:bundleIdentifier];
    [self.assertionPIDs removeObjectForKey:bundleIdentifier];
}

// MARK: - 进程死亡订阅

- (void)subscribeToDeathForBundleIdentifier:(NSString *)bundleIdentifier pid:(pid_t)pid
{
    SALiteLoadAssertionFrameworks();
    NSNumber *key = @(pid);
    if ([self.watchedPIDs containsObject:key]) return;

    [self.watchedPIDs addObject:key];
    __weak typeof(self) weakSelf = self;
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)pid,
                                                      DISPATCH_PROC_EXIT, dispatch_get_main_queue());
    if (source) {
        self.deathSources[key] = source;
        dispatch_source_set_event_handler(source, ^{
            __strong typeof(weakSelf) self = weakSelf;
            [self processDidExitBundleIdentifier:bundleIdentifier pid:pid];
        });
        dispatch_resume(source);
    }

    Class identifierClass = NSClassFromString(@"RBSProcessIdentifier");
    Class connectionClass = NSClassFromString(@"RBSConnection");
    RBSProcessIdentifier *identifier = identifierClass ? [(id)identifierClass identifierWithPid:pid] : nil;
    RBSConnection *connection = connectionClass ? [(id)connectionClass sharedInstance] : nil;
    if (identifier && [connection respondsToSelector:@selector(subscribeToProcessDeath:handler:)]) {
        [connection subscribeToProcessDeath:identifier handler:^{
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                [self processDidExitBundleIdentifier:bundleIdentifier pid:pid];
            });
        }];
    } else if (!source) {
        [self.watchedPIDs removeObject:key];
    }
    SALiteLog([NSString stringWithFormat:@"监听 %@ PID:%d proc:%@ RBS:%@", bundleIdentifier, pid,
               source ? @"是" : @"否", identifier && connection ? @"是" : @"否"]);
    // Close the gap between discovering the PID and registering both exit observers.
    struct vdt_proc_bsdinfo info = {0};
    if ((kill(pid, 0) == -1 && errno == ESRCH)
        || (proc_pidinfo(pid, VDT_PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info)
            && info.pbi_status == 5)) {
        [self processDidExitBundleIdentifier:bundleIdentifier pid:pid];
    }
}

- (void)processDidExitBundleIdentifier:(NSString *)bundleIdentifier pid:(pid_t)pid
{
    NSNumber *key = @(pid);
    if (![self.watchedPIDs containsObject:key]) return;
    SALiteLog([NSString stringWithFormat:@"退出通知 %@ PID:%d", bundleIdentifier, pid]);
    [self.watchedPIDs removeObject:key];
    dispatch_source_t source = self.deathSources[key];
    if (source) {
        dispatch_source_cancel(source);
        [self.deathSources removeObjectForKey:key];
    }
    [self handleDeathForBundleIdentifier:bundleIdentifier pid:pid];
}

- (void)handleDeathForBundleIdentifier:(NSString *)bundleIdentifier pid:(pid_t)pid
{
    if ([self.assertionPIDs[bundleIdentifier] intValue] == pid) {
        [self releaseAssertionForBundleIdentifier:bundleIdentifier];
    }
    if ([self.userBlocked containsObject:bundleIdentifier]) {
        SALiteLog([NSString stringWithFormat:@"跳过拉起 %@：用户已屏蔽", bundleIdentifier]);
        return;
    }

    NSDictionary *policy = [SALiteConfig policyForBundleIdentifier:bundleIdentifier];
    if (![self isPolicyEligible:policy]) {
        SALiteLog([NSString stringWithFormat:@"跳过拉起 %@：配置未启用或条件不满足", bundleIdentifier]);
        return;
    }

    if (![policy[@"relaunchOnCrash"] boolValue]) {
        [self.crashBlocked addObject:bundleIdentifier];
        return;
    }

    int64_t delay = SALiteCrashRelaunchDelay;
    if ([SALiteConfig globalBoolForKey:@"crashLoopProtection"]) {
        double last = [self.lastAutoLaunchAt[bundleIdentifier] doubleValue];
        double now = [NSDate date].timeIntervalSince1970;
        // 短时间内反复崩溃：改用较长的唤醒间隔，避免拉起风暴
        if (last > 0 && (now - last) <= SALiteCrashLoopWindow) {
            NSInteger configured = [SALiteConfig globalIntegerForKey:@"crashWakeInterval"];
            NSInteger seconds = configured > 0 ? MAX(configured, 1) : SALiteDefaultCrashWake;
            delay = (int64_t)((double)seconds * NSEC_PER_SEC);
        }
    }

    __weak typeof(self) weakSelf = self;
    SALiteLog([NSString stringWithFormat:@"计划拉起 %@ 延迟:%.1f秒", bundleIdentifier,
               (double)delay / NSEC_PER_SEC]);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if ([self.userBlocked containsObject:bundleIdentifier]) return;

        NSDictionary *current = [SALiteConfig policyForBundleIdentifier:bundleIdentifier];
        pid_t currentPID = [self pidForBundleIdentifier:bundleIdentifier];
        // The exit notification identifies a dead process even when SpringBoard still caches its PID.
        if ([self isPolicyEligible:current] && (currentPID <= 0 || currentPID == pid)) {
            [self launchBundleIdentifierInBackground:bundleIdentifier];
        } else {
            SALiteLog([NSString stringWithFormat:@"取消拉起 %@ 当前PID:%d", bundleIdentifier, currentPID]);
        }
    });
}

// MARK: - 后台拉起

- (void)launchBundleIdentifierInBackground:(NSString *)bundleIdentifier
{
    if (bundleIdentifier.length == 0) return;
    if ([self.autoLaunchPending containsObject:bundleIdentifier]) return;
    if ([self.userBlocked containsObject:bundleIdentifier]) return;

    [self.autoLaunchPending addObject:bundleIdentifier];
    SALiteLog([NSString stringWithFormat:@"请求后台拉起 %@", bundleIdentifier]);
    self.lastAutoLaunchAt[bundleIdentifier] = @([NSDate date].timeIntervalSince1970);

    BOOL launched = NO;
    UIApplication *application = [UIApplication sharedApplication];
    SEL launchSelector = NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:");
    if ([application respondsToSelector:launchSelector]) {
        launched = ((BOOL (*)(id, SEL, NSString *, BOOL))objc_msgSend)(application, launchSelector,
                                                                      bundleIdentifier, YES);
    }

    if (!launched) {
        SALiteLoadLaunchFrameworks();

        Class optionsClass = NSClassFromString(@"FBSOpenApplicationOptions");
        Class serviceClass = NSClassFromString(@"FBSSystemService");
        if ([optionsClass respondsToSelector:@selector(optionsWithDictionary:)]
            && [serviceClass respondsToSelector:@selector(sharedService)]) {
            FBSOpenApplicationOptions *options = [(id)optionsClass
                optionsWithDictionary:@{@"__ActivateSuspended": @YES,
                                        @"__LaunchOrigin": @"StayAlive Lite"}];
            FBSSystemService *service = [(id)serviceClass sharedService];
            if ([service respondsToSelector:@selector(openApplication:options:withResult:)]) {
                [service openApplication:bundleIdentifier options:options withResult:^(NSError *error) {
                    if (error) SALiteLog([NSString stringWithFormat:@"拉起失败 %@：%@", bundleIdentifier, error]);
                }];
            } else {
                SALiteLog([NSString stringWithFormat:@"拉起失败 %@：FBS 接口不可用", bundleIdentifier]);
                [self.autoLaunchPending removeObject:bundleIdentifier];
            }
        } else {
            SALiteLog([NSString stringWithFormat:@"拉起失败 %@：启动框架不可用", bundleIdentifier]);
            [self.autoLaunchPending removeObject:bundleIdentifier];
        }
    }

    // 进程出现后分三次补挂断言，覆盖不同启动耗时
    __weak typeof(self) weakSelf = self;
    for (NSNumber *seconds in SALiteLaunchRetryDelays()) {
        int64_t when = (int64_t)(seconds.doubleValue * NSEC_PER_SEC);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, when), dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            pid_t pid = [self pidForBundleIdentifier:bundleIdentifier];
            if (pid < 1) return;

            NSDictionary *policy = [SALiteConfig policyForBundleIdentifier:bundleIdentifier];
            if ([self isPolicyEligible:policy] && ![self.userBlocked containsObject:bundleIdentifier]) {
                [self ensureAssertionForBundleIdentifier:bundleIdentifier pid:pid];
            }
        });
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, SALiteAutoLaunchTimeout),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        [self.autoLaunchPending removeObject:bundleIdentifier];
    });
}

// MARK: - 用户主动结束

- (void)markUserKilledBundleIdentifier:(NSString *)bundleIdentifier
{
    if (bundleIdentifier.length == 0) return;

    NSDictionary *policy = [SALiteConfig policyForBundleIdentifier:bundleIdentifier];
    if (![policy[@"enabled"] boolValue]) return;

    [self.userBlocked addObject:bundleIdentifier];
    [self.crashBlocked removeObject:bundleIdentifier];
    [self.autoLaunchPending removeObject:bundleIdentifier];
    [self releaseAssertionForBundleIdentifier:bundleIdentifier];
    [self saveRuntimeState];
}

- (NSString *)bundleIdentifierForProcess:(id)process
{
    NSString *bundleIdentifier = SALiteKVCString(process, @"bundleIdentifier");
    if (bundleIdentifier.length) return bundleIdentifier;

    id identity = SALiteKVC(process, @"identity");
    bundleIdentifier = SALiteKVCString(identity, @"embeddedApplicationIdentifier");
    if (bundleIdentifier.length) return bundleIdentifier;

    return SALiteKVCString(identity, @"bundleIdentifier");
}

- (void)applicationProcessDidLaunch:(id)process
{
    if (!self.started) return;

    NSString *bundleIdentifier = [self bundleIdentifierForProcess:process];
    if (bundleIdentifier.length == 0) return;

    BOOL wasPending = [self.autoLaunchPending containsObject:bundleIdentifier];
    if (wasPending) {
        SALiteLog([NSString stringWithFormat:@"已启动 %@", bundleIdentifier]);
        [self.autoLaunchPending removeObject:bundleIdentifier];
    }
    [self.startupBlocked removeObject:bundleIdentifier];

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, SALitePostLaunchDelay),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        // 不是我们自己拉起、却是用户屏蔽的 App 跑到前台 → 用户在主动使用它，解除屏蔽
        if (!wasPending
            && [self.userBlocked containsObject:bundleIdentifier]
            && [self isForegroundBundleIdentifier:bundleIdentifier]) {
            [self.userBlocked removeObject:bundleIdentifier];
            [self.crashBlocked removeObject:bundleIdentifier];
            [self saveRuntimeState];
        }
        [self evaluateAll];
    });
}

@end
