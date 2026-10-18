module process_runtime

import sync
import time

enum ShutdownPhase {
	idle
	stopping
	stopped
	failed
}

// One App owns the entire teardown. Other callers observe the same result.
@[heap]
pub struct ShutdownOwner {
mut:
	mu      sync.Mutex
	phase   ShutdownPhase
	message string
	starts  int
}

pub fn (mut owner ShutdownOwner) claim() bool {
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	if owner.phase != .idle { return false }
	owner.phase = .stopping
	return true
}

pub fn (mut owner ShutdownOwner) finish(message string) {
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	if owner.phase != .stopping { return }
	owner.message = message
	owner.phase = if message == '' { .stopped } else { .failed }
}

pub fn (mut owner ShutdownOwner) wait_stopped() ! {
	for {
		owner.mu.@lock()
		phase := owner.phase
		message := owner.message
		owner.mu.unlock()
		match phase {
			.idle { return error('app_shutdown_not_started') }
			.stopped { return }
			.failed { return error(message) }
			.stopping { time.sleep(time.millisecond) }
		}
	}
}

pub fn (mut owner ShutdownOwner) begin_start() bool {
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	if owner.phase != .idle { return false }
	owner.starts++
	return true
}

pub fn (mut owner ShutdownOwner) end_start() {
	owner.mu.@lock()
	owner.starts--
	owner.mu.unlock()
}

pub fn (mut owner ShutdownOwner) wait_started() {
	for {
		owner.mu.@lock()
		active := owner.starts > 0
		owner.mu.unlock()
		if !active { return }
		time.sleep(time.millisecond)
	}
}
