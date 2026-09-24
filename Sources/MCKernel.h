#ifndef MC_KERNEL_H
#define MC_KERNEL_H

#include <sys/types.h>
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <errno.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The iOS SDK omits the memorystatus_control declarations used by the daemon. */
#ifndef MEMORYSTATUS_CMD_GET_PRIORITY_LIST
#define MEMORYSTATUS_CMD_GET_PRIORITY_LIST 1
#endif
#ifndef MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES
#define MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES 2
#endif
#ifndef MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES
#define MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES 7
#endif
#ifndef MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES
#define MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES 8
#endif
#ifndef MEMORYSTATUS_CMD_ELEVATED_INACTIVEJETSAMPRIORITY_ENABLE
#define MEMORYSTATUS_CMD_ELEVATED_INACTIVEJETSAMPRIORITY_ENABLE 14
#endif
#ifndef MEMORYSTATUS_CMD_ELEVATED_INACTIVEJETSAMPRIORITY_DISABLE
#define MEMORYSTATUS_CMD_ELEVATED_INACTIVEJETSAMPRIORITY_DISABLE 15
#endif
#ifndef MEMORYSTATUS_CMD_SET_PROCESS_IS_FREEZABLE
#define MEMORYSTATUS_CMD_SET_PROCESS_IS_FREEZABLE 18
#endif
#ifndef MEMORYSTATUS_MEMLIMIT_ATTR_FATAL
#define MEMORYSTATUS_MEMLIMIT_ATTR_FATAL 0x1
#endif
#ifndef JETSAM_PRIORITY_MAX
#define JETSAM_PRIORITY_MAX 210
#endif
#ifndef MC_MEMLIMIT_DEFAULT
#define MC_MEMLIMIT_DEFAULT (-1)
#endif

typedef struct {
    int32_t pid;
    int32_t priority;
    uint64_t user_data;
    int32_t limit;
    uint32_t state;
} memorystatus_priority_entry_t;

typedef struct {
    int32_t priority;
    uint64_t user_data;
} memorystatus_priority_properties_t;

typedef struct {
    int32_t memlimit_active;
    uint32_t memlimit_active_attr;
    int32_t memlimit_inactive;
    uint32_t memlimit_inactive_attr;
} memorystatus_memlimit_properties_t;

int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags,
                         void *buffer, size_t buffersize);

/* Configs retain the 0..210 scale. iOS 15 (XNU 8020) uses 0..21;
 * iOS 16 (XNU 8792) expanded the corresponding bands by ten.
 * -2 means invalid config, never pass it to the kernel (IDLE_HEAD there). */
static inline int32_t MCNativeJetsamPriority(int64_t configured, int osMajor) {
    if (configured < -1 || configured > 210) return -2;
    if (configured <= 0 || osMajor >= 16) return (int32_t)configured;
    if (configured % 10 != 0) return -2;
    return (int32_t)(configured / 10);
}

/* GET_PRIORITY_LIST returns bytes copied, unlike SET commands (zero on success).
 * Apple XNU xnu-8792.61.2: memorystatus_cmd_get_priority_list. */
static inline bool MCGetKernelPriority(pid_t pid, int32_t *priority) {
    memorystatus_priority_entry_t entry = {0};
    errno = 0;
    int result = memorystatus_control(MEMORYSTATUS_CMD_GET_PRIORITY_LIST, pid, 0,
                                     &entry, sizeof(entry));
    if (result < 0) return false;
    if (result != (int)sizeof(entry) || entry.pid != pid) {
        errno = EIO;
        return false;
    }
    if (priority) *priority = entry.priority;
    return true;
}

#ifdef __cplusplus
}
#endif
#endif
