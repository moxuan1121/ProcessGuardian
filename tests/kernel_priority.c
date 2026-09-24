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
