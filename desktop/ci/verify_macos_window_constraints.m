// Compile with: clang -I. -framework AppKit -framework CoreText \
//   desktop/ci/verify_macos_window_constraints.m -o /tmp/workbench-window-test
#import "desktop/workbench_window.h"

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
        [editor release];
        [owned release];
        puts("PASS exact owned NSWindow constraints during background startup: content minimum 760 x 660");
    }
    return 0;
}
