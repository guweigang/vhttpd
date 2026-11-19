module executor

#include "@VMODROOT/src/executor/vjsx_compiler_memory.h"

fn C.vhttpd_trim_compiler_allocator()
fn C.vhttpd_maintain_allocator(active bool) int

fn maintain_inproc_vjsx_allocator(active bool) {
	C.vhttpd_maintain_allocator(active)
}

$if gcboehm ? {
	#include <gc/gc.h>
	fn C.GC_gcollect_and_unmap()
}

// Bootstrap is allocation-heavy, unlike ordinary request dispatch. Once its
// temporary context is gone, reclaim the bridge's garbage and return free pages.
fn release_inproc_vjsx_compiler_memory() {
	$if gcboehm ? {
		C.GC_gcollect_and_unmap()
		// Boehm only unmaps blocks that were already free before a collection.
		// Age the pages just reclaimed from bootstrap so they can be returned too.
		C.GC_gcollect_and_unmap()
	} $else {
		gc_collect()
	}
	C.vhttpd_trim_compiler_allocator()
}
