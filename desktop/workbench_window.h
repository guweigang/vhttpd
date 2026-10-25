#include <AppKit/AppKit.h>

// Called from ui2's public window-ready hook. Resolve the active NSWindow in
// AppKit rather than casting the renderer's opaque callback handle.
static void vhttpd_workbench_window_minimum(double width, double height) {
    NSWindow *window = [NSApp keyWindow] ?: [NSApp mainWindow];
    if (window) {
        [window setContentMinSize:NSMakeSize(width, height)];
    }
}
