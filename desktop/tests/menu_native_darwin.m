#include "../workbench_window.h"
#include <assert.h>

static NSMenuItem *row(NSString *title, SEL action) {
    return [[[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""] autorelease];
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        for (NSString *title in @[@"View", @"查看"]) {
            NSMenu *menu = [[[NSMenu alloc] initWithTitle:title] autorelease];
            menu.autoenablesItems = NO;
            NSMenuItem *declared = row(@"Apps", NSSelectorFromString(@"handleMenuItem:"));
            declared.enabled = NO;
            declared.state = NSControlStateValueOn;
            declared.keyEquivalent = @"a";
            [menu addItem:[NSMenuItem separatorItem]];
            [menu addItem:row(@"system tabs", @selector(toggleTabBar:))];
            [menu addItem:declared];
            [menu addItem:[NSMenuItem separatorItem]];
            [menu addItem:[NSMenuItem separatorItem]];
            [menu addItem:row(@"system overview", @selector(toggleTabOverview:))];
            NSMenuItem *parent = row(@"Window", NULL);
            parent.submenu = [[[NSMenu alloc] initWithTitle:@"Window"] autorelease];
            NSMenuItem *fullscreen = row(@"Full screen", NSSelectorFromString(@"handleMenuItem:"));
            [parent.submenu addItem:fullscreen];
            [parent.submenu addItem:row(@"system full screen", @selector(toggleFullScreen:))];
            [menu addItem:parent];
            NSMenuItem *quit = row(@"Quit", @selector(terminate:));
            [menu addItem:quit];
            NSMenuItem *alternate = row(@"system alternate quit", NSSelectorFromString(@"terminateAndKeepWindows:"));
            alternate.alternate = YES;
            [menu addItem:alternate];
            [menu addItem:[NSMenuItem separatorItem]];
            vhttpd_workbench_normalize_menu(menu);
            assert(menu.numberOfItems == 4);
            assert([menu itemAtIndex:0] == declared);
            assert([menu itemAtIndex:1].separatorItem);
            assert([menu itemAtIndex:2] == parent);
            assert([menu itemAtIndex:3] == quit);
            assert(parent.submenu.numberOfItems == 1);
            assert([parent.submenu itemAtIndex:0] == fullscreen);
            assert(!declared.enabled && declared.state == NSControlStateValueOn);
            assert([declared.keyEquivalent isEqualToString:@"a"]);
            vhttpd_workbench_normalize_menu(menu);
            assert(menu.numberOfItems == 4);
        }
        puts("PASS native menu normalization: both languages, recursive system items, explicit actions/state/shortcuts, idempotence");
    }
    return 0;
}
