/**
 * MCPrefs.h —— 偏好面板共享的读写工具。
 *
 * 面板运行在 Preferences.app 进程内（mobile 身份），守护进程以 root 运行，
 * 两者唯一的接口就是那个偏好 plist + 一个 Darwin 通知，所以这里只封装这两件事。
 * 路径与常量全部复用 MCCommon，避免面板和守护进程各写一份字符串然后对不上。
 */
#import <Foundation/Foundation.h>
#import <notify.h>
#import "../MCCommon.h"

@interface MCPrefs : NSObject

/** 读整个偏好字典（永远返回非 nil 的可变副本）。 */
+ (NSMutableDictionary *)readPrefs;
/** 落盘；wake 为真时立刻发通知让守护进程跑一轮。 */
+ (void)writePrefs:(NSDictionary *)prefs wakeDaemon:(BOOL)wake;
+ (NSDictionary *)readStatus;

/** 已安装 App：@{ 包名 : 显示名 }。 */
+ (NSDictionary<NSString *, NSString *> *)installedApps;
/** 当前运行的进程名，去重排序。 */
+ (NSArray<NSString *> *)runningProcessNames;

/** 一条配置的人类可读副标题，例如 "PID 1234 · Jetsam 180 · Nice -10"。 */
+ (NSString *)subtitleForIdentifier:(NSString *)key config:(NSDictionary *)cfg;

@end

/** Jetsam band 数值与名称，两数组下标一一对应，供选择器直接使用。 */
FOUNDATION_EXPORT NSArray<NSNumber *> *MCPriorityBands(void);
FOUNDATION_EXPORT NSArray<NSString *> *MCPriorityNames(void);
