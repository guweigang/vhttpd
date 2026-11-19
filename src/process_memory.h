#ifndef VHTTPD_PROCESS_MEMORY_H
#define VHTTPD_PROCESS_MEMORY_H

#include <stdlib.h>

#if defined(__GLIBC__)
#include <malloc.h>
#endif

static inline void vhttpd_configure_process_allocator(void) {
#if defined(__GLIBC__)
    /* Per-thread arenas otherwise retain substantial freed bootstrap memory.
     * Keep the default bounded on small servers; operators can raise it through
     * glibc's standard MALLOC_ARENA_MAX environment variable. */
    if (getenv("MALLOC_ARENA_MAX") == NULL)
        (void)mallopt(M_ARENA_MAX, 2);
#endif
}

#endif
