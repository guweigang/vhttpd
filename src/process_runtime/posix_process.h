#ifndef VHTTPD_POSIX_PROCESS_H
#define VHTTPD_POSIX_PROCESS_H
#include <sys/wait.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <string.h>
#include <poll.h>

/* Observe child exit without reaping: the PID cannot be recycled before cleanup. */
static int vhttpd_child_state(int pid) {
    siginfo_t info;
    memset(&info, 0, sizeof(info));
    int result;
    do { result = waitid(P_PID, (id_t)pid, &info, WEXITED | WNOHANG | WNOWAIT); }
    while (result < 0 && errno == EINTR);
    if (result < 0) return -1;
    return info.si_pid == 0 ? 1 : 0;
}
/* The registry keeps the child unreaped while checking its process group.
 * Peer credentials identify the listener generation, not just its pathname. */
static int vhttpd_child_owns_socket(int child_pid, int fd) {
    pid_t peer_pid = -1;
#if defined(__APPLE__)
    socklen_t size = sizeof(peer_pid);
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer_pid, &size) != 0 ||
        size != sizeof(peer_pid)) return 0;
#elif defined(__linux__)
    struct ucred credentials;
    socklen_t size = sizeof(credentials);
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &size) != 0 ||
        size != sizeof(credentials)) return 0;
    peer_pid = credentials.pid;
#else
    return 0;
#endif
    return peer_pid > 0 && getpgid(peer_pid) == (pid_t)child_pid;
}
typedef struct vhttpd_signal_pipe { int read_fd; int write_fd; } vhttpd_signal_pipe;
static vhttpd_signal_pipe vhttpd_signal_pipe_create(void) {
    int fds[2];
    vhttpd_signal_pipe failed = { -1, -1 };
    if (pipe(fds) < 0) return failed;
    if (fcntl(fds[0], F_SETFD, FD_CLOEXEC) < 0 ||
        fcntl(fds[1], F_SETFD, FD_CLOEXEC) < 0 ||
        fcntl(fds[1], F_SETFL, O_NONBLOCK) < 0) {
        int saved = errno;
        close(fds[0]); close(fds[1]); errno = saved;
        return failed;
    }
    vhttpd_signal_pipe result = { fds[0], fds[1] };
    return result;
}
static int vhttpd_signal_pipe_ready(int fd, int timeout_ms) {
    struct pollfd item = { fd, POLLIN, 0 };
    return poll(&item, 1, timeout_ms) > 0 && (item.revents & POLLIN) ? 1 : 0;
}
/* Only async-signal-safe operations; queued termination signals may coalesce. */
static void vhttpd_signal_pipe_notify(int fd, int sig) {
    int saved = errno;
    (void)write(fd, &sig, sizeof(sig));
    errno = saved;
}
/* Published only once after successful installation; never retired while signal
 * callbacks can run. sig_atomic_t permits access from the native signal path. */
static volatile sig_atomic_t vhttpd_shutdown_write_fd = -1;
static void vhttpd_shutdown_signal_publish(int fd) { vhttpd_shutdown_write_fd = fd; }
static int vhttpd_shutdown_signal_fd(void) { return (int)vhttpd_shutdown_write_fd; }
static void vhttpd_shutdown_signal_notify(int sig) {
    vhttpd_signal_pipe_notify((int)vhttpd_shutdown_write_fd, sig);
}
static int vhttpd_signal_pipe_wait(int fd) {
    int sig = 0;
    size_t received = 0;
    while (received < sizeof(sig)) {
        ssize_t count = read(fd, (char *)&sig + received, sizeof(sig) - received);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return -1;
        received += (size_t)count;
    }
    return sig;
}
#endif
