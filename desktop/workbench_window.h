#include <AppKit/AppKit.h>

// Called from ui2's public window-ready hook. Resolve the active NSWindow in
// AppKit rather than casting the renderer's opaque callback handle.
static void vhttpd_workbench_window_minimum(double width, double height) {
    NSWindow *window = [NSApp keyWindow] ?: [NSApp mainWindow];
    if (window) {
        [window setContentMinSize:NSMakeSize(width, height)];
    }
}

// Keep ui2's native application menu and event target; only relocate About.
static void vhttpd_workbench_configure_app_menu(void) {
    NSMenu *bar = [NSApp mainMenu];
    if (bar.numberOfItems < 2) return;
    NSMenu *application = [bar itemAtIndex:0].submenu;
    if ([application itemWithTitle:@"关于 vhttpd Workbench"]) return;
    for (NSInteger index=1; index<bar.numberOfItems; ++index) {
        NSMenu *menu = [bar itemAtIndex:index].submenu;
        NSMenuItem *about = [menu itemWithTitle:@"关于 vhttpd Workbench"];
        if (!about) continue;
        [about retain];
        [menu removeItem:about];
        [application insertItem:about atIndex:0];
        [about release];
        [application insertItem:[NSMenuItem separatorItem] atIndex:1];
        if (menu.numberOfItems && [menu itemAtIndex:menu.numberOfItems-1].separatorItem)
            [menu removeItemAtIndex:menu.numberOfItems-1];
        break;
    }
}
