#ifndef VHTTPD_UPGRADE_PROCESS_H
#define VHTTPD_UPGRADE_PROCESS_H
#include <unistd.h>
#include <sys/syscall.h>
#include <signal.h>
static int vhttpd_upgrade_pidfd_open(int pid) {
#if defined(SYS_pidfd_open)
    return (int)syscall(SYS_pidfd_open, pid, 0);
#else
    return -1;
#endif
}
static int vhttpd_upgrade_pidfd_term(int fd) {
#if defined(SYS_pidfd_send_signal)
    return (int)syscall(SYS_pidfd_send_signal, fd, SIGTERM, 0, 0);
#else
    return -1;
#endif
}
#endif
