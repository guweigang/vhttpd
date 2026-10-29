#ifndef VHTTPD_WORKBENCH_WINDOW_WINDOWS_H
#define VHTTPD_WORKBENCH_WINDOW_WINDOWS_H
#include <windows.h>
#include <commctrl.h>

static void vhttpd_workbench_prepare_windows_display(void) {
    // Use one system-DPI coordinate space throughout the native ui2 tree.
    SetProcessDPIAware();
}
static double vhttpd_workbench_windows_scale(void) {
    HDC dc = GetDC(NULL);
    if (!dc) return 1.0;
    double scale = GetDeviceCaps(dc, LOGPIXELSX) / 96.0;
    ReleaseDC(NULL, dc);
    return scale > 0 ? scale : 1.0;
}

static LRESULT CALLBACK vhttpd_workbench_size_proc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam, UINT_PTR id, DWORD_PTR data) {
    if (message == WM_GETMINMAXINFO) {
        double scale = vhttpd_workbench_windows_scale();
        RECT frame = {0,0,(LONG)(760*scale),(LONG)(660*scale)};
        AdjustWindowRectEx(&frame,(DWORD)GetWindowLongPtrW(hwnd,GWL_STYLE),GetMenu(hwnd)!=NULL,(DWORD)GetWindowLongPtrW(hwnd,GWL_EXSTYLE));
        MINMAXINFO *info = (MINMAXINFO*)lparam;
        info->ptMinTrackSize.x = frame.right-frame.left;
        info->ptMinTrackSize.y = frame.bottom-frame.top;
        return 0;
    }
    return DefSubclassProc(hwnd,message,wparam,lparam);
}
static void vhttpd_workbench_configure_windows(void *window) {
    if (!window) return;
    SetWindowSubclass((HWND)window,vhttpd_workbench_size_proc,73,0);
    HINSTANCE module = GetModuleHandleW(NULL);
    HICON large = (HICON)LoadImageW(module,MAKEINTRESOURCEW(1),IMAGE_ICON,GetSystemMetrics(SM_CXICON),GetSystemMetrics(SM_CYICON),LR_SHARED);
    HICON small = (HICON)LoadImageW(module,MAKEINTRESOURCEW(1),IMAGE_ICON,GetSystemMetrics(SM_CXSMICON),GetSystemMetrics(SM_CYSMICON),LR_SHARED);
    if(large) SendMessageW((HWND)window,WM_SETICON,ICON_BIG,(LPARAM)large);
    if(small) SendMessageW((HWND)window,WM_SETICON,ICON_SMALL,(LPARAM)small);
}

static void vhttpd_workbench_activate_windows(void *native_window) {
    HWND window = (HWND)native_window;
    if (!window || !IsWindow(window)) return;
    if (IsIconic(window)) ShowWindow(window, SW_RESTORE);
    SetForegroundWindow(window);
}
#endif
