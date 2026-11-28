static BOOL CALLBACK vhttpd_probe_count_update(HWND hwnd, LPARAM data) {
    if (GetUpdateRect(hwnd, NULL, FALSE)) ++*(int *)data;
    return TRUE;
}

static BOOL CALLBACK vhttpd_probe_validate_child(HWND hwnd, LPARAM data) {
    ValidateRect(hwnd, NULL);
    ++*(int *)data;
    return TRUE;
}

static int vhttpd_probe_unchanged_children(void *window, int reset) {
    int count = 0;
    if (reset) {
        ValidateRect((HWND)window, NULL);
        EnumChildWindows((HWND)window, vhttpd_probe_validate_child, (LPARAM)&count);
    } else {
        vhttpd_probe_count_update((HWND)window, (LPARAM)&count);
        EnumChildWindows((HWND)window, vhttpd_probe_count_update, (LPARAM)&count);
    }
    return count;
}

static int vhttpd_probe_edit_needs_repaint(void *window) {
    HWND edit = FindWindowExW((HWND)window, NULL, L"Edit", NULL);
    return edit == NULL || GetUpdateRect(edit, NULL, FALSE);
}
