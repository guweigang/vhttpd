module listener_runtime

import sync
import time

// Owner serializes listener generations, including startup and deferred cleanup.
// The serving loop alone closes handles. Stop never transfers a handle to a
// caller that could close/unlink it after a replacement has started.
@[heap]
pub struct Owner {
mut:
	mu              sync.Mutex
	generation      u64
	closed          bool
	active          bool
	stopping        bool
	listener        ?&Listener
	request_counter u64
	requests        map[u64]AcceptedRequest
}

pub fn (mut owner Owner) reserve() ?u64 {
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	if owner.closed || owner.active { return none }
	owner.generation++
	owner.active = true
	owner.stopping = false
	return owner.generation
}

pub fn (mut owner Owner) publish(generation u64, listener &Listener) bool {
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	if !owner.active || owner.stopping || owner.generation != generation || owner.listener != none {
		return false
	}
	owner.listener = unsafe { listener }
	return true
}

pub fn (mut owner Owner) should_stop(generation u64) bool {
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	return !owner.active || owner.stopping || owner.generation != generation
}

pub fn (mut owner Owner) is_current(generation u64) bool {
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	return owner.active && owner.generation == generation
}

pub fn (mut owner Owner) request_stop() ?u64 {
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	if !owner.active { return none }
	owner.stopping = true
	owner.interrupt_requests()
	return owner.generation
}

// Process shutdown is terminal; provider request_stop remains restartable.
pub fn (mut owner Owner) request_shutdown() ?u64 {
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	owner.closed = true
	if !owner.active { return none }
	owner.stopping = true
	owner.interrupt_requests()
	return owner.generation
}

pub fn (mut owner Owner) wait_stopped(generation u64) {
	for {
		owner.mu.@lock()
		active := owner.active && owner.generation == generation
		owner.mu.unlock()
		if !active { return }
		time.sleep(time.millisecond)
	}
}

// Keep the reservation through close/unlink. A stale finalizer is harmless.
pub fn (mut owner Owner) finish(generation u64) bool {
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	if !owner.active || owner.generation != generation || owner.requests.len > 0 { return false }
	owned := owner.listener
	owner.listener = none
	if mut listener := owned { listener.close() or {} }
	owner.active = false
	owner.stopping = false
	return true
}
