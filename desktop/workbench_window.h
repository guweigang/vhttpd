#include <AppKit/AppKit.h>
#include <CoreText/CoreText.h>

// Called from ui2's public window-ready hook. Resolve the active NSWindow in
// AppKit rather than casting the renderer's opaque callback handle.
static void vhttpd_workbench_window_minimum(double width, double height) {
    NSWindow *window = [NSApp keyWindow] ?: [NSApp mainWindow];
    if (window) {
        [window setContentMinSize:NSMakeSize(width, height)];
    }
}

// Track native menu lifetime before the key-equivalent monitor sees Escape.
// AppKit does not always expose its tracking run-loop mode to local monitors.
static int vhttpd_workbench_menu_depth = 0;
@interface VHTTPDWorkbenchMenuTracker : NSObject
- (void)began:(NSNotification *)notification;
- (void)ended:(NSNotification *)notification;
@end
@implementation VHTTPDWorkbenchMenuTracker
- (void)began:(NSNotification *)notification { (void)notification; vhttpd_workbench_menu_depth++; }
- (void)ended:(NSNotification *)notification { (void)notification; if (vhttpd_workbench_menu_depth > 0) vhttpd_workbench_menu_depth--; }
@end

// Keep ui2's native application menu and event target; only relocate About.
static void vhttpd_workbench_configure_app_menu(void) {
    static VHTTPDWorkbenchMenuTracker *tracker = nil;
    if (!tracker) {
        tracker = [VHTTPDWorkbenchMenuTracker new];
        [[NSNotificationCenter defaultCenter] addObserver:tracker selector:@selector(began:) name:NSMenuDidBeginTrackingNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:tracker selector:@selector(ended:) name:NSMenuDidEndTrackingNotification object:nil];
    }
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

static int vhttpd_workbench_menu_tracking(void) {
    return vhttpd_workbench_menu_depth > 0 || [[NSApp mainMenu] highlightedItem] != nil;
}

static int vhttpd_workbench_register_font(const char *path) {
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
    CFErrorRef error = NULL;
    bool registered = CTFontManagerRegisterFontsForURL((CFURLRef)url, kCTFontManagerScopeProcess, &error);
    bool already = error && CFErrorGetCode(error) == kCTFontManagerErrorAlreadyRegistered;
    if (error) CFRelease(error);
    return registered || already;
}
