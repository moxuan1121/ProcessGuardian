/**
 * MCCommon.h —— 守护进程与偏好面板共享的配置模型、路径与日志。
 */
#ifndef MC_COMMON_H
#define MC_COMMON_H

#import <Foundation/Foundation.h>
#import "MCKernel.h"

/** 偏好域。改这一处即可整体换名，避免与原 tweak 冲突。 */
extern NSString *const MCDomain;
/** SpringBoard tweak 与守护进程之间的 Darwin 通知名。 */
extern NSString *const MCApplyLimitsNotification;
/** 状态回写文件（偏好面板读取以显示 PID）。 */
extern NSString *const MCStatusFileName;
/** 守护进程日志文件名，位于 MobileSupport 或 jbroot 下的 Library/Logs。 */
extern NSString *const MCLogFileName;

extern const NSInteger MCDefaultCheckInterval;   /* 1800 秒 */
extern const double  MCDefaultLogSizeLimitMB;   /* 2 MB  */

@interface MCProcessConfig : NSObject <NSCopying>

@property (nonatomic, copy)   NSString *key;          /* AppConfigs 里的键：进程名或包名 */

/* 数值型 */
@property (nonatomic, assign) NSInteger memLimitActive;    /* MB；0=不设置，-1=不受限 */
@property (nonatomic, assign) NSInteger memLimitInactive;  /* MB；同上 */
@property (nonatomic, assign) NSInteger jetsamPriority;    /* -1=不动，0=交还系统 */
@property (nonatomic, assign) NSInteger niceValue;         /* PRIO_MIN..PRIO_MAX */
@property (nonatomic, assign) NSInteger cpuThreshold;     /* 前台 CPU 百分比；0=关闭 */
@property (nonatomic, assign) NSInteger cpuDuration;      /* 连续超限秒数 */
@property (nonatomic, assign) BOOL keepAlive;
@property (nonatomic, assign) BOOL relaunchAfterRespring;

@property (nonatomic, copy)   NSString *remark;       /* 偏好面板显示名 */

+ (instancetype)configWithDictionary:(NSDictionary *)dict key:(NSString *)key;
/** 全默认值（不设限额、不动优先级、所有强锁关闭）。 */
+ (instancetype)defaultConfigForIdentifier:(NSString *)key;
- (NSDictionary *)dictionaryValue;
/** 至少有一项需要处理（否则守护进程可以直接跳过该进程）。 */
- (BOOL)hasAnythingToApply;
@end

@interface MCCommon : NSObject

/** RootHide 共享偏好目录。 */
+ (NSString *)preferencesDirectory;
+ (NSString *)preferencesPlistPath;
+ (NSString *)statusPlistPath;
+ (NSString *)logFilePath;

/** 读取整个偏好字典。 */
+ (NSDictionary *)readPreferences;
+ (NSDictionary *)readStatus;
+ (void)writeStatus:(NSDictionary *)status;

/** AppConfigs -> { key : MCProcessConfig } */
+ (NSDictionary<NSString *, MCProcessConfig *> *)parsedAppConfigs;

/** 默认预设：守护进程首次运行若 AppConfigs 为空则写入。 */
+ (NSDictionary *)defaultAppConfigs;

/** 供守护进程与面板共用的时间戳格式化。 */
+ (NSString *)timestampString;

@end

/** 按进程名 / 包名解析 PID 列表；找不到返回空数组。 */
NSArray<NSNumber *> *MCPidsForIdentifier(NSString *identifier);
/** 单个 PID 的可执行文件名。 */
NSString *MCProcessNameForPid(pid_t pid);
/** 由 pid 的可执行路径推出 bundle identifier（读 Info.plist）。 */
NSString *MCBundleIdForPid(pid_t pid);

#endif /* MC_COMMON_H */
