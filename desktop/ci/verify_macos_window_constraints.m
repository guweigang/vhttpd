// Compile with: clang -I. -framework AppKit -framework CoreText \
//   desktop/ci/verify_macos_window_constraints.m -o /tmp/workbench-window-test
#import "desktop/workbench_window.h"

@interface VHTTPDWindowProbe : NSObject <NSWindowDelegate>
@property(nonatomic, assign) BOOL resized;
@property(nonatomic, assign) BOOL closed;
@end
@implementation VHTTPDWindowProbe
- (void)windowDidResize:(NSNotification *)notification { self.resized = YES; }
- (void)windowWillClose:(NSNotification *)notification { self.closed = YES; }
@end

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSWindow *owned = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 980, 740)
            styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
            backing:NSBackingStoreBuffered defer:NO];
        // Deliberately do not order the window front. This reproduces background
        // startup where looking up NSApp.keyWindow/mainWindow silently fails.
        NSCAssert(NSApp.keyWindow == nil && NSApp.mainWindow == nil, @"test window unexpectedly activated");
        vhttpd_workbench_window_minimum((void *)owned, 760, 660);
        NSCAssert(NSEqualSizes(owned.contentMinSize, NSMakeSize(760, 660)), @"owned window minimum was not installed");
        NSSize expected = [owned frameRectForContentRect:NSMakeRect(0, 0, 760, 660)].size;
        NSCAssert(NSEqualSizes(owned.minSize, expected), @"frame minimum does not include title bar");
        NSCAssert(owned.tabbingMode == NSWindowTabbingModeDisallowed, @"unexpected native window tabbing");
        NSTextView *editor = [[NSTextView alloc] initWithFrame:NSMakeRect(12, 12, 200, 40)];
        [owned.contentView addSubview:editor];
        NSCAssert([owned makeFirstResponder:editor], @"test editor did not receive focus");
        // Programmatic frames bypass AppKit's interactive min-size checks.
        [owned setContentSize:NSMakeSize(100, 120)];
        vhttpd_workbench_window_content_floor((void *)owned, 760, 660);
        NSCAssert(NSEqualSizes(owned.contentView.bounds.size, NSMakeSize(760, 660)), @"undersized content was not restored");
        NSCAssert(owned.firstResponder == editor, @"size correction changed keyboard focus");
        [owned setContentSize:NSMakeSize(1200, 800)];
        vhttpd_workbench_window_content_floor((void *)owned, 760, 660);
        NSCAssert(NSEqualSizes(owned.contentView.bounds.size, NSMakeSize(1200, 800)), @"valid user size was changed");
        vhttpd_workbench_window_minimum(NULL, 760, 660);
        // A close-to-tray request must preserve the exact window and editor.
        owned.releasedWhenClosed = NO;
        VHTTPDWindowProbe *probe = [VHTTPDWindowProbe new];
        owned.delegate = probe;
        vhttpd_workbench_close_to_tray((void *)owned,1);
        [(id)owned.delegate windowDidResize:[NSNotification notificationWithName:NSWindowDidResizeNotification object:owned]];
        NSCAssert(probe.resized, @"ui2 resize callback was not forwarded");
        [owned performClose:nil];
        [owned close];
        NSCAssert(![NSApp.delegate applicationShouldTerminateAfterLastWindowClosed:NSApp], @"closing the window terminated the app");
        NSCAssert(owned.contentView != nil, @"closed window lost its content");
        NSCAssert(!owned.visible, @"closed window remained visible");
        NSCAssert(owned.delegate == probe, @"ui2 window delegate was replaced");
        vhttpd_workbench_close_to_tray((void *)owned,0);
        [owned close];
        NSCAssert([NSApp.delegate applicationShouldTerminateAfterLastWindowClosed:NSApp], @"explicit quit was intercepted");
        NSApp.delegate = nil;
        owned.delegate = nil;
        [probe release];
        [editor release];
        [owned release];
        puts("PASS owned NSWindow constraints, close-to-tray preservation, delegate preservation and explicit quit");
    }
    return 0;
}
