//
//  SALitePrivateAPI.h
//  只声明接口、不提供实现：所有实例都通过 NSClassFromString 拿到 Class 后以
//  objc_msgSend 发消息，因此链接期不会产生 _OBJC_CLASS_$_RBSTarget 之类的符号引用。
//
//  调用约定：
//      Class cls = NSClassFromString(@"RBSTarget");
//      id target = [(id)cls targetWithPid:pid];
//

#import <Foundation/Foundation.h>
#import <TargetConditionals.h>

@interface NSObject (SALiteSpringBoardController)
- (id)applicationWithBundleIdentifier:(NSString *)bundleIdentifier;
@end

// MARK: - RunningBoardServices

@interface RBSAssertion : NSObject
- (instancetype)initWithExplanation:(NSString *)explanation
                             target:(id)target
                         attributes:(NSArray *)attributes;
- (BOOL)acquireWithError:(NSError **)error;
- (void)invalidate;
@end

@interface RBSTarget : NSObject
+ (instancetype)targetWithPid:(pid_t)pid;
@end

@interface RBSLegacyAttribute : NSObject
+ (instancetype)attributeWithReason:(NSInteger)reason flags:(NSUInteger)flags;
@end

@interface RBSDomainAttribute : NSObject
+ (instancetype)attributeWithDomain:(NSString *)domain name:(NSString *)name;
@end

@interface RBSProcessIdentifier : NSObject
+ (instancetype)identifierWithPid:(pid_t)pid;
@end

@interface RBSConnection : NSObject
+ (instancetype)sharedInstance;
- (void)subscribeToProcessDeath:(RBSProcessIdentifier *)identifier handler:(dispatch_block_t)handler;
@end

// MARK: - BackBoardServices（iOS 15 以前的兜底路径）

@interface BKSProcessAssertion : NSObject
- (instancetype)initWithPID:(pid_t)pid flags:(NSUInteger)flags reason:(NSInteger)reason name:(NSString *)name;
- (BOOL)valid;
- (void)invalidate;
@end

// MARK: - FrontBoardServices

@interface FBSOpenApplicationOptions : NSObject
+ (instancetype)optionsWithDictionary:(NSDictionary *)dictionary;
@end

@interface FBSSystemService : NSObject
+ (instancetype)sharedService;
- (void)openApplication:(NSString *)bundleIdentifier
                options:(FBSOpenApplicationOptions *)options
             withResult:(void (^)(NSError *error))result;
@end

// MARK: - SpringBoardServices

@interface SBSApplicationShortcutIcon : NSObject
- (instancetype)initWithSystemImageName:(NSString *)systemImageName;
@end

@interface SBSApplicationShortcutItem : NSObject
@property (nonatomic, copy) NSString *type;
@property (nonatomic, copy) NSString *localizedTitle;
@property (nonatomic, copy) NSDictionary *userInfo;
@property (nonatomic, strong) SBSApplicationShortcutIcon *icon;
@end
