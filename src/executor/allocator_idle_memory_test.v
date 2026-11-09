module executor

#include "@VMODROOT/src/executor/vjsx_allocator_idle_test.h"

fn C.vhttpd_test_idle_allocator_policy() int

fn test_idle_allocator_threshold_rate_limit_and_concurrent_callers() {
	assert C.vhttpd_test_idle_allocator_policy() == 0
}
