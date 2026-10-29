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
    // All painted hit-test overlays have been replaced by native button
    // surfaces/popups. Present container backgrounds and transparent labels
    // as one composed frame rather than exposing partially painted siblings.
    LONG_PTR extended = GetWindowLongPtrW((HWND)window,GWL_EXSTYLE);
    SetWindowLongPtrW((HWND)window,GWL_EXSTYLE,extended | WS_EX_COMPOSITED);
    SetWindowSubclass((HWND)window,vhttpd_workbench_size_proc,73,0);
    MONITORINFO monitor = {sizeof(MONITORINFO)};
    RECT frame;
    if (GetMonitorInfoW(MonitorFromWindow((HWND)window,MONITOR_DEFAULTTONEAREST),&monitor) && GetWindowRect((HWND)window,&frame)) {
        int margin = (int)(8*vhttpd_workbench_windows_scale());
        int width = frame.right-frame.left, height = frame.bottom-frame.top;
        int max_width = monitor.rcWork.right-monitor.rcWork.left-2*margin;
        int max_height = monitor.rcWork.bottom-monitor.rcWork.top-2*margin;
        if(width>max_width) width=max_width;
        if(height>max_height) height=max_height;
        int x=frame.left, y=frame.top;
        if(x+width>monitor.rcWork.right-margin) x=monitor.rcWork.right-margin-width;
        if(y+height>monitor.rcWork.bottom-margin) y=monitor.rcWork.bottom-margin-height;
        if(x<monitor.rcWork.left+margin) x=monitor.rcWork.left+margin;
        if(y<monitor.rcWork.top+margin) y=monitor.rcWork.top+margin;
        SetWindowPos((HWND)window,NULL,x,y,width,height,SWP_NOACTIVATE|SWP_NOZORDER);
    }
    HINSTANCE module = GetModuleHandleW(NULL);
    HICON large = (HICON)LoadImageW(module,MAKEINTRESOURCEW(1),IMAGE_ICON,GetSystemMetrics(SM_CXICON),GetSystemMetrics(SM_CYICON),LR_SHARED);
    HICON small = (HICON)LoadImageW(module,MAKEINTRESOURCEW(1),IMAGE_ICON,GetSystemMetrics(SM_CXSMICON),GetSystemMetrics(SM_CYSMICON),LR_SHARED);
    if(large) SendMessageW((HWND)window,WM_SETICON,ICON_BIG,(LPARAM)large);
    if(small) SendMessageW((HWND)window,WM_SETICON,ICON_SMALL,(LPARAM)small);
    RedrawWindow((HWND)window,NULL,NULL,RDW_INVALIDATE | RDW_ALLCHILDREN | RDW_FRAME | RDW_UPDATENOW | RDW_ERASE);
}

// Native popups own dismissal, keyboard navigation and accessibility without
// placing an opaque HWND over the application's existing sibling controls.
static int vhttpd_workbench_choose_environment(void *window, void *label_table,
        int count, int selected, int x, int y) {
    HWND owner = (HWND)window;
    const wchar_t *const *labels = (const wchar_t *const *)label_table;
    if (!owner || !IsWindow(owner) || !labels || count <= 0) return 0;
    HMENU menu = CreatePopupMenu();
    if (!menu) return 0;
    for (int i = 0; i < count; ++i) {
        MENUITEMINFOW item = {sizeof(MENUITEMINFOW)};
        item.fMask = MIIM_STRING | MIIM_ID | MIIM_STATE | MIIM_FTYPE;
        item.fType = MFT_STRING | MFT_RADIOCHECK;
        item.fState = i == selected ? MFS_CHECKED : MFS_UNCHECKED;
        item.wID = (UINT)(i + 1);
        item.dwTypeData = (LPWSTR)labels[i];
        if (!InsertMenuItemW(menu, (UINT)i, TRUE, &item)) {
            DestroyMenu(menu);
            return 0;
        }
    }
    POINT anchor = {x,y};
    ClientToScreen(owner,&anchor);
    SetForegroundWindow(owner);
    UINT chosen = TrackPopupMenuEx(menu,TPM_RETURNCMD | TPM_NONOTIFY | TPM_LEFTALIGN | TPM_TOPALIGN,
        anchor.x,anchor.y,owner,NULL);
    DestroyMenu(menu);
    PostMessageW(owner,WM_NULL,0,0);
    return chosen <= (UINT)count ? (int)chosen : 0;
}

static void vhttpd_workbench_activate_windows(void *native_window) {
    HWND window = (HWND)native_window;
    if (!window || !IsWindow(window)) return;
    if (IsIconic(window)) ShowWindow(window, SW_RESTORE);
    SetForegroundWindow(window);
}
#endif
