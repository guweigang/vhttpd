#ifndef VHTTPD_MEMORY_IDLE_H
#define VHTTPD_MEMORY_IDLE_H
#include <stdint.h>
typedef struct {
 uint64_t active, last_activity_ns, last_attempt_ns;
 uint64_t attempts, collections, last_elapsed_ns, max_elapsed_ns;
 uint64_t heap_after_bytes, generation, claimed_generation, cancelled, passes;
} VhttpdMemoryIdleStats;
void vhttpd_memory_begin(void);
void vhttpd_memory_end(void);
void vhttpd_memory_touch(void);
int vhttpd_memory_start_once(void);
int vhttpd_memory_claim(uint64_t heap_bytes);
int vhttpd_memory_still_idle(void);
int vhttpd_memory_is_quiet(void);
void vhttpd_memory_finish(uint64_t heap_bytes, uint64_t elapsed_ns, int passes);
VhttpdMemoryIdleStats vhttpd_memory_stats(void);
#endif
