/**
 * MCKernel.h — XNU 私有接口常量声明
 *
 * 所有数值均对照 XNU 源码核对（bsd/sys/kern_memorystatus.h、bsd/sys/proc_info.h、
 * bsd/sys/resource.h、bsd/sys/resource_private.h、osfmk/mach/task_policy.h）。
 * iOS SDK 的公开头文件不导出这些符号，因此在此集中声明。
 */
#ifndef MC_KERNEL_H
#define MC_KERNEL_H

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <sys/types.h>

__BEGIN_DECLS

/* ==========================================================================
 * 1. memorystatus_control —— Jetsam / 内存限制总入口
 *    int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags,
 *                             void *buffer, size_t buffersize);
 * ========================================================================== */

/* MEMORYSTATUS_CMD_GET_PRIORITY_LIST
 * 读取内核当前的 jetsam 优先级链表，用于回读"真实生效"的优先级。 */
#ifndef MEMORYSTATUS_CMD_GET_PRIORITY_LIST
#define MEMORYSTATUS_CMD_GET_PRIORITY_LIST            1
#endif

/* MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES
 * 设置进程 jetsam 优先级。buffer = memorystatus_priority_properties_t，buffersize = 16。 */
#ifndef MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES
#define MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES      2
#endif

/* 5/6 都写入 active==inactive 的限额，区别在是否 fatal。flags 位置传 MB 数值。 */
#ifndef MEMORYSTATUS_CMD_SET_JETSAM_HIGH_WATER_MARK
#define MEMORYSTATUS_CMD_SET_JETSAM_HIGH_WATER_MARK   5   /* 超限不立即杀 */
#endif
#ifndef MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT
#define MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT        6   /* 超限立即杀 */
#endif

/* 7/8：分别写入/回读 active、inactive 限额及属性。buffer 16 字节。 */
#ifndef MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES
#define MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES      7
#endif
#ifndef MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES
#define MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES      8
#endif

/* 14/15：把 inactive 时的 jetsam band 提升到 ELEVATED_INACTIVE（更难被杀）。 */
#ifndef MEMORYSTATUS_CMD_ELEVATED_INACTIVEJETSAMPRIORITY_ENABLE
#define MEMORYSTATUS_CMD_ELEVATED_INACTIVEJETSAMPRIORITY_ENABLE  14
#endif
#ifndef MEMORYSTATUS_CMD_ELEVATED_INACTIVEJETSAMPRIORITY_DISABLE
#define MEMORYSTATUS_CMD_ELEVATED_INACTIVEJETSAMPRIORITY_DISABLE 15
#endif

/* 16/17：进程是否"由系统实体托管"（assertiond / runningboard）。
 *        托管进程的配置会被系统随时还原，因此需要剥离。 */
#ifndef MEMORYSTATUS_CMD_SET_PROCESS_IS_MANAGED
#define MEMORYSTATUS_CMD_SET_PROCESS_IS_MANAGED       16
#endif
#ifndef MEMORYSTATUS_CMD_GET_PROCESS_IS_MANAGED
#define MEMORYSTATUS_CMD_GET_PROCESS_IS_MANAGED       17
#endif

/* 18/19：是否允许被冻结。 */
#ifndef MEMORYSTATUS_CMD_SET_PROCESS_IS_FREEZABLE
#define MEMORYSTATUS_CMD_SET_PROCESS_IS_FREEZABLE     18
#endif
#ifndef MEMORYSTATUS_CMD_GET_PROCESS_IS_FREEZABLE
#define MEMORYSTATUS_CMD_GET_PROCESS_IS_FREEZABLE     19
#endif

/* 25/26：coalition 脏内存能否换出到磁盘。单向转换，且只有 coalition leader 可设。 */
#ifndef MEMORYSTATUS_CMD_MARK_PROCESS_COALITION_SWAPPABLE
#define MEMORYSTATUS_CMD_MARK_PROCESS_COALITION_SWAPPABLE      25
#endif
#ifndef MEMORYSTATUS_CMD_GET_PROCESS_COALITION_IS_SWAPPABLE
#define MEMORYSTATUS_CMD_GET_PROCESS_COALITION_IS_SWAPPABLE    26
#endif

/* 28：把可能是 0 / -1 的 memlimit 表达值换算成实际 MB 数值。 */
#ifndef MEMORYSTATUS_CMD_CONVERT_MEMLIMIT_MB
#define MEMORYSTATUS_CMD_CONVERT_MEMLIMIT_MB                 28
#endif

#ifndef MEMORYSTATUS_FLAGS_GRP_SET_PRIORITY
#define MEMORYSTATUS_FLAGS_GRP_SET_PRIORITY             0x8
#endif
#ifndef MEMORYSTATUS_SET_PRIORITY_ASSERTION
#define MEMORYSTATUS_SET_PRIORITY_ASSERTION             0x1
#endif
#ifndef MEMORYSTATUS_MEMLIMIT_ATTR_FATAL
#define MEMORYSTATUS_MEMLIMIT_ATTR_FATAL                0x1
#endif

