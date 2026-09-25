/**
 * Tweak.x —— 注入 SpringBoard 的前台切换探针。
 *
 * 原版通过 MSHookMessageEx 交换 -[SpringBoard frontDisplayDidChange:]。
 * 这里改用纯 Objective-C runtime（method_setImplementation），使同一个 dylib
 * 在 Substrate、Substitute 以及 TrollFools 直接注入场景下都能加载，
 * 不再产生对 CydiaSubstrate.framework 的链接期依赖。
 *
 * 应用启动通知用于及时应用内存和优先级配置。
 */
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>
#import <UIKit/UIKit.h>
#import <notify.h>

static NSString *const kApplyLimitsNotification = @"com.moxuan.processguardian/ProcessChanged";
static const char *kCPUFrontmostNotification = "com.moxuan.processguardian/CPUFrontmost";
static int sCPUFrontmostToken = -1;

static void MCPostFrontmost(void) {
    UIApplication *app = UIApplication.sharedApplication;
    SEL selector = sel_registerName("_accessibilityFrontMostApplication");
    id front = [app respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(app, selector) : nil;
    NSString *bundle = [front respondsToSelector:@selector(bundleIdentifier)] ? [front bundleIdentifier] : nil;
    uint64_t hash = 0;
    if (bundle.length) {
        hash = 1469598103934665603ULL;
        const unsigned char *bytes = (const unsigned char *)bundle.UTF8String;
        for (; *bytes; bytes++) { hash ^= *bytes; hash *= 1099511628211ULL; }
    }
    if (sCPUFrontmostToken >= 0) notify_set_state(sCPUFrontmostToken, hash);
    notify_post(kCPUFrontmostNotification);
}

typedef void (*MCFrontDisplayChangedIMP)(id, SEL, id);

/* 原 IMP 属于类而非实例，associated object 无从挂载，用文件静态变量保存。 */
static MCFrontDisplayChangedIMP sOriginalIMP;
static MCFrontDisplayChangedIMP sOriginalProcessLaunchIMP;

static void MC_applicationProcessDidLaunch(id self, SEL cmd, id process) {
    if (sOriginalProcessLaunchIMP) sOriginalProcessLaunchIMP(self, cmd, process);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)kApplyLimitsNotification, NULL, NULL, true);
}

static void MC_frontDisplayDidChange(id self, SEL _cmd, id display) {
    if (sOriginalIMP) sOriginalIMP(self, _cmd, display);
    MCPostFrontmost();

    /* 只发一个纯信号，不带 payload：读配置、算 PID、下内核调用全在守护进程里。 */
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)kApplyLimitsNotification,
        NULL, NULL, true);
}

static void MCInstall(void) {
    Class cls = objc_getClass("SpringBoard");
    if (!cls) return;                       /* 非 SpringBoard 进程，静默退出 */
    notify_register_check(kCPUFrontmostNotification, &sCPUFrontmostToken);
    dispatch_async(dispatch_get_main_queue(), ^{ MCPostFrontmost(); });

    Class workspace = objc_getClass("SBMainWorkspace");
    SEL launch = sel_registerName("applicationProcessDidLaunch:");
    Method launchMethod = class_getInstanceMethod(workspace, launch);
    if (launchMethod) {
        sOriginalProcessLaunchIMP = (MCFrontDisplayChangedIMP)method_getImplementation(launchMethod);
        if (!class_addMethod(workspace, launch, (IMP)MC_applicationProcessDidLaunch,
                             method_getTypeEncoding(launchMethod)))
            method_setImplementation(launchMethod, (IMP)MC_applicationProcessDidLaunch);
    }

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
    }
}
