module connection_runtime

import net
import net.websocket
import sync
import time

#include <fcntl.h>

fn C.fcntl(fd i32, cmd i32, arg ...voidptr) i32

// A session owns an interrupt descriptor for one connected socket. Atomic
// CLOEXEC duplication excludes executed worker children and prevents a late
// stop from shutting down a recycled descriptor after EOF.
@[heap]
pub struct Session {
mut:
	mu        sync.Mutex
	stopping  bool
	interrupt ?int
	reason    string
}

pub fn Session.connected(client &websocket.Client) !&Session {
	// Client.conn is a nullable library field until TCP connect succeeds.
	if isnil(client.conn) { return error('websocket_connection_unavailable') }
	mut session := &Session{}
	session.retain_native(client.conn.sock.handle)!
	return session
}

// Transfer a fresh descriptor from the retained socket, never a native client fd
// that may already have been closed and reused. The caller owns closing it.
pub fn (mut session Session) duplicate_interrupt() !int {
	session.mu.@lock()
	defer { session.mu.unlock() }
	fd := session.interrupt or { return error('websocket_session_released') }
	owned := C.fcntl(fd, C.F_DUPFD_CLOEXEC, 0)
	if owned < 0 { return error('websocket_interrupt_dup_failed') }
	return owned
}

pub fn (mut session Session) request_stop() {
	session.mu.@lock()
	defer { session.mu.unlock() }
	session.stopping = true
	if fd := session.interrupt { net.shutdown(fd) }
}

pub fn (mut session Session) stopped() bool {
	session.mu.@lock()
	defer { session.mu.unlock() }
	return session.stopping
}

pub fn (mut session Session) note_reason(reason string) {
	session.mu.@lock()
	defer { session.mu.unlock() }
	if session.reason == '' { session.reason = reason }
}

pub fn (mut session Session) disconnect_reason() string {
	session.mu.@lock()
	defer { session.mu.unlock() }
	return if session.reason != '' { session.reason } else { 'stopped' }
}

// Broadcast cancellation is state, not a single-consumer channel message.
pub fn (mut session Session) wait(delay time.Duration) bool {
	deadline := time.now().add(delay)
	for !session.stopped() {
		remaining := deadline - time.now()
		if remaining <= 0 { return true }
		time.sleep(if remaining < 10 * time.millisecond { remaining } else { 10 * time.millisecond })
	}
	return false
}

// Call only after the reader and every session task have exited.
pub fn (mut session Session) release() {
	session.mu.@lock()
	defer { session.mu.unlock() }
	session.stopping = true
	owned := session.interrupt
	session.interrupt = none
	if fd := owned { net.close(fd) or {} }
}

@[heap]
pub struct Run {
mut:
	mu       sync.Mutex
	stopping bool
	done     bool
	session  ?&Session
}

pub fn (mut run Run) stopped() bool {
	run.mu.@lock()
	defer { run.mu.unlock() }
	return run.stopping
}

pub fn (mut run Run) attach(mut session Session) bool {
	run.mu.@lock()
	defer { run.mu.unlock() }
	if run.stopping || run.done || run.session != none {
		session.request_stop()
		return false
	}
	run.session = unsafe { &session }
	return true
}

pub fn (mut run Run) detach(session &Session) {
	run.mu.@lock()
	defer { run.mu.unlock() }
	if current := run.session {
		if voidptr(current) == voidptr(session) { run.session = none }
	}
}

pub fn (mut run Run) request_stop() {
	run.mu.@lock()
	defer { run.mu.unlock() }
	run.stopping = true
	if mut session := run.session {
		session.note_reason('stopped')
		session.request_stop()
	}
}

pub fn (mut run Run) wait(delay time.Duration) bool {
	deadline := time.now().add(delay)
	for !run.stopped() {
		remaining := deadline - time.now()
		if remaining <= 0 { return true }
		time.sleep(if remaining < 10 * time.millisecond { remaining } else { 10 * time.millisecond })
	}
	return false
}

pub fn (mut run Run) finished() bool {
	run.mu.@lock()
	defer { run.mu.unlock() }
	return run.done
}

pub fn (mut run Run) finish() {
	run.mu.@lock()
	defer { run.mu.unlock() }
	run.session = none
	run.stopping = true
	run.done = true
}

pub fn (mut run Run) wait_finished() {
	for !run.finished() { time.sleep(time.millisecond) }
}

@[heap]
pub struct Registry {
mut:
	mu      sync.Mutex
	closed  bool
	runs    map[string]&Run
	blocked map[string]int
	paused  map[string]bool
}

pub fn (mut registry Registry) reserve(key string) ?&Run {
	registry.mu.@lock()
	defer { registry.mu.unlock() }
	if registry.closed || key == '' { return none }
	for prefix, paused in registry.paused {
		if paused && key.starts_with(prefix) { return none }
	}
	for prefix, count in registry.blocked {
		if count > 0 && key.starts_with(prefix) { return none }
	}
	if mut current := registry.runs[key] {
		if !current.finished() { return none }
	}
	mut run := &Run{}
	registry.runs[key] = run
	return run
}

// Teardown completes before removal; stale releases cannot erase a replacement.
pub fn (mut registry Registry) release(key string, mut run Run) {
	run.finish()
	registry.mu.@lock()
	defer { registry.mu.unlock() }
	if current := registry.runs[key] {
		if voidptr(current) == voidptr(&run) { registry.runs.delete(key) }
	}
}

fn (mut registry Registry) request_stops(prefix string, pause bool) &StopTicket {
	registry.mu.@lock()
	defer { registry.mu.unlock() }
	if pause { registry.paused[prefix] = true }
	registry.blocked[prefix]++
	mut stopped := []&Run{}
	for key, mut run in registry.runs {
		if key.starts_with(prefix) {
			run.request_stop()
			stopped << run
		}
	}
	return &StopTicket{ registry: &registry, prefix: prefix, runs: stopped }
}

pub fn (mut registry Registry) stop_prefix(prefix string) {
	mut stopped := registry.request_stops(prefix, false)
	stopped.wait()
}

// Separate notification from waiting so provider shutdown can notify all owners.
pub fn (mut registry Registry) request_pause(prefix string) &StopTicket {
	return registry.request_stops(prefix, true)
}

pub fn (mut registry Registry) pause_prefix(prefix string) {
	mut stopped := registry.request_pause(prefix)
	stopped.wait()
}

pub fn (mut registry Registry) resume_prefix(prefix string) bool {
	registry.mu.@lock()
	defer { registry.mu.unlock() }
	if registry.closed { return false }
	for blocked, count in registry.blocked {
		if count > 0 && (prefix.starts_with(blocked) || blocked.starts_with(prefix)) {
			return false
		}
	}
	registry.paused.delete(prefix)
	return true
}

// Notify all owners before waiting for any; shutdown permanently closes admission.
pub fn (mut registry Registry) request_shutdown() []&Run {
	registry.mu.@lock()
	defer { registry.mu.unlock() }
	registry.closed = true
	mut stopped := []&Run{}
	for _, mut run in registry.runs {
		run.request_stop()
		stopped << run
	}
	return stopped
}

// Final cleanup after the reader/writers join, including initial/reset TLS
// state when no TCP connection was published or the peer already closed it.
pub fn close_client(mut client websocket.Client) {
	client.dispose()
}