/* jetsam band 上界；把守护进程钉在这里可确保它永远排在回收队列最后。 */
#ifndef JETSAM_PRIORITY_MAX
#define JETSAM_PRIORITY_MAX                             210
#endif

/*
 * 限额语义（kern_memorystatus.c memorystatus_set_memlimit_internal）：
 * 写入 <=0 的值内核会替换成设备默认限额，因此「恢复默认」就是写 -1。
 */
#ifndef MC_MEMLIMIT_DEFAULT
#define MC_MEMLIMIT_DEFAULT                             (-1)
#endif

typedef uint32_t memorystatus_proc_state_t;

/* GET_PRIORITY_LIST 的回填单元。pid != 0 时内核只写一条。 */
typedef struct {
    pid_t    pid;
    int32_t  priority;
    uint64_t user_data;
    int32_t  limit;                       /* MB */
    memorystatus_proc_state_t state;
} memorystatus_priority_entry_t;

typedef struct {
    int32_t  priority;
    uint64_t user_data;
} memorystatus_priority_properties_t;   /* 含尾部填充，实测 16 字节 */

typedef struct {
    int32_t  memlimit_active;           /* 前台限额（MB） */
    uint32_t memlimit_active_attr;
    int32_t  memlimit_inactive;         /* 后台限额（MB） */
    uint32_t memlimit_inactive_attr;
} memorystatus_memlimit_properties_t;   /* 16 字节 */

int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags,
                         void *buffer, size_t buffersize);

/* ==========================================================================
 * 2. proc_track_dirty —— 脏数据标记 / Idle Exit
 * ========================================================================== */
#ifndef PROC_DIRTY_TRACK
#define PROC_DIRTY_TRACK                0x1
#endif
#ifndef PROC_DIRTY_ALLOW_IDLE_EXIT
#define PROC_DIRTY_ALLOW_IDLE_EXIT      0x2   /* 置位表示"允许"空闲退出 */
#endif
#ifndef PROC_DIRTY_DEFER
#define PROC_DIRTY_DEFER                0x4
#endif
#ifndef PROC_DIRTY_LAUNCH_IN_PROGRESS
#define PROC_DIRTY_LAUNCH_IN_PROGRESS   0x8
#endif
#ifndef PROC_DIRTY_DEFER_ALWAYS
#define PROC_DIRTY_DEFER_ALWAYS         0x10
#endif

#ifndef PROC_DIRTY_TRACKED
#define PROC_DIRTY_TRACKED              0x1
#endif
#ifndef PROC_DIRTY_ALLOWS_IDLE_EXIT
#define PROC_DIRTY_ALLOWS_IDLE_EXIT     0x2
#endif
#ifndef PROC_DIRTY_IS_DIRTY
#define PROC_DIRTY_IS_DIRTY             0x4
#endif

int proc_track_dirty(pid_t pid, uint32_t flags);
int proc_dirty_details(pid_t pid, int *dirtystatus);

/* ==========================================================================
 * 3. proc_rlimit_control —— EXC_RESOURCE 监控开关
 *    int proc_rlimit_control(pid_t pid, int flavor, void *arg);
 * ========================================================================== */
#ifndef RLIMIT_WAKEUPS_MONITOR
#define RLIMIT_WAKEUPS_MONITOR          0x1
#endif
#ifndef RLIMIT_CPU_USAGE_MONITOR
#define RLIMIT_CPU_USAGE_MONITOR        0x2
#endif
#ifndef RLIMIT_THREAD_CPULIMITS
#define RLIMIT_THREAD_CPULIMITS         0x3
#endif
#ifndef RLIMIT_FOOTPRINT_INTERVAL
#define RLIMIT_FOOTPRINT_INTERVAL       0x4
#endif

#ifndef WAKEMON_ENABLE
#define WAKEMON_ENABLE                  0x01
#endif
#ifndef WAKEMON_DISABLE
#define WAKEMON_DISABLE                 0x02
#endif
#ifndef WAKEMON_GET_PARAMS
#define WAKEMON_GET_PARAMS              0x04
#endif
#ifndef WAKEMON_SET_DEFAULTS
#define WAKEMON_SET_DEFAULTS            0x08
#endif
#ifndef WAKEMON_MAKE_FATAL
#define WAKEMON_MAKE_FATAL              0x10
#endif
#ifndef CPUMON_MAKE_FATAL
#define CPUMON_MAKE_FATAL               0x1000
#endif

struct mc_rlimit_control_wakeupmon {
    uint32_t wm_flags;
    int32_t  wm_rate;
};

int proc_rlimit_control(pid_t pid, int flavor, void *arg);

/* ==========================================================================
 * 4. I/O 策略与 Darwin 优先级
 * ========================================================================== */
#ifndef IOPOL_TYPE_DISK
#define IOPOL_TYPE_DISK                 0
#endif
#ifndef IOPOL_SCOPE_PROCESS
#define IOPOL_SCOPE_PROCESS             0
#endif
#ifndef IOPOL_SCOPE_THREAD
#define IOPOL_SCOPE_THREAD              1
#endif
#ifndef IOPOL_SCOPE_DARWIN_BG
#define IOPOL_SCOPE_DARWIN_BG           2
#endif

