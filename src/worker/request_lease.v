module worker

import connection_runtime
import net.unix
import sync

// A path can be reused. Its generation fences native dialing against retirement.
@[heap]
struct SlotGeneration {
mut:
	mu      sync.Mutex
	retired bool
}

fn (mut generation SlotGeneration) retire() {
	generation.mu.@lock()
	generation.retired = true
	generation.mu.unlock()
}

fn (mut state WorkerState) slot_generation_unlocked(path string) &SlotGeneration {
	if generation := state.slot_generations[path] { return generation }
	generation := &SlotGeneration{}
	state.slot_generations[path] = generation
	return generation
}

fn (mut state WorkerState) retire_slot_generation_unlocked(path string) {
	mut old := state.slot_generation_unlocked(path)
	old.retire()
	state.slot_generations[path] = &SlotGeneration{ retired: true }
}

fn (mut state WorkerState) publish_slot_generation_unlocked(path string) {
	// Replace, rather than reactivate, a retired identity.
	state.slot_generations[path] = &SlotGeneration{}
}

fn (state &WorkerState) slot_available_unlocked(path string) bool {
	if generation := state.slot_generations[path] {
		generation.mu.@lock()
		retired := generation.retired
		generation.mu.unlock()
		return !retired
	}
	return true
}

@[heap]
pub struct RequestLease {
pub:
	socket_path string
	state       &WorkerState    @[required]
	generation  &SlotGeneration @[required]
mut:
	mu        sync.Mutex
	completed bool
	dialed    bool
	done      chan bool = chan bool{}
}

// No WorkerState lock is acquired while holding the generation's dial fence.
pub fn (mut lease RequestLease) connect() !&unix.StreamConn {
	lease.mu.@lock()
	defer { lease.mu.unlock() }
	if lease.completed { return error('worker_request_lease_completed') }
	if lease.dialed { return error('worker_request_lease_connected') }
	lease.generation.mu.@lock()
	defer { lease.generation.mu.unlock() }
	if lease.generation.retired { return error('worker_slot_restarted') }
	conn := connection_runtime.dial_unix(lease.socket_path)!
	lease.dialed = true
	return conn
}

pub fn (mut lease RequestLease) release(port LifecyclePort) { lease.complete(port, false) }

pub fn (mut lease RequestLease) finish(port LifecyclePort) { lease.complete(port, true) }

fn (mut lease RequestLease) complete(port LifecyclePort, served bool) {
	lease.mu.@lock()
	if lease.completed {
		lease.mu.unlock()
		_ := <-lease.done
		return
	}
	lease.completed = true
	lease.mu.unlock()
	mut state := lease.state
	state.complete_request(port, lease.socket_path, lease.generation, served)
	lease.done.close()
}
