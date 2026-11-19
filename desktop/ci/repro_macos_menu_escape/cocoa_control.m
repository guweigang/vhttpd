#import <Cocoa/Cocoa.h>
@interface ProbeDelegate : NSObject <NSApplicationDelegate>
@property(retain) NSWindow *window;
@end
@implementation ProbeDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)note {
 NSMenu *bar=[NSMenu new];NSMenuItem *appItem=[NSMenuItem new];[bar addItem:appItem];NSMenu *appMenu=[NSMenu new];appItem.submenu=appMenu;[appMenu addItemWithTitle:@"Quit Cocoa Control" action:@selector(terminate:) keyEquivalent:@"q"];
 NSMenuItem *project=[NSMenuItem new];project.title=@"Project";[bar addItem:project];project.submenu=[NSMenu new];[project.submenu addItemWithTitle:@"No action" action:nil keyEquivalent:@""];NSApp.mainMenu=bar;
 self.window=[[NSWindow alloc] initWithContentRect:NSMakeRect(150,150,500,260) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];self.window.title=@"Cocoa Menu Control";
 NSTextField *label=[NSTextField labelWithString:@"FORM OPEN"];label.frame=NSMakeRect(20,180,300,40);[self.window.contentView addSubview:label];NSTextField *field=[[NSTextField alloc] initWithFrame:NSMakeRect(20,120,400,35)];field.stringValue=@"fixture";[self.window.contentView addSubview:field];[self.window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app {return YES;}
@end
int main(){@autoreleasepool{NSApplication *app=NSApplication.sharedApplication;[app setActivationPolicy:NSApplicationActivationPolicyRegular];ProbeDelegate *d=[ProbeDelegate new];app.delegate=d;[app run];}}