#ifndef IOPOL_DEFAULT
#define IOPOL_DEFAULT                   0
#endif
#ifndef IOPOL_IMPORTANT
#define IOPOL_IMPORTANT                 1
#endif
#ifndef IOPOL_PASSIVE
#define IOPOL_PASSIVE                   2
#endif
#ifndef IOPOL_THROTTLE
#define IOPOL_THROTTLE                  3
#endif
#ifndef IOPOL_UTILITY
#define IOPOL_UTILITY                   4
#endif
#ifndef IOPOL_STANDARD
#define IOPOL_STANDARD                  5
#endif

int setiopolicy_np(int iotype, int scope, int policy);

#ifndef PRIO_PROCESS
#define PRIO_PROCESS                    0
#endif
#ifndef PRIO_DARWIN_PROCESS
#define PRIO_DARWIN_PROCESS             4
#endif
#ifndef PRIO_DARWIN_GPU
#define PRIO_DARWIN_GPU                 5
#endif
#ifndef PRIO_DARWIN_ROLE
#define PRIO_DARWIN_ROLE                6
#endif

#ifndef PRIO_DARWIN_BG
#define PRIO_DARWIN_BG                  0x1000
#endif
#ifndef PRIO_DARWIN_NONUI
#define PRIO_DARWIN_NONUI               0x1001
#endif

#ifndef PRIO_DARWIN_GPU_ALLOW
#define PRIO_DARWIN_GPU_ALLOW           0x1
#endif
#ifndef PRIO_DARWIN_GPU_DENY
#define PRIO_DARWIN_GPU_DENY            0x2
#endif
#ifndef PRIO_DARWIN_GPU_BACKGROUND
#define PRIO_DARWIN_GPU_BACKGROUND      0x3
#endif

#ifndef PRIO_DARWIN_ROLE_UI_FOCAL
#define PRIO_DARWIN_ROLE_UI_FOCAL       0x1
#endif

#ifndef PRIO_MIN
#define PRIO_MIN                        -20
#endif
#ifndef PRIO_MAX
#define PRIO_MAX                        20
#endif

/* ==========================================================================
 * 5. Mach task policy
 * ========================================================================== */
/*
 * SDK 的 <mach/task_policy.h> 在不同 iOS SDK 版本里导出情况不一致，
 * 逐个 #ifndef 兜住：有系统定义时沿用系统值，没有时用这里的同值常量。
 * 一律 cast 成 integer_t，不依赖 task_policy_flavor_t 是否对 SDK 用户可见。
 */
#ifndef TASK_CATEGORY_POLICY
#define TASK_CATEGORY_POLICY                        ((integer_t)1)
#endif
#ifndef TASK_SUPPRESSION_POLICY
#define TASK_SUPPRESSION_POLICY                     ((integer_t)3)
#endif
#ifndef TASK_BASE_QOS_POLICY
#define TASK_BASE_QOS_POLICY                        ((integer_t)8)
#endif
#ifndef TASK_OVERRIDE_QOS_POLICY
#define TASK_OVERRIDE_QOS_POLICY                    ((integer_t)9)
#endif
#ifndef TASK_BASE_LATENCY_QOS_POLICY
#define TASK_BASE_LATENCY_QOS_POLICY                ((integer_t)10)
#endif
#ifndef TASK_BASE_THROUGHPUT_QOS_POLICY
#define TASK_BASE_THROUGHPUT_QOS_POLICY             ((integer_t)11)
#endif

/* task_role 取值用 #define 而不是 enum：SDK 的 enum task_role 已声明同名标识符，
 * 两个 enum 里重复的 enumerator 在 C 里构成重定义。tier 编号越小越优先。 */
#ifndef TASK_FOREGROUND_APPLICATION
#define TASK_FOREGROUND_APPLICATION     1
#endif

#ifndef MC_LATENCY_QOS_TIER_0
#define MC_LATENCY_QOS_TIER_0      ((0xFF << 16) | 1)   /* 0x00FF0001 最高 */
#endif
#ifndef MC_THROUGHPUT_QOS_TIER_0
#define MC_THROUGHPUT_QOS_TIER_0   ((0xFE << 16) | 1)   /* 0x00FE0001 最高 */
#endif

typedef struct {
    integer_t task_latency_qos_tier;
    integer_t task_throughput_qos_tier;
} mc_task_qos_policy_t;
#ifndef MC_TASK_QOS_POLICY_COUNT
#define MC_TASK_QOS_POLICY_COUNT  2
#endif
#ifndef MC_TASK_CATEGORY_POLICY_COUNT
#define MC_TASK_CATEGORY_POLICY_COUNT 1
#endif
#ifndef MC_TASK_SUPPRESSION_POLICY_COUNT
#define MC_TASK_SUPPRESSION_POLICY_COUNT 1
#endif

/* task_suppression_policy { integer_t suppression_status; } —— 0 表示禁用 App Nap */
typedef struct {
    integer_t suppression_status;
} mc_task_suppression_policy_t;

__END_DECLS

#endif /* MC_KERNEL_H */
