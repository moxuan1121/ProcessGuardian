/**
 * Preferences.h —— Preferences.framework 私有头的最小声明。
 *
 * 该 framework 不在 iOS SDK 里，PreferenceLoader 面板必须自带一份声明。只声明本项目
 * 实际用到的成员；实现由设备上系统那份 framework 在运行时提供，所以链接要允许
 * 未定义符号（见 Makefile 的 -undefined dynamic_lookup）。
 */
#ifndef MC_PREFERENCES_SHIM_H
#define MC_PREFERENCES_SHIM_H

#import <UIKit/UIKit.h>

@class PSSpecifier;

/** 面板里所有可 push 的页面都以它为基类：这样就能拿到 specifier（即配置键）。 */
@interface PSViewController : UIViewController
@property (nonatomic, strong) PSSpecifier *specifier;
@end

@interface PSListController : PSViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView *tableview;
@property (nonatomic, strong) NSArray<PSSpecifier *> *specifiers;
/** 读取 PreferenceBundle 内同名 plist 并解析成 specifier 数组。 */
- (NSArray<PSSpecifier *> *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (id)preferenceValueForSpecifier:(PSSpecifier *)specifier;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
@end

/**
 * PreferenceLoader 里以编程方式造 specifier 的常规入口。
 * 其余字段一律通过 properties / titleDictionary 两个字典塞进去，
 * 键名与 Root.plist 里写的完全一致（CellType、Label、Detail、Plural...）。
 */
@interface PSSpecifier : NSObject
+ (PSSpecifier *)emptySpecifier;
@property (nonatomic, copy) NSString *property;
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *label;
@property (nonatomic, copy) NSString *footerText;
@property (nonatomic) Class cellClass;
@property (nonatomic) Class controllerClass;
@property (nonatomic, strong) NSMutableDictionary *properties;
@property (nonatomic, strong) NSMutableDictionary *titleDictionary;
@end

#endif /* MC_PREFERENCES_SHIM_H */
