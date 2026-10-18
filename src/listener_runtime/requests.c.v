module listener_runtime

import net
import time

#include <fcntl.h>
fn C.fcntl(fd i32, cmd i32, arg ...voidptr) i32

struct AcceptedRequest {
	interrupt int
mut:
	dispatching bool
}

// Register before spawning. The duplicate belongs to the listener generation;
// the handler alone closes the original connection, then completes this token.
pub fn (mut owner Owner) accept_request(generation u64, socket int) ?u64 {
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	if !owner.active || owner.stopping || owner.generation != generation { return none }
	fd := C.fcntl(socket, C.F_DUPFD_CLOEXEC, 0)
	if fd < 0 { return none }
	owner.request_counter++
	owner.requests[owner.request_counter] = AcceptedRequest{interrupt: fd}
	return owner.request_counter
}

// Linearize dispatch admission against stop. Already admitted work completes
// cooperatively, while unread/decoded requests cannot enter after stop.
pub fn (mut owner Owner) begin_request(generation u64, request u64) bool {
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	if !owner.active || owner.stopping || owner.generation != generation { return false }
	mut accepted := owner.requests[request] or { return false }
	if accepted.dispatching { return false }
	accepted.dispatching = true
	owner.requests[request] = accepted
	return true
}

pub fn (mut owner Owner) complete_request(request u64) {
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	accepted := owner.requests[request] or { return }
	net.close(accepted.interrupt) or {}
	owner.requests.delete(request)
}

// Called with owner.mu held. Never shut down a borrowed descriptor: its number
// may have been recycled between handler close and completion registration.
fn (mut owner Owner) interrupt_requests() {
	for _, accepted in owner.requests { net.shutdown(accepted.interrupt) }
}

pub fn (mut owner Owner) active_requests(generation u64) int {
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	return if owner.active && owner.generation == generation { owner.requests.len } else { 0 }
}

// The serving loop waits outside application locks before resource teardown.
// Also covers early serving-loop returns, not just an explicit stop request.
pub fn (mut owner Owner) drain_requests(generation u64) {
	owner.mu.@lock()
	if owner.active && owner.generation == generation {
		owner.stopping = true
		owner.interrupt_requests()
	}
	owner.mu.unlock()
	for owner.active_requests(generation) > 0 { time.sleep(time.millisecond) }
}
