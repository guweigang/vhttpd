#ifndef VHTTPD_VJSX_COMPILER_MEMORY_H
#define VHTTPD_VJSX_COMPILER_MEMORY_H

/* QuickJS uses libc allocations, while V's compiler bridge uses Boehm.
 * Return free libc pages after the temporary compiler has been destroyed. */
#if defined(__GLIBC__)
#include <malloc.h>
static inline void vhttpd_trim_compiler_allocator(void) {
    (void)malloc_trim(0);
}
#else
static inline void vhttpd_trim_compiler_allocator(void) {}
#endif

#endif
