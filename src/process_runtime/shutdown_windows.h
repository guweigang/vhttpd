#ifndef VHTTPD_SHUTDOWN_WINDOWS_H
#define VHTTPD_SHUTDOWN_WINDOWS_H
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <stdio.h>
/* Console close callbacks must wait before returning; see
 * https://learn.microsoft.com/windows/console/handlerroutine
 * Native callbacks only notify; application cleanup runs on a V-owned thread. */
static HANDLE vhttpd_console_event;
static HANDLE vhttpd_console_finished;
static volatile LONG vhttpd_console_signal;
static volatile LONG vhttpd_console_installed;
static BOOL WINAPI vhttpd_console_control(DWORD kind) {
    LONG signal;
    switch (kind) {
        case CTRL_C_EVENT: signal = 2; break;
        case CTRL_BREAK_EVENT:
        case CTRL_CLOSE_EVENT:
        case CTRL_LOGOFF_EVENT:
        case CTRL_SHUTDOWN_EVENT: signal = 15; break;
        default: return FALSE;
    }
    if (InterlockedCompareExchange(&vhttpd_console_signal, signal, 0) == 0)
        SetEvent(vhttpd_console_event);
    /* Windows terminates a closing console when this callback returns.
       Give the cleanup worker time within the OS's close-event deadline. */
    if (kind != CTRL_C_EVENT && kind != CTRL_BREAK_EVENT)
        WaitForSingleObject(vhttpd_console_finished, 4000);
    return TRUE;
}
static int vhttpd_shutdown_console_install(void) {
    if (InterlockedCompareExchange(&vhttpd_console_installed, 1, 0) != 0) return 0;
    wchar_t name[96];
    swprintf_s(name, 96, L"Local\\vhttpd.shutdown.%lu", GetCurrentProcessId());
    /* Default token DACL, non-inheritable. Reject pre-existing objects. */
    vhttpd_console_event = CreateEventW(NULL, FALSE, FALSE, name);
    if (vhttpd_console_event && GetLastError() == ERROR_ALREADY_EXISTS) {
        CloseHandle(vhttpd_console_event); vhttpd_console_event = NULL;
        InterlockedExchange(&vhttpd_console_installed, 0); return 0;
    }
    vhttpd_console_finished = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!vhttpd_console_event || !vhttpd_console_finished ||
        !SetConsoleCtrlHandler(vhttpd_console_control, TRUE)) {
        if (vhttpd_console_event) CloseHandle(vhttpd_console_event);
        if (vhttpd_console_finished) CloseHandle(vhttpd_console_finished);
        vhttpd_console_event = vhttpd_console_finished = NULL;
        InterlockedExchange(&vhttpd_console_installed, 0);
        return 0;
    }
    /* Registered callback and waiter own both events until process exit. */
    return 1;
}
static int vhttpd_shutdown_console_wait(void) {
    if (WaitForSingleObject(vhttpd_console_event, INFINITE) != WAIT_OBJECT_0) return -1;
    LONG signal = InterlockedCompareExchange(&vhttpd_console_signal, 0, 0);
    return signal ? (int)signal : 15;
}
static void vhttpd_shutdown_console_finished(void) { SetEvent(vhttpd_console_finished); }
#endif
