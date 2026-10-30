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

// Match ui2's 10.5pt (=14 logical px) body font and its native DPI rounding.
static double vhttpd_workbench_field_line_height(void) {
    static double cached = 0;
    if (cached > 0) return cached;
    HDC dc = GetDC(NULL);
    if (!dc) return 18;
    int dpi = GetDeviceCaps(dc, LOGPIXELSY);
    HFONT font = CreateFontW(-MulDiv(105,dpi,720),0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,
        DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,
        DEFAULT_PITCH | FF_DONTCARE,L"Microsoft YaHei UI");
    HGDIOBJ previous = font ? SelectObject(dc,font) : NULL;
    TEXTMETRICW metrics;
    cached = GetTextMetricsW(dc,&metrics) ? (metrics.tmHeight + 2) * 96.0 / dpi : 18;
    if (previous) SelectObject(dc,previous);
    if (font) DeleteObject(font);
    ReleaseDC(NULL,dc);
    return cached;
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

// Keep Win32's popup lifetime, keyboard navigation, accessibility strings and
// monitor placement, but draw only this menu's rows with workbench typography.
// No full-window transparent child is mounted over the ui2 sibling controls.
typedef struct {
    HFONT font;
    double scale;
    UINT width;
} VhttpdEnvironmentMenu;

static LRESULT CALLBACK vhttpd_workbench_environment_proc(HWND hwnd, UINT message,
        WPARAM wparam, LPARAM lparam, UINT_PTR id, DWORD_PTR data) {
    VhttpdEnvironmentMenu *style = (VhttpdEnvironmentMenu *)data;
    if (message == WM_MEASUREITEM) {
        MEASUREITEMSTRUCT *item = (MEASUREITEMSTRUCT *)lparam;
        if (item && item->CtlType == ODT_MENU && item->itemData) {
            item->itemWidth = style->width;
            item->itemHeight = (UINT)(38 * style->scale);
            return TRUE;
        }
    }
    if (message == WM_DRAWITEM) {
        DRAWITEMSTRUCT *item = (DRAWITEMSTRUCT *)lparam;
        if (item && item->CtlType == ODT_MENU && item->itemData) {
            int saved = SaveDC(item->hDC);
            double scale = style->scale;
            BOOL high_contrast = FALSE;
            HIGHCONTRASTW contrast = {sizeof(HIGHCONTRASTW)};
            if (SystemParametersInfoW(SPI_GETHIGHCONTRAST, sizeof(contrast), &contrast, 0))
                high_contrast = (contrast.dwFlags & HCF_HIGHCONTRASTON) != 0;
            BOOL hover = (item->itemState & ODS_SELECTED) != 0;
            BOOL checked = (item->itemState & ODS_CHECKED) != 0;
            COLORREF background = high_contrast ? GetSysColor(COLOR_MENU) : RGB(255,255,255);
            COLORREF foreground = high_contrast ? GetSysColor(COLOR_MENUTEXT) : RGB(23,32,42);
            COLORREF accent = high_contrast ? GetSysColor(COLOR_HIGHLIGHTTEXT) : RGB(37,99,235);
            HBRUSH paper = CreateSolidBrush(background);
            FillRect(item->hDC, &item->rcItem, paper);
            DeleteObject(paper);
            RECT row = item->rcItem;
            InflateRect(&row, -(int)(4*scale), -(int)(2*scale));
            if (hover || checked) {
                COLORREF fill = high_contrast ? GetSysColor(COLOR_HIGHLIGHT) :
                    (hover ? RGB(224,234,255) : RGB(235,241,255));
                HBRUSH brush = CreateSolidBrush(fill);
                HGDIOBJ previous_brush = SelectObject(item->hDC, brush);
                HGDIOBJ previous_pen = SelectObject(item->hDC, GetStockObject(NULL_PEN));
                RoundRect(item->hDC,row.left,row.top,row.right,row.bottom,(int)(10*scale),(int)(10*scale));
                SelectObject(item->hDC,previous_pen);
                SelectObject(item->hDC,previous_brush);
                DeleteObject(brush);
                if (high_contrast) foreground = GetSysColor(COLOR_HIGHLIGHTTEXT);
            }
            SetBkMode(item->hDC,TRANSPARENT);
            SetTextColor(item->hDC,checked ? accent : foreground);
            SelectObject(item->hDC,style->font);
            RECT text = row;
            text.left += (int)(12*scale);
            text.right -= (int)(32*scale);
            DrawTextW(item->hDC,(const wchar_t *)item->itemData,-1,&text,
                DT_LEFT | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS | DT_HIDEPREFIX);
            if (checked) {
                int cx = row.right-(int)(17*scale);
                int cy = (row.top+row.bottom)/2;
                HPEN pen = CreatePen(PS_SOLID,(int)(2*scale),accent);
                HGDIOBJ previous = SelectObject(item->hDC,pen);
                MoveToEx(item->hDC,cx-(int)(5*scale),cy,NULL);
                LineTo(item->hDC,cx-(int)(1*scale),cy+(int)(4*scale));
                LineTo(item->hDC,cx+(int)(6*scale),cy-(int)(4*scale));
                SelectObject(item->hDC,previous);
                DeleteObject(pen);
            }
            RestoreDC(item->hDC,saved);
            return TRUE;
        }
    }
    return DefSubclassProc(hwnd,message,wparam,lparam);
}

static int vhttpd_workbench_choose_environment(void *window, void *label_table,
        int count, int selected, int x, int y) {
    HWND owner = (HWND)window;
    const wchar_t *const *labels = (const wchar_t *const *)label_table;
    if (!owner || !IsWindow(owner) || !labels || count <= 0) return 0;
    HMENU menu = CreatePopupMenu();
    if (!menu) return 0;
    VhttpdEnvironmentMenu style = {0};
    style.scale = vhttpd_workbench_windows_scale();
    style.font = CreateFontW(-(int)(14*style.scale),0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,
        DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,
        DEFAULT_PITCH,L"Microsoft YaHei UI");
    style.width = (UINT)(220*style.scale);
    HDC dc = GetDC(owner);
    if (dc) {
        HGDIOBJ previous = SelectObject(dc,style.font);
        for (int i=0;i<count;++i) {
            RECT extent = {0};
            DrawTextW(dc,labels[i],-1,&extent,DT_CALCRECT | DT_SINGLELINE | DT_HIDEPREFIX);
            UINT width = (UINT)(extent.right-extent.left+56*style.scale);
            if (width > style.width) style.width = width;
        }
        SelectObject(dc,previous);
        ReleaseDC(owner,dc);
    }
    MONITORINFO monitor = {sizeof(MONITORINFO)};
    if (GetMonitorInfoW(MonitorFromWindow(owner,MONITOR_DEFAULTTONEAREST),&monitor)) {
        UINT maximum = (UINT)((monitor.rcWork.right-monitor.rcWork.left)*0.75);
        if (style.width > maximum) style.width = maximum;
    }
    if (!SetWindowSubclass(owner,vhttpd_workbench_environment_proc,74,(DWORD_PTR)&style)) {
        if (style.font) DeleteObject(style.font);
        DestroyMenu(menu);
        return 0;
    }
    BOOL valid = TRUE;
    for (int i = 0; i < count; ++i) {
        MENUITEMINFOW item = {sizeof(MENUITEMINFOW)};
        // Keep the actual title as well as owner-draw data: screen readers and
        // native menu inspection must still expose the environment's name.
        item.fMask = MIIM_STRING | MIIM_ID | MIIM_STATE | MIIM_FTYPE | MIIM_DATA;
        item.fType = MFT_OWNERDRAW;
        item.fState = i == selected ? MFS_CHECKED : MFS_UNCHECKED;
        item.wID = (UINT)(i + 1);
        item.dwTypeData = (LPWSTR)labels[i];
        item.dwItemData = (ULONG_PTR)labels[i];
        if (!InsertMenuItemW(menu, (UINT)i, TRUE, &item)) { valid = FALSE; break; }
    }
    MENUINFO info = {sizeof(MENUINFO)};
    info.fMask = MIM_BACKGROUND | MIM_STYLE;
    info.hbrBack = (HBRUSH)GetStockObject(WHITE_BRUSH);
    info.dwStyle = MNS_NOCHECK;
    SetMenuInfo(menu,&info);
    POINT anchor = {x,y};
    ClientToScreen(owner,&anchor);
    SetForegroundWindow(owner);
    UINT chosen = valid ? TrackPopupMenuEx(menu,TPM_RETURNCMD | TPM_NONOTIFY | TPM_LEFTALIGN | TPM_TOPALIGN,
        anchor.x,anchor.y,owner,NULL) : 0;
    RemoveWindowSubclass(owner,vhttpd_workbench_environment_proc,74);
    DestroyMenu(menu);
    if (style.font) DeleteObject(style.font);
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
