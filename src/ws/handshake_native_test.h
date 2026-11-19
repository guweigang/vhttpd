#ifndef VHTTPD_HANDSHAKE_NATIVE_TEST_H
#define VHTTPD_HANDSHAKE_NATIVE_TEST_H
#include <stdint.h>
#if defined(__linux__)
#include <malloc.h>
#if defined(__GLIBC__)
#if __GLIBC_PREREQ(2, 33)
#define VHTTPD_HAS_MALLINFO2 1
#endif
#endif
#endif
static inline uint64_t vhttpd_test_allocator_in_use(void) {
#if defined(VHTTPD_HAS_MALLINFO2)
    return (uint64_t)mallinfo2().uordblks;
#else
    return 0;
#endif
}
#endif
