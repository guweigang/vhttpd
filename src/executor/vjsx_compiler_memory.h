#ifndef VHTTPD_VJSX_COMPILER_MEMORY_H
#define VHTTPD_VJSX_COMPILER_MEMORY_H

#include "../memidle/idle.h"

/* QuickJS uses libc allocations, while V's compiler bridge uses Boehm.
 * Return free libc pages after the temporary compiler has been destroyed. */
#if defined(__GLIBC__)
#include <malloc.h>
#include <pthread.h>
#include <stdatomic.h>
#include <time.h>
static inline void vhttpd_trim_compiler_allocator(void) {
    (void)malloc_trim(0);
}

static inline int vhttpd_maintain_allocator(int active) {
    if (!active && !vhttpd_memory_is_quiet()) return 0;
#if __GLIBC_PREREQ(2, 33)
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    static time_t last_attempt;
    static _Atomic(time_t) last_activity;
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
    if (active) {
        time_t observed = atomic_load_explicit(&last_activity, memory_order_relaxed);
        while (observed < now.tv_sec &&
               !atomic_compare_exchange_weak_explicit(&last_activity, &observed,
                   now.tv_sec, memory_order_relaxed, memory_order_relaxed)) {}
        return 0;
    }
    if (pthread_mutex_trylock(&lock) != 0) return 0;
    int result = 0;
    if (now.tv_sec - atomic_load_explicit(&last_activity, memory_order_relaxed) >= 5 &&
        now.tv_sec - last_attempt >= 30) {
        last_attempt = now.tv_sec;
        struct mallinfo2 usage = mallinfo2();
        if (usage.fordblks >= 32 * 1024 * 1024) {
            result = malloc_trim(0);
        }
    }
    pthread_mutex_unlock(&lock);
    return result;
#else
    (void)active;
    return 0;
#endif
}
#else
static inline void vhttpd_trim_compiler_allocator(void) {}
static inline int vhttpd_maintain_allocator(int active) { (void)active; return 0; }
#endif

#endif
