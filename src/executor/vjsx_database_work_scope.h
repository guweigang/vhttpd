#ifndef VHTTPD_VJSX_DATABASE_WORK_SCOPE_H
#define VHTTPD_VJSX_DATABASE_WORK_SCOPE_H
/* closure.Lifetime.frame borrows a zero-argument callback. Thread-local input
 * lets every worker use a static callback instead of leaking a captured wrapper.
 * The V caller keeps the work object rooted on its stack for the entire frame. */
#if defined(_MSC_VER)
extern __declspec(thread) void *vhttpd_database_scope_work;
#else
extern _Thread_local void *vhttpd_database_scope_work;
#endif
static inline void vhttpd_database_scope_set(void *work) { vhttpd_database_scope_work = work; }
static inline void *vhttpd_database_scope_get(void) { return vhttpd_database_scope_work; }
#endif
