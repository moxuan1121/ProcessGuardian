//
//  Tweak.x
//  StayAlive Lite —— SpringBoard 注入入口
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <UIKit/UIKit.h>

#import "SALiteConfig.h"
#import "SALiteStayAliveManager.h"
#import "SALitePrivateAPI.h"

static NSString *const SALiteShortcutType  = @"com.crctdd.stayalivelite.toggle-background";
static NSString *const SALiteUserInfoKey   = @"bundleID";
static NSString *const SALiteSettingsAppID = @"com.apple.Preferences";
static NSString *const SALiteShortcutIcon  = @"arrow.clockwise.circle";

/// 0.1.7：守护核心真正 start 之后才让各个 hook 生效
static BOOL SALiteRuntimeActive = NO;

static const NSTimeInterval SALiteDidFinishLaunchDelay  = 2.0;   // 启动完成通知后的补评估延迟
static const NSTimeInterval SALiteBootstrapFallbackDelay = 6.0;  // 通知未到达时的兜底延迟

// MARK: - 原始实现

static IMP SALiteOriginalKillAppLayout = NULL;
static IMP SALiteOriginalKillContainer = NULL;
static IMP SALiteOriginalProcessDidLaunch = NULL;
static IMP SALiteOriginalShortcutItems = NULL;
static IMP SALiteOriginalActivateShortcut = NULL;

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

/// 长按图标的宿主图标可能提供两种取值方式
static NSString *SALiteIconBundleIdentifier(id iconView)
{
    for (NSString *name in @[ @"applicationBundleIdentifier", @"applicationBundleIdentifierForShortcuts" ]) {
        SEL selector = NSSelectorFromString(name);
        if (![iconView respondsToSelector:selector]) continue;

        id value = ((id (*)(id, SEL))objc_msgSend)(iconView, selector);
        if ([value isKindOfClass:[NSString class]] && [value length]) return value;
    }
    return nil;
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

// MARK: - 长按菜单 Quick Action

static NSArray *SALiteApplicationShortcutItems(id self, SEL _cmd)
{
    NSArray *original = SALiteOriginalShortcutItems
                        ? ((NSArray *(*)(id, SEL))SALiteOriginalShortcutItems)(self, _cmd)
                        : nil;

    if (![SALiteConfig isGlobalEnabled] || ![SALiteConfig globalBoolForKey:@"longPressEnabled"]) {
        return original;
    }

    NSString *bundleIdentifier = SALiteIconBundleIdentifier(self);
    if (bundleIdentifier.length == 0 || [bundleIdentifier isEqualToString:SALiteSettingsAppID]) {
        return original;
    }

    BOOL on = [[SALiteConfig policyForBundleIdentifier:bundleIdentifier] objectForKey:@"enabled"].boolValue;

    NSMutableArray *items = original ? [original mutableCopy] : [NSMutableArray array];

    SALiteLoadLaunchFrameworks();
    Class itemClass = NSClassFromString(@"SBSApplicationShortcutItem");
    SBSApplicationShortcutItem *item = [[(id)itemClass alloc] init];
    if (item) {
        item.type = SALiteShortcutType;
        item.localizedTitle = on ? @"关闭守护后台" : @"开启守护后台";
        item.userInfo = @{ SALiteUserInfoKey: bundleIdentifier };

        Class iconClass = NSClassFromString(@"SBSApplicationShortcutSystemIcon");
        if ([iconClass instancesRespondToSelector:@selector(initWithSystemImageName:)]) {
            item.icon = [[(id)iconClass alloc] initWithSystemImageName:SALiteShortcutIcon];
        }
        [items insertObject:item atIndex:0];
    }

    return items;
}

static void SALiteActivateShortcut(id self, SEL _cmd, id shortcut, NSString *bundleIdentifier, id iconView)
{
    if (![[shortcut type] isEqualToString:SALiteShortcutType]) {
        if (SALiteOriginalActivateShortcut) {
            ((void (*)(id, SEL, id, NSString *, id))SALiteOriginalActivateShortcut)(self, _cmd,
                                                                                   shortcut, bundleIdentifier, iconView);
        }
        return;
    }

    // 自己的快捷方式：直接翻转策略，不再走系统实现
    id value = [shortcut userInfo][SALiteUserInfoKey];
    NSString *target = [value isKindOfClass:[NSString class]] ? value : bundleIdentifier;
    if (target.length == 0) return;

    BOOL on = [[SALiteConfig policyForBundleIdentifier:target] objectForKey:@"enabled"].boolValue;
    [SALiteConfig setValue:@(!on) forKey:@"enabled" bundleIdentifier:target];
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
    MSHookMessageEx(switcher,
                    @selector(killAppLayoutOfContainer:withVelocity:forReason:),
                    (IMP)SALiteKillAppLayoutOfContainer,
                    &SALiteOriginalKillAppLayout);
    MSHookMessageEx(switcher,
                    @selector(killContainer:forReason:),
                    (IMP)SALiteKillContainer,
                    &SALiteOriginalKillContainer);

    MSHookMessageEx(objc_getClass("SBMainWorkspace"),
                    @selector(applicationProcessDidLaunch:),
                    (IMP)SALiteApplicationProcessDidLaunch,
                    &SALiteOriginalProcessDidLaunch);

    dispatch_async(dispatch_get_main_queue(), ^{
        // SpringBoard 启动完成后再补一次评估；若通知没来，兜底定时器同样会启动守护
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                       usingBlock:^{
            SALiteBootstrapAfter(SALiteDidFinishLaunchDelay);
        }];
        SALiteBootstrapAfter(SALiteBootstrapFallbackDelay);
    });
}
