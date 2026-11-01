#ifndef VHTTPD_WORKBENCH_WINDOW_LINUX_H
#define VHTTPD_WORKBENCH_WINDOW_LINUX_H
#include <X11/Xlib.h>
#include <string.h>

/* Request activation through the window manager after a user log handoff. */
static void vhttpd_workbench_activate_x11(void *native_display, unsigned long window) {
    Display *display = (Display *)native_display;
    if (!display || !window) return;
    XEvent event;
    memset(&event, 0, sizeof(event));
    event.xclient.type = ClientMessage;
    event.xclient.window = window;
    event.xclient.message_type = XInternAtom(display, "_NET_ACTIVE_WINDOW", False);
    event.xclient.format = 32;
    event.xclient.data.l[0] = 1; /* ordinary application */
    event.xclient.data.l[1] = CurrentTime;
    XMapRaised(display, window);
    XSendEvent(display, DefaultRootWindow(display), False,
               SubstructureRedirectMask | SubstructureNotifyMask, &event);
    XFlush(display);
}
#endif
