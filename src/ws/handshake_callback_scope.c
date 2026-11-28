#include "handshake_callback_scope.h"
#if defined(_MSC_VER)
__declspec(thread) void *vhttpd_ws_handshake_capture;
#else
_Thread_local void *vhttpd_ws_handshake_capture;
#endif
