#ifndef VHTTPD_VJSX_ALLOCATOR_IDLE_TEST_H
#define VHTTPD_VJSX_ALLOCATOR_IDLE_TEST_H

#if defined(__GLIBC__)
#include <malloc.h>
#include <pthread.h>
#include <time.h>
#include "vjsx_compiler_memory.h"
#if __GLIBC_PREREQ(2, 33)

static time_t vhttpd_test_trim_time = 100;
static size_t vhttpd_test_trim_free = 32 * 1024 * 1024 - 1;
static int vhttpd_test_trim_calls;
static int vhttpd_test_trim_clock_failure;

static int vhttpd_test_trim_clock(clockid_t clock, struct timespec *now) {
    (void)clock;
    now->tv_sec = vhttpd_test_trim_time;
    now->tv_nsec = 0;
    return vhttpd_test_trim_clock_failure ? -1 : 0;
}

static struct mallinfo2 vhttpd_test_trim_usage(void) {
    struct mallinfo2 result = {0};
    result.fordblks = vhttpd_test_trim_free;
    return result;
}

static int vhttpd_test_trim_call(size_t pad) {
    (void)pad;
    vhttpd_test_trim_calls++;
    return 1;
}

// Compile a separate copy of the actual helper with deterministic allocator
// and clock observations. The production helper keeps its own static state.
#undef VHTTPD_VJSX_COMPILER_MEMORY_H
#define vhttpd_maintain_allocator vhttpd_test_trim_helper
#define vhttpd_trim_compiler_allocator vhttpd_test_trim_compiler
#define clock_gettime(clock, now) vhttpd_test_trim_clock(clock, now)
#define mallinfo2() vhttpd_test_trim_usage()
#define malloc_trim(pad) vhttpd_test_trim_call(pad)
#include "vjsx_compiler_memory.h"
#undef vhttpd_maintain_allocator
#undef vhttpd_trim_compiler_allocator
#undef clock_gettime
#undef mallinfo2
#undef malloc_trim

static void *vhttpd_test_trim_thread(void *unused) {
    (void)unused;
    (void)vhttpd_test_trim_helper(0);
    return NULL;
}

static int vhttpd_test_idle_allocator_policy(void) {
    if (vhttpd_test_trim_helper(0) != 0 || vhttpd_test_trim_calls != 0) return 1;
    vhttpd_test_trim_free = 64 * 1024 * 1024;
    vhttpd_test_trim_time = 110;
    if (vhttpd_test_trim_helper(0) != 0 || vhttpd_test_trim_calls != 0) return 2;
    vhttpd_test_trim_time = 130;
    if (vhttpd_test_trim_helper(0) != 1 || vhttpd_test_trim_calls != 1) return 3;
    vhttpd_test_trim_time = 159;
    if (vhttpd_test_trim_helper(0) != 0 || vhttpd_test_trim_calls != 1) return 4;
    vhttpd_test_trim_time = 160;
    pthread_t threads[16];
    for (int i = 0; i < 16; i++) {
        if (pthread_create(&threads[i], NULL, vhttpd_test_trim_thread, NULL)) return 5;
    }
    for (int i = 0; i < 16; i++) {
        if (pthread_join(threads[i], NULL)) return 6;
    }
    if (vhttpd_test_trim_calls != 2) return 7;
    vhttpd_test_trim_time = 190;
    vhttpd_test_trim_clock_failure = 1;
    if (vhttpd_test_trim_helper(0) != 0 || vhttpd_test_trim_calls != 2) return 8;
    vhttpd_test_trim_clock_failure = 0;
    if (vhttpd_test_trim_helper(0) != 1 || vhttpd_test_trim_calls != 3) return 9;
    vhttpd_test_trim_time = 225;
    if (vhttpd_test_trim_helper(1) != 0) return 10;
    vhttpd_test_trim_time = 229;
    if (vhttpd_test_trim_helper(0) != 0 || vhttpd_test_trim_calls != 3) return 11;
    vhttpd_test_trim_time = 230;
    if (vhttpd_test_trim_helper(0) != 1 || vhttpd_test_trim_calls != 4) return 12;
    vhttpd_test_trim_time = 270;
    (void)vhttpd_test_trim_helper(1);
    // A delayed activity observation must not move the shared timestamp back.
    vhttpd_test_trim_time = 265;
    (void)vhttpd_test_trim_helper(1);
    vhttpd_test_trim_time = 274;
    if (vhttpd_test_trim_helper(0) != 0 || vhttpd_test_trim_calls != 4) return 13;
    vhttpd_test_trim_time = 275;
    if (vhttpd_test_trim_helper(0) != 1 || vhttpd_test_trim_calls != 5) return 14;
    return 0;
}
#else
static int vhttpd_test_idle_allocator_policy(void) { return 0; }
#endif
#else
static int vhttpd_test_idle_allocator_policy(void) { return 0; }
#endif
#endif
