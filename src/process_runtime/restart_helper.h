#ifndef VHTTPD_RESTART_HELPER_H
#define VHTTPD_RESTART_HELPER_H
#include <unistd.h>
#include <fcntl.h>
#include <sys/resource.h>
#include <sys/stat.h>
/* The exec'd helper must not retain the old listener sockets or terminal. */
static int vhttpd_restart_detach(const char *logpath) {
    if (setsid() < 0) return -1;
    struct rlimit lim;
    if (getrlimit(RLIMIT_NOFILE, &lim) != 0) return -1;
    for (int fd = 3; fd < (int)(lim.rlim_cur > 1048576 ? 1048576 : lim.rlim_cur); fd++) close(fd);
    int in = open("/dev/null", O_RDONLY);
    int out = open(logpath, O_WRONLY|O_CREAT|O_APPEND|O_NOFOLLOW, 0600);
    if (in < 0 || out < 0) return -1;
    if (dup2(in,0)<0 || dup2(out,1)<0 || dup2(out,2)<0) return -1;
    if (in>2) close(in);
    if (out>2) close(out);
    return 0;
}
#endif
