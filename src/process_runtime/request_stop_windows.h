#ifndef VHTTPD_REQUEST_STOP_WINDOWS_H
#define VHTTPD_REQUEST_STOP_WINDOWS_H
#include <windows.h>
#include <stdio.h>
static int vhttpd_request_process_stop(int pid) {
    wchar_t name[96];
    HANDLE event;
    if (pid <= 0) return 0;
    swprintf_s(name, 96, L"Local\\vhttpd.shutdown.%lu", (unsigned long)pid);
    event = OpenEventW(EVENT_MODIFY_STATE, FALSE, name);
    if (!event) return 0;
    int result = SetEvent(event) != 0;
    CloseHandle(event);
    return result;
}
#endif
