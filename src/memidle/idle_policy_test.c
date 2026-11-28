#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "idle.c"
#ifndef _WIN32
static void *activity_thread(void *unused) {
 (void)unused;
 for(int i=0;i<10000;i++){vhttpd_memory_begin();vhttpd_memory_end();}
 return NULL;
}
#endif
static void reset_policy(void) { memset(&vhttpd_memory_idle_state,0,sizeof vhttpd_memory_idle_state);started=collecting=0; }
int main(void) {
 const uint64_t heap=64*1024*1024, now=monotonic_ns();
 reset_policy();assert(vhttpd_memory_start_once()==1);assert(vhttpd_memory_start_once()==0);
 /* An active request cannot become eligible merely by taking a long time. */
 vhttpd_memory_begin();assert(!claim_at(now+10*QUIET_NS,heap));vhttpd_memory_end();
 assert(!claim_at(vhttpd_memory_idle_state.last_activity_ns+QUIET_NS-1,heap));
 assert(claim_at(vhttpd_memory_idle_state.last_activity_ns+QUIET_NS,heap));
 assert(!claim_at(now+10*QUIET_NS,heap));
 /* New traffic invalidates a claim; aborted passes must not raise the floor. */
 vhttpd_memory_begin();assert(!vhttpd_memory_still_idle());vhttpd_memory_end();
 vhttpd_memory_finish(heap,0,0);assert(vhttpd_memory_stats().cancelled==1);assert(vhttpd_memory_stats().heap_after_bytes==0);
 uint64_t next=vhttpd_memory_idle_state.last_attempt_ns+COOLDOWN_NS;
 assert(!claim_at(next-1,heap));assert(claim_at(next,heap));assert(vhttpd_memory_still_idle());
 vhttpd_memory_finish(20*1024*1024,1234,2);
 assert(vhttpd_memory_stats().collections==1);assert(vhttpd_memory_stats().passes==2);
 assert(!claim_at(next+COOLDOWN_NS,20*1024*1024));
 vhttpd_memory_begin();vhttpd_memory_end();
 assert(claim_at(next+COOLDOWN_NS,20*1024*1024));
 vhttpd_memory_finish(20*1024*1024,1500,2);
 next+=COOLDOWN_NS;
 assert(!claim_at(next+COOLDOWN_NS,28*1024*1024-1));
 assert(claim_at(next+COOLDOWN_NS,28*1024*1024));vhttpd_memory_finish(4*1024*1024,2345,1);
 assert(!claim_at(next+2*COOLDOWN_NS,MIN_HEAP_BYTES-1));
 reset_policy();
#ifndef _WIN32
 pthread_t threads[8];for(int i=0;i<8;i++)assert(!pthread_create(&threads[i],NULL,activity_thread,NULL));
 for(int i=0;i<8;i++)pthread_join(threads[i],NULL);
 assert(vhttpd_memory_stats().active==0);assert(vhttpd_memory_stats().generation==160000);
#endif
 puts("idle policy: active, quiet window, concurrent claims, cancellation, cooldown, growth floor and concurrency passed");
 return 0;
}
