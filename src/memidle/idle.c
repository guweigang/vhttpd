#include "idle.h"
#include <stddef.h>
#ifdef _WIN32
#include <windows.h>
static volatile LONG memory_lock;
static int lock_try(void) { return InterlockedCompareExchange(&memory_lock,1,0)==0; }
static void lock_enter(void) { while(!lock_try()) SwitchToThread(); }
static void lock_leave(void) { InterlockedExchange(&memory_lock,0); }
static uint64_t monotonic_ns(void) { return (uint64_t)GetTickCount64()*1000000; }
#else
#include <pthread.h>
#include <time.h>
static pthread_mutex_t memory_lock=PTHREAD_MUTEX_INITIALIZER;
static int lock_try(void) { return pthread_mutex_trylock(&memory_lock)==0; }
static void lock_enter(void) { pthread_mutex_lock(&memory_lock); }
static void lock_leave(void) { pthread_mutex_unlock(&memory_lock); }
static uint64_t monotonic_ns(void) {
 struct timespec t;
 if(clock_gettime(CLOCK_MONOTONIC,&t)!=0) return 0;
 return (uint64_t)t.tv_sec*1000000000+(uint64_t)t.tv_nsec;
}
#endif
#define QUIET_NS (UINT64_C(30)*1000000000)
#define COOLDOWN_NS (UINT64_C(60)*1000000000)
#define MIN_HEAP_BYTES (UINT64_C(16)*1024*1024)
#define MIN_GROWTH_BYTES (UINT64_C(8)*1024*1024)
/* One linked definition, shared by every V module and C translation unit. */
VhttpdMemoryIdleStats vhttpd_memory_idle_state;
static int started, collecting;

void vhttpd_memory_begin(void) {
 lock_enter();
 vhttpd_memory_idle_state.active++;
 vhttpd_memory_idle_state.generation++;
 vhttpd_memory_idle_state.last_activity_ns=monotonic_ns();
 lock_leave();
}
void vhttpd_memory_end(void) {
 lock_enter();
 if(vhttpd_memory_idle_state.active) vhttpd_memory_idle_state.active--;
 vhttpd_memory_idle_state.last_activity_ns=monotonic_ns();
 vhttpd_memory_idle_state.generation++;
 lock_leave();
}
void vhttpd_memory_touch(void) {
 lock_enter();
 vhttpd_memory_idle_state.last_activity_ns=monotonic_ns();
 vhttpd_memory_idle_state.generation++;
 lock_leave();
}
int vhttpd_memory_start_once(void) {
 lock_enter();int result=!started;
 if(result) { started=1;vhttpd_memory_idle_state.last_activity_ns=monotonic_ns(); }
 lock_leave();return result;
}
static int claim_at(uint64_t now,uint64_t heap) {
 VhttpdMemoryIdleStats *s=&vhttpd_memory_idle_state;
 if(!now || collecting || s->active || now<s->last_activity_ns || now-s->last_activity_ns<QUIET_NS) return 0;
 if(s->last_attempt_ns && (now<s->last_attempt_ns || now-s->last_attempt_ns<COOLDOWN_NS)) return 0;
 if(heap<MIN_HEAP_BYTES) return 0;
 /* A new workload may leave garbage without expanding an existing pool. */
 if(s->heap_after_bytes && s->generation==s->claimed_generation &&
    (heap<s->heap_after_bytes || heap-s->heap_after_bytes<MIN_GROWTH_BYTES)) return 0;
 collecting=1;s->last_attempt_ns=now;s->claimed_generation=s->generation;s->attempts++;
 return 1;
}
int vhttpd_memory_claim(uint64_t heap) {
 if(!lock_try())return 0;
 int result=claim_at(monotonic_ns(),heap);lock_leave();return result;
}
int vhttpd_memory_is_quiet(void) {
 lock_enter();uint64_t now=monotonic_ns();
 int result=now && !vhttpd_memory_idle_state.active && now>=vhttpd_memory_idle_state.last_activity_ns && now-vhttpd_memory_idle_state.last_activity_ns>=QUIET_NS;
 lock_leave();return result;
}
int vhttpd_memory_still_idle(void) {
 lock_enter();int result=collecting && !vhttpd_memory_idle_state.active && vhttpd_memory_idle_state.generation==vhttpd_memory_idle_state.claimed_generation;
 lock_leave();return result;
}
void vhttpd_memory_finish(uint64_t heap,uint64_t elapsed,int passes) {
 lock_enter();
 if(passes>0) {
  vhttpd_memory_idle_state.collections++;
  vhttpd_memory_idle_state.passes+=(uint64_t)passes;
  vhttpd_memory_idle_state.heap_after_bytes=heap;
 } else { vhttpd_memory_idle_state.cancelled++; }
 vhttpd_memory_idle_state.last_elapsed_ns=elapsed;
 if(elapsed>vhttpd_memory_idle_state.max_elapsed_ns)vhttpd_memory_idle_state.max_elapsed_ns=elapsed;
 collecting=0;lock_leave();
}
VhttpdMemoryIdleStats vhttpd_memory_stats(void) {
 lock_enter();VhttpdMemoryIdleStats result=vhttpd_memory_idle_state;lock_leave();return result;
}
