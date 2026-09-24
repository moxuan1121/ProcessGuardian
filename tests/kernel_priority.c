#include "../Sources/MCKernel.h"
#include <assert.h>
#include <stdio.h>

static int reply = 24;
static pid_t returned_pid = 123;
int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags,
                         void *buffer, size_t size) {
    assert(command == MEMORYSTATUS_CMD_GET_PRIORITY_LIST);
    assert(pid == 123 && flags == 0 && size == 24);
    memorystatus_priority_entry_t *entry = buffer;
    entry->pid = returned_pid;
    entry->priority = 160;
    errno = reply < 0 ? EPERM : 0;
    return reply;
}

int main(void) {
    const int bands[] = {0, 10, 20, 30, 40, 50, 80, 90, 100, 120, 130, 150, 160, 170, 180, 190, 210};
    for (size_t i = 0; i < sizeof(bands) / sizeof(bands[0]); i++) {
        assert(MCNativeJetsamPriority(bands[i], 15) == bands[i] / 10);
        assert(MCNativeJetsamPriority(bands[i], 16) == bands[i]);
    }
    assert(MCNativeJetsamPriority(-1, 15) == -1);
    assert(MCNativeJetsamPriority(-2, 15) == -2);
    assert(MCNativeJetsamPriority(211, 16) == -2);
    assert(MCNativeJetsamPriority(155, 15) == -2);
    assert(MCNativeJetsamPriority(INT64_MAX, 15) == -2);
    puts("Jetsam bands: iOS 15/16 mapping, sentinels and invalid inputs passed");
    int32_t priority = -999;
    assert(sizeof(memorystatus_priority_entry_t) == 24);
    assert(MCGetKernelPriority(123, &priority) && priority == 160);
    reply = -1;
    priority = -999;
    assert(!MCGetKernelPriority(123, &priority) && errno == EPERM && priority == -999);
    reply = 0;
    assert(!MCGetKernelPriority(123, &priority) && errno == EIO);
    reply = 12;
    assert(!MCGetKernelPriority(123, &priority) && errno == EIO);
    reply = 24;
    returned_pid = 456;
    assert(!MCGetKernelPriority(123, &priority) && errno == EIO);
    puts("Jetsam readback: byte-count success, syscall failure, short data and PID checks passed");
    return 0;
}
