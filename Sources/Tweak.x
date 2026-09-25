/**
 * Tweak.x —— 注入 SpringBoard 的前台切换探针。
 *
 * 原版通过 MSHookMessageEx 交换 -[SpringBoard frontDisplayDidChange:]。
 * 这里改用纯 Objective-C runtime（method_setImplementation），使同一个 dylib
 * 在 Substrate、Substitute 以及 TrollFools 直接注入场景下都能加载，
 * 不再产生对 CydiaSubstrate.framework 的链接期依赖。
 *
 * 通知名在这里是硬编码常量，dylib 因此不链接 MCCommon.m —— 保持和原版一样小。
 */
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>
#import <UIKit/UIKit.h>
#import "MCCPUGuard.h"

static NSString *const kApplyLimitsNotification = @"com.moxuan.processguardian/ProcessChanged";

typedef void (*MCFrontDisplayChangedIMP)(id, SEL, id);

/* 原 IMP 属于类而非实例，associated object 无从挂载，用文件静态变量保存。 */
static MCFrontDisplayChangedIMP sOriginalIMP;

static NSString *MCFrontmostBundle(void) {
    id app = UIApplication.sharedApplication;
    SEL front = sel_registerName("_accessibilityFrontMostApplication");
    if (![app respondsToSelector:front]) return nil;
    id current = ((id (*)(id, SEL))objc_msgSend)(app, front);
    SEL identifier = sel_registerName("bundleIdentifier");
    return [current respondsToSelector:identifier] ? ((id (*)(id, SEL))objc_msgSend)(current, identifier) : nil;
}

static void MC_frontDisplayDidChange(id self, SEL _cmd, id display) {
    if (sOriginalIMP) sOriginalIMP(self, _cmd, display);
    MCCPUGuardFrontmostChanged(MCFrontmostBundle());

    /* 只发一个纯信号，不带 payload：读配置、算 PID、下内核调用全在守护进程里。 */
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)kApplyLimitsNotification,
        NULL, NULL, true);
}

static void MCInstall(void) {
    Class cls = objc_getClass("SpringBoard");
    if (!cls) return;                       /* 非 SpringBoard 进程，静默退出 */

    SEL sel = sel_registerName("frontDisplayDidChange:");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;

    sOriginalIMP = (MCFrontDisplayChangedIMP)method_getImplementation(m);
    if (!sOriginalIMP) return;
    method_setImplementation(m, (IMP)MC_frontDisplayDidChange);
}

__attribute__((constructor))
static void MCTweakMain(void) {
    @autoreleasepool {
        MCInstall();
        dispatch_async(dispatch_get_main_queue(), ^{ MCCPUGuardFrontmostChanged(MCFrontmostBundle()); });
    }
}
