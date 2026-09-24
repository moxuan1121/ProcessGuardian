/**
 * MCPrefsClasses.h —— 偏好面板各页面与自定义 cell 的声明。
 *
 * 合并成一个头文件而不是每个类一份：它们互相引用（根面板 push 列表页、列表页 push
 * 编辑器、编辑器 present 选择器），拆开就要来回前置声明，反而容易漂移。
 */
#ifndef MC_PREFS_CLASSES_H
#define MC_PREFS_CLASSES_H

#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import "MCPrefs.h"

/** 列表排序方式，值存在偏好域的 SortMode 键里，由列表页读取后应用。 */
typedef NS_ENUM(NSInteger, MCListSortMode) {
    MCListSortDefault  = 0,
    MCListSortByNice   = 1,
    MCListSortByJetsam = 2,
};

/** 进程行：备注为主标题，运行状态/生效摘要为副标题。三个列表页共用，复用标识为 @"MCAppProcessCell"。 */
@interface MCAppProcessCell : UITableViewCell
- (void)configureWithTitle:(NSString *)title subtitle:(NSString *)subtitle running:(BOOL)running;
@end

@interface MCRootProcessCell : PSTableCell
@end

/** 根面板：设置项和已添加进程一起展示。 */
@interface ProcessGuardianPrefsListController : PSListController
@end

/** 选择要纳管的对象（已安装 App / 正在运行的进程）。 */
@interface MCAppListViewController : UIViewController <UITableViewDataSource,
                                                       UITableViewDelegate,
                                                       UISearchResultsUpdating,
                                                       UISearchControllerDelegate>
/** 选中一条后回调，参数是包名或进程名。 */
@property (nonatomic, copy) void (^onPick)(NSString *identifier);
/** 选「应用程序」还是「运行中的进程」。 */
@property (nonatomic, assign) BOOL pickProcesses;
@end

/** 单条配置的编辑器。 */
@interface MCProcessEditViewController : UIViewController <UITableViewDataSource,
                                                          UITableViewDelegate>
/** AppConfigs 里的键（包名或进程名）。 */
@property (nonatomic, copy) NSString *targetIdentifier;
@property (nonatomic, assign) BOOL creating;
@property (nonatomic, copy) void (^onSaved)(void);
@end

/** 运行日志查看器。 */
@interface MCLogViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@end

#endif /* MC_PREFS_CLASSES_H */
