#ifndef VHTTPD_SOCKET_WINDOWS_H
#define VHTTPD_SOCKET_WINDOWS_H
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <windows.h>
#include <limits.h>
#include <stdint.h>

static SOCKET vhttpd_native_socket(int fd) { return (SOCKET)(uintptr_t)(unsigned int)fd; }
static int vhttpd_socket_protect(int fd) {
    return SetHandleInformation((HANDLE)vhttpd_native_socket(fd), HANDLE_FLAG_INHERIT, 0) != 0;
}
/* Shared state/independent descriptor lifetime follow WSADuplicateSocketW:
 * https://learn.microsoft.com/windows/win32/api/winsock2/nf-winsock2-wsaduplicatesocketw */
static int vhttpd_socket_duplicate(int fd) {
    WSAPROTOCOL_INFOW info;
    SOCKET alias;
    if (WSADuplicateSocketW(vhttpd_native_socket(fd), GetCurrentProcessId(), &info) != 0) return -1;
    alias = WSASocketW(FROM_PROTOCOL_INFO, FROM_PROTOCOL_INFO, FROM_PROTOCOL_INFO, &info,
                      0, WSA_FLAG_OVERLAPPED | WSA_FLAG_NO_HANDLE_INHERIT);
    if (alias == INVALID_SOCKET) return -1;
    /* V's net.Socket uses int. Never silently truncate an out-of-range handle. */
    if ((uintptr_t)alias > INT_MAX) { closesocket(alias); WSASetLastError(WSAEMFILE); return -1; }
    return (int)alias;
}
static int vhttpd_socket_wait_writable(int fd, int milliseconds) {
    SOCKET socket = vhttpd_native_socket(fd);
    fd_set write_set, error_set;
    struct timeval wait;
    FD_ZERO(&write_set); FD_ZERO(&error_set);
    FD_SET(socket, &write_set); FD_SET(socket, &error_set);
    wait.tv_sec = milliseconds / 1000; wait.tv_usec = (milliseconds % 1000) * 1000;
    int result = select(0, NULL, &write_set, &error_set, &wait);
    if (result == SOCKET_ERROR && WSAGetLastError() == WSAEINTR) return 0;
    return result;
}
static int vhttpd_socket_connect_error(int fd, int *code) {
    int length = sizeof(*code);
    return getsockopt(vhttpd_native_socket(fd), SOL_SOCKET, SO_ERROR, (char *)code, &length);
}
#endif
