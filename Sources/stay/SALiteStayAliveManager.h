//
//  SALiteStayAliveManager.h
//  StayAlive Lite —— SpringBoard 侧守护核心
//

#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>

NS_ASSUME_NONNULL_BEGIN

/// 私有对象结构随系统版本变化，统一走安全的 KVC 取值
FOUNDATION_EXPORT id _Nullable SALiteKVC(id _Nullable object, NSString *key);
FOUNDATION_EXPORT NSString *_Nullable SALiteKVCString(id _Nullable object, NSString *key);

/// 私有框架按需加载（0.1.7 起不在 -start 里做，避免 SpringBoard 启动阶段就 dlopen）
FOUNDATION_EXPORT void SALiteLoadAssertionFrameworks(void);
FOUNDATION_EXPORT void SALiteLoadLaunchFrameworks(void);

@interface SALiteStayAliveManager : NSObject

/// 0.1.7：-start 是否已经执行过，避免重复启动
@property (nonatomic, assign) BOOL started;
/// 0.1.7：启动恢复队列是否已经排好下一步
@property (nonatomic, assign) BOOL startupRecoveryScheduled;
/// 全局开关 / 定时边界重排的通知令牌
@property (nonatomic, assign) int preferencesToken;

/// bid -> RBSAssertion / BKSProcessAssertion
@property (nonatomic, strong) NSMutableDictionary *assertions;
/// bid -> NSNumber(pid)
@property (nonatomic, strong) NSMutableDictionary *assertionPIDs;
/// 用户手动上滑杀掉的 App，不再自动拉起
@property (nonatomic, strong) NSMutableSet<NSString *> *userBlocked;
/// 崩溃后暂不拉起的 App
@property (nonatomic, strong) NSMutableSet<NSString *> *crashBlocked;
/// 注销后不自动拉起的 App
@property (nonatomic, strong) NSMutableSet<NSString *> *startupBlocked;
/// 正在等待启动结果
@property (nonatomic, strong) NSMutableSet<NSString *> *autoLaunchPending;
/// 已订阅进程死亡的 pid
@property (nonatomic, strong) NSMutableSet<NSNumber *> *watchedPIDs;
/// bid -> @(eligible)，用于检测上升沿
@property (nonatomic, strong) NSMutableDictionary *lastEligibility;
/// bid -> @(timeIntervalSince1970)
@property (nonatomic, strong) NSMutableDictionary *lastAutoLaunchAt;

@property (nonatomic, copy) NSDictionary<NSString *, NSDictionary *> *policies;
/// 0.1.7：注销后需要按顺序恢复守护的 bid，逐个错峰处理
@property (nonatomic, strong) NSMutableArray<NSString *> *startupRecoveryQueue;
@property (nonatomic, assign) SCNetworkReachabilityRef reachability;
@property (nonatomic, strong) dispatch_source_t _Nullable boundaryTimer;

+ (instancetype)sharedManager;

- (void)start;
- (void)evaluateAll;
- (void)scheduleNextBoundary;
- (void)saveRuntimeState;
- (void)markUserKilledBundleIdentifier:(NSString *)bundleIdentifier;
- (void)applicationProcessDidLaunch:(id)process;

@end

NS_ASSUME_NONNULL_END
