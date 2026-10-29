#ifndef VHTTPD_WORKBENCH_WINDOW_WINDOWS_H
#define VHTTPD_WORKBENCH_WINDOW_WINDOWS_H
#include <windows.h>

static void vhttpd_workbench_activate_windows(void *native_window) {
    HWND window = (HWND)native_window;
    if (!window || !IsWindow(window)) return;
    if (IsIconic(window)) ShowWindow(window, SW_RESTORE);
    SetForegroundWindow(window);
}
#endif
