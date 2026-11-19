#include "../../src/socket_runtime/windows.h"
#include "../../src/process_runtime/shutdown_windows.h"
#include "../../src/process_runtime/request_stop_windows.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    WSADATA data;
    struct sockaddr_in address = {0};
    int length = sizeof(address);
    DWORD flags;
    DWORD timeout = 2000;
    SOCKET listener, client, accepted;
    int alias;
    char byte;
    assert(WSAStartup(MAKEWORD(2, 2), &data) == 0);
    listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    assert(listener != INVALID_SOCKET);
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    assert(bind(listener, (struct sockaddr *)&address, sizeof(address)) == 0);
    assert(getsockname(listener, (struct sockaddr *)&address, &length) == 0);
    assert(listen(listener, 1) == 0);
    client = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    assert(client != INVALID_SOCKET && connect(client, (struct sockaddr *)&address, length) == 0);
    accepted = accept(listener, NULL, NULL);
    assert(accepted != INVALID_SOCKET && (uintptr_t)accepted <= INT_MAX);
    alias = vhttpd_socket_duplicate((int)accepted);
    assert(alias >= 0 && alias != (int)accepted);
    assert(vhttpd_socket_protect((int)accepted));
    assert(GetHandleInformation((HANDLE)accepted, &flags) && !(flags & HANDLE_FLAG_INHERIT));
    assert(GetHandleInformation((HANDLE)vhttpd_native_socket(alias), &flags) && !(flags & HANDLE_FLAG_INHERIT));
    assert(setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, (const char *)&timeout, sizeof(timeout)) == 0);
    assert(setsockopt(vhttpd_native_socket(alias), SOL_SOCKET, SO_RCVTIMEO, (const char *)&timeout, sizeof(timeout)) == 0);
    closesocket(accepted);
    assert(send(client, "x", 1, 0) == 1);
    assert(recv(vhttpd_native_socket(alias), &byte, 1, 0) == 1 && byte == 'x');
    assert(shutdown(vhttpd_native_socket(alias), SD_BOTH) == 0);
    assert(recv(client, &byte, 1, 0) == 0);
    closesocket(vhttpd_native_socket(alias)); closesocket(client); closesocket(listener);
    assert(vhttpd_socket_duplicate(-1) < 0);
    assert(vhttpd_shutdown_console_install());
    assert(!vhttpd_shutdown_console_install());
    assert(GetHandleInformation(vhttpd_console_event, &flags) && !(flags & HANDLE_FLAG_INHERIT));
    assert(vhttpd_request_process_stop((int)GetCurrentProcessId()));
    assert(vhttpd_shutdown_console_wait() == 15);
    vhttpd_shutdown_console_finished();
    WSACleanup();
    puts("PASS socket alias lifetime, no inheritance, shared shutdown and Desktop graceful stop event");
    return 0;
}
