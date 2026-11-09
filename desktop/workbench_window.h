#include <AppKit/AppKit.h>
#include <CoreText/CoreText.h>

// Native minimums handle normal edge dragging. Also enforce the same content
// floor when a window manager or sharing host applies a frame directly.
static void vhttpd_workbench_window_content_floor(void *native_window, double width, double height) {
    static BOOL adjusting = NO;
    NSWindow *window = (NSWindow *)native_window;
    if (!window || adjusting) return;
    NSSize size = window.contentView.bounds.size;
    if (size.width + 0.01 >= width && size.height + 0.01 >= height) return;
    adjusting = YES;
    [window setContentSize:NSMakeSize(MAX(size.width, width), MAX(size.height, height))];
    adjusting = NO;
}

// ui2 supplies the owned NSWindow in its ready callback. The application can
// be launching in the background, so keyWindow/mainWindow may both be nil or
// refer to a different window; constraints must target this exact handle.
static void vhttpd_workbench_window_minimum(void *native_window, double width, double height) {
    [NSWindow setAllowsAutomaticWindowTabbing:NO];
    NSWindow *window = (NSWindow *)native_window;
    if (!window) return;
    [window setContentMinSize:NSMakeSize(width, height)];
    NSRect minimumFrame = [window frameRectForContentRect:NSMakeRect(0, 0, width, height)];
    [window setMinSize:minimumFrame.size];
    window.tabbingMode = NSWindowTabbingModeDisallowed;
    vhttpd_workbench_window_content_floor(native_window, width, height);
}

// AppKit recognizes English menu titles and can insert tab/fullscreen rows
// that are absent from the Chinese declaration. This workbench has one window
// and declares fullscreen itself. Filter by action, never localized titles,
// without touching ui2's handleMenuItem: rows or their enabled state.
static void vhttpd_workbench_normalize_menu(NSMenu *menu) {
    for (NSMenuItem *item in [[menu.itemArray copy] autorelease]) {
        NSString *action = NSStringFromSelector(item.action);
        if ([action isEqualToString:@"toggleTabBar:"] ||
            [action isEqualToString:@"toggleTabOverview:"] ||
            [action isEqualToString:@"toggleFullScreen:"] ||
            (item.alternate && [action hasPrefix:@"terminate"])) {
            [menu removeItem:item];
        } else if (item.submenu) {
            vhttpd_workbench_normalize_menu(item.submenu);
        }
    }
    BOOL previousWasSeparator = YES;
    for (NSMenuItem *item in [[menu.itemArray copy] autorelease]) {
        if (item.separatorItem && previousWasSeparator) [menu removeItem:item];
        previousWasSeparator = item.separatorItem;
    }
    if (menu.itemArray.lastObject.separatorItem) [menu removeItem:menu.itemArray.lastObject];
}

// Track native menu lifetime before the key-equivalent monitor sees Escape.
// AppKit does not always expose its tracking run-loop mode to local monitors.
static NSMutableSet *vhttpd_workbench_open_menus = nil;
@interface VHTTPDWorkbenchMenuTracker : NSObject <NSMenuDelegate>
- (void)began:(NSNotification *)notification;
- (void)ended:(NSNotification *)notification;
- (void)menuWillOpen:(NSMenu *)menu;
- (void)menuNeedsUpdate:(NSMenu *)menu;
- (void)menuDidClose:(NSMenu *)menu;
@end
@implementation VHTTPDWorkbenchMenuTracker
- (void)began:(NSNotification *)notification { [vhttpd_workbench_open_menus addObject:notification.object]; }
- (void)ended:(NSNotification *)notification { [vhttpd_workbench_open_menus removeObject:notification.object]; }
- (void)menuNeedsUpdate:(NSMenu *)menu { vhttpd_workbench_normalize_menu(menu); }
- (void)menuWillOpen:(NSMenu *)menu {
    vhttpd_workbench_normalize_menu(menu);
    [vhttpd_workbench_open_menus addObject:menu];
}
- (void)menuDidClose:(NSMenu *)menu { [vhttpd_workbench_open_menus removeObject:menu]; }
@end

static void vhttpd_workbench_track_menu(NSMenu *menu, VHTTPDWorkbenchMenuTracker *tracker) {
    if (!menu) return;
    menu.delegate = tracker;
    for (NSMenuItem *item in menu.itemArray) {
        if (item.submenu) vhttpd_workbench_track_menu(item.submenu,tracker);
    }
}

// Keep ui2's native application menu and event target; only relocate About.
static void vhttpd_workbench_configure_app_menu(const char *about_title, const char *quit_title) {
    static VHTTPDWorkbenchMenuTracker *tracker = nil;
    if (!tracker) {
        tracker = [VHTTPDWorkbenchMenuTracker new];
        vhttpd_workbench_open_menus = [NSMutableSet new];
        [[NSNotificationCenter defaultCenter] addObserver:tracker selector:@selector(began:) name:NSMenuDidBeginTrackingNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:tracker selector:@selector(ended:) name:NSMenuDidEndTrackingNotification object:nil];
    }
    NSMenu *bar = [NSApp mainMenu];
    if (bar.numberOfItems < 2) return;
    vhttpd_workbench_normalize_menu(bar);
    vhttpd_workbench_track_menu(bar,tracker);
    NSMenu *application = [bar itemAtIndex:0].submenu;
    NSString *localizedAbout = [NSString stringWithUTF8String:about_title];
    for (NSMenuItem *item in application.itemArray) {
        if (item.action == @selector(terminate:)) {
            item.title = [NSString stringWithUTF8String:quit_title];
        }
    }
    if ([application itemWithTitle:localizedAbout]) return;
    for (NSInteger index=1; index<bar.numberOfItems; ++index) {
        NSMenu *menu = [bar itemAtIndex:index].submenu;
        NSMenuItem *about = [menu itemWithTitle:localizedAbout];
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
    return vhttpd_workbench_open_menus.count > 0 || [[NSApp mainMenu] highlightedItem] != nil;
}

static int vhttpd_workbench_register_font(const char *path) {
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
    CFErrorRef error = NULL;
    bool registered = CTFontManagerRegisterFontsForURL((CFURLRef)url, kCTFontManagerScopeProcess, &error);
    bool already = error && CFErrorGetCode(error) == kCTFontManagerErrorAlreadyRegistered;
    if (error) CFRelease(error);
    return registered || already;
}
