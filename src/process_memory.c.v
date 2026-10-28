module main

#include "@VMODROOT/src/process_memory.h"

fn C.vhttpd_configure_process_allocator()

// Configure before application workers start. Explicit glibc tuning wins over
// the bounded default used by the standalone server.
fn configure_process_allocator() {
	C.vhttpd_configure_process_allocator()
}
