//
//  SALiteConfig.h
//  StayAlive Lite —— 偏好读写层
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN


/// 首选项 plist（rootless: /var/jb/... ；本仓库统一使用 /var/mobile/Library/Preferences）
extern NSString *const SALitePrefsPlistPath;
/// 运行时状态（userBlocked 等）
extern NSString *const SALiteRuntimePlistPath;
/// 设置界面导航状态记忆


@interface SALiteConfig : NSObject

// MARK: 默认值
+ (NSDictionary *)defaultPolicy;
+ (NSDictionary *)defaultGlobalSettings;

// MARK: 原始字典
+ (NSDictionary *)rootDictionary;
+ (NSDictionary *)normalizedDictionary:(nullable id)dict defaults:(NSDictionary *)defaults;

// MARK: 单 App 策略
+ (NSDictionary<NSString *, NSDictionary *> *)allPolicies;
+ (NSDictionary *)policyForBundleIdentifier:(nullable NSString *)bundleIdentifier;

// MARK: 全局设置
+ (NSDictionary *)globalSettings;
+ (nullable id)globalValueForKey:(NSString *)key;
+ (BOOL)globalBoolForKey:(NSString *)key;
+ (NSInteger)globalIntegerForKey:(NSString *)key;
+ (BOOL)isGlobalEnabled;

// MARK: 定时运行
+ (NSInteger)minuteOfDayForDate:(NSDate *)date;
+ (BOOL)isScheduleActiveForPolicy:(NSDictionary *)policy date:(NSDate *)date;

// MARK: 其它
+ (NSString *)sharedPathForPath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
