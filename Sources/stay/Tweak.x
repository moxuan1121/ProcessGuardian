//
//  Tweak.x
//  StayAlive Lite —— SpringBoard 注入入口
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

#import "SALiteConfig.h"
#import "SALiteStayAliveManager.h"
#import "SALitePrivateAPI.h"


/// 0.1.7：守护核心真正 start 之后才让各个 hook 生效
static BOOL SALiteRuntimeActive = NO;

static const NSTimeInterval SALiteDidFinishLaunchDelay  = 2.0;   // 启动完成通知后的补评估延迟
static const NSTimeInterval SALiteBootstrapFallbackDelay = 6.0;  // 通知未到达时的兜底延迟

// MARK: - 原始实现

static IMP SALiteOriginalKillAppLayout = NULL;
static IMP SALiteOriginalKillContainer = NULL;
static IMP SALiteOriginalProcessDidLaunch = NULL;

static void SALiteHook(Class cls, SEL selector, IMP replacement, IMP *original)
{
    if (!cls) return;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    *original = method_getImplementation(method);
    if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) {
        method_setImplementation(method, replacement);
    }
}

// MARK: - 工具

/// 从卡片容器里尽可能完整地取出所有 bundle id（主卡片 / 次要项 / PB 快照 / 全部 item）
static NSArray<NSString *> *SALiteBundleIDsFromContainer(id container)
{
    if (!container) return @[];

    NSMutableOrderedSet *bundleIDs = [NSMutableOrderedSet orderedSet];

    id appLayout = SALiteKVC(container, @"appLayout") ?: container;
    NSString *identifier = SALiteKVCString(appLayout, @"bundleIdentifier");
    if (identifier.length) [bundleIDs addObject:identifier];

    id primaryItem = SALiteKVC(container, @"primaryDisplayItem");
    identifier = SALiteKVCString(primaryItem, @"bundleIdentifier");
    if (identifier.length) [bundleIDs addObject:identifier];

    id protobuf = SALiteKVC(container, @"protobufRepresentation");
    identifier = SALiteKVCString(SALiteKVC(protobuf, @"primaryDisplayItem"), @"bundleIdentifier");
    if (identifier.length) [bundleIDs addObject:identifier];

    NSArray *items = nil;
    SEL allItems = NSSelectorFromString(@"allItems");
    if ([container respondsToSelector:allItems]) {
        id raw = ((id (*)(id, SEL))objc_msgSend)(container, allItems);
        items = [raw isKindOfClass:[NSArray class]] ? raw : nil;
    }
    if (!items) {
        id map = SALiteKVC(container, @"rolesToLayoutItemsMap");
        items = [map isKindOfClass:[NSDictionary class]] ? [map allValues] : nil;
    }

    for (id item in items) {
        id displayItem = SALiteKVC(item, @"displayItem") ?: item;
        identifier = SALiteKVCString(displayItem, @"bundleIdentifier");
        if (identifier.length) [bundleIDs addObject:identifier];
    }

    return [bundleIDs array];
}

// MARK: - 上滑杀进程

static void SALiteKillAppLayoutOfContainer(id self, SEL _cmd, id container, id velocity, NSInteger reason)
{
    if (SALiteRuntimeActive) {
        for (NSString *bundleIdentifier in SALiteBundleIDsFromContainer(container)) {
            [[SALiteStayAliveManager sharedManager] markUserKilledBundleIdentifier:bundleIdentifier];
        }
    }
    if (SALiteOriginalKillAppLayout) {
        ((void (*)(id, SEL, id, id, NSInteger))SALiteOriginalKillAppLayout)(self, _cmd, container, velocity, reason);
    }
}

static void SALiteKillContainer(id self, SEL _cmd, id container, NSInteger reason)
{
    if (SALiteRuntimeActive) {
        for (NSString *bundleIdentifier in SALiteBundleIDsFromContainer(container)) {
            [[SALiteStayAliveManager sharedManager] markUserKilledBundleIdentifier:bundleIdentifier];
        }
    }
    if (SALiteOriginalKillContainer) {
        ((void (*)(id, SEL, id, NSInteger))SALiteOriginalKillContainer)(self, _cmd, container, reason);
    }
}

// MARK: - 进程启动

static void SALiteApplicationProcessDidLaunch(id self, SEL _cmd, id process)
{
    if (SALiteOriginalProcessDidLaunch) {
        ((void (*)(id, SEL, id))SALiteOriginalProcessDidLaunch)(self, _cmd, process);
    }
    if (SALiteRuntimeActive) {
        [[SALiteStayAliveManager sharedManager] applicationProcessDidLaunch:process];
    }
}

// MARK: - 入口

/// 0.1.7：守护核心延后到 SpringBoard 真正可用时才启动，且只启动一次
static void SALiteBootstrapAfter(NSTimeInterval seconds)
{
    static dispatch_once_t startOnce;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        dispatch_once(&startOnce, ^{
            SALiteRuntimeActive = YES;
            [[SALiteStayAliveManager sharedManager] start];
        });
    });
}

%ctor
{
    if (![[NSProcessInfo processInfo].processName isEqualToString:@"SpringBoard"]) return;

    Class switcher = objc_getClass("SBFluidSwitcherViewController");
    SALiteHook(switcher,
                    @selector(killAppLayoutOfContainer:withVelocity:forReason:),
                    (IMP)SALiteKillAppLayoutOfContainer,
                    &SALiteOriginalKillAppLayout);
    SALiteHook(switcher,
                    @selector(killContainer:forReason:),
                    (IMP)SALiteKillContainer,
                    &SALiteOriginalKillContainer);

    SALiteHook(objc_getClass("SBMainWorkspace"),
                    @selector(applicationProcessDidLaunch:),
                    (IMP)SALiteApplicationProcessDidLaunch,
                    &SALiteOriginalProcessDidLaunch);

    dispatch_async(dispatch_get_main_queue(), ^{
        // SpringBoard 启动完成后再补一次评估；若通知没来，兜底定时器同样会启动守护
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                       usingBlock:^(NSNotification *notification){
            SALiteBootstrapAfter(SALiteDidFinishLaunchDelay);
        }];
        SALiteBootstrapAfter(SALiteBootstrapFallbackDelay);
    });
}
