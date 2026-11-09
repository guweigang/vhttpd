module memidle

import time

#flag @VMODROOT/src/memidle/idle.c
#include "@VMODROOT/src/memidle/idle.h"

fn C.vhttpd_memory_begin()
fn C.vhttpd_memory_end()
fn C.vhttpd_memory_touch()
fn C.vhttpd_memory_start_once() int
fn C.vhttpd_memory_claim(heap u64) int
fn C.vhttpd_memory_still_idle() int
fn C.vhttpd_memory_finish(heap u64, elapsed u64, passes int)

pub fn begin() { C.vhttpd_memory_begin() }
pub fn end() { C.vhttpd_memory_end() }
pub fn touch() { C.vhttpd_memory_touch() }

$if gcboehm ? {
	#include <gc.h>
	fn C.GC_get_heap_size() uint
	fn C.GC_gcollect_and_unmap()
}

// One process-wide worker, including processes with only native HTTP routes.
pub fn start() {
	$if gcboehm ? {
		if C.vhttpd_memory_start_once() != 0 { spawn reclaim_loop() }
	}
}

fn reclaim_loop() {
	$if gcboehm ? {
		for {
			time.sleep(time.second)
			if C.vhttpd_memory_claim(u64(C.GC_get_heap_size())) == 0 { continue }
			started := time.sys_mono_now()
			mut passes := 0
			// A request can arrive after a quiet-period claim. Recheck before
			// each pass; never hold an application/allocator gate across GC.
			if C.vhttpd_memory_still_idle() != 0 { C.GC_gcollect_and_unmap(); passes++ }
			if C.vhttpd_memory_still_idle() != 0 { C.GC_gcollect_and_unmap(); passes++ }
			C.vhttpd_memory_finish(u64(C.GC_get_heap_size()), u64(time.sys_mono_now()-started), passes)
		}
	}
}

@[typedef]
struct C.VhttpdMemoryIdleStats {
	active u64
	last_activity_ns u64
	last_attempt_ns u64
	attempts u64
	collections u64
	last_elapsed_ns u64
	max_elapsed_ns u64
	heap_after_bytes u64
	generation u64
	claimed_generation u64
	cancelled u64
	passes u64
}
fn C.vhttpd_memory_stats() C.VhttpdMemoryIdleStats

pub struct Stats {
pub:
	active u64
	attempts u64
	collections u64
	last_elapsed_ns u64
	max_elapsed_ns u64
	heap_after_bytes u64
	cancelled u64
	passes u64
}
pub fn stats() Stats {
	s := C.vhttpd_memory_stats()
	return Stats{active:s.active, attempts:s.attempts, collections:s.collections,
		last_elapsed_ns:s.last_elapsed_ns,max_elapsed_ns:s.max_elapsed_ns,
		heap_after_bytes:s.heap_after_bytes,cancelled:s.cancelled,passes:s.passes}
}
