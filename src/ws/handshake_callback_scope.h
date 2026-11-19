#ifndef VHTTPD_WS_HANDSHAKE_CALLBACK_SCOPE_H
#define VHTTPD_WS_HANDSHAKE_CALLBACK_SCOPE_H
#if defined(_MSC_VER)
extern __declspec(thread) void *vhttpd_ws_handshake_capture;
#else
extern _Thread_local void *vhttpd_ws_handshake_capture;
#endif
static inline void vhttpd_ws_handshake_set(void *capture) { vhttpd_ws_handshake_capture = capture; }
static inline void *vhttpd_ws_handshake_get(void) { return vhttpd_ws_handshake_capture; }
#endif
