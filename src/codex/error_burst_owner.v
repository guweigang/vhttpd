module codex

import connection_runtime
import sync
import time

// Aggregation is live task state, not part of copied ProviderRuntime snapshots.
@[heap]
pub struct ErrorBurstOwner {
mut:
	mu       sync.Mutex
	sequence u64
	pending  map[string]&ErrorBurstJob
}

@[heap]
pub struct ErrorBurstJob {
pub:
	instance  string
	stream_id string
	owner     &ErrorBurstOwner             @[required]
	registry  &connection_runtime.Registry @[required]
	run       &connection_runtime.Run      @[required]
	key       string
	run_key   string
mut:
	messages []string
}

// Reserve before spawn, using the same codex/ pause/shutdown boundary as the
// provider's network tasks. Return a job only for a newly scheduled burst.
pub fn (mut owner ErrorBurstOwner) enqueue(mut registry connection_runtime.Registry, instance string, stream_id string, payload string) ?&ErrorBurstJob {
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	resolved := ProviderRuntime.normalize_instance(instance)
	if stream_id.trim_space() == '' { return none }
	key := '${resolved.len}:${resolved}${stream_id}'
	if mut pending := owner.pending[key] {
		if voidptr(pending.registry) != voidptr(&registry) || pending.run.stopped() { return none }
		if payload !in pending.messages { pending.messages << payload }
		return none
	}
	owner.sequence++
	run_key := 'codex/error-burst/${voidptr(&owner)}/${owner.sequence}'
	run := registry.reserve(run_key) or { return none }
	job := &ErrorBurstJob{
		instance:  resolved
		stream_id: stream_id
		owner:     unsafe { &owner }
		registry:  unsafe { &registry }
		run:       run
		key:       key
		run_key:   run_key
		messages:  [payload]
	}
	owner.pending[key] = job
	return job
}

pub fn (job &ErrorBurstJob) wait(delay time.Duration) bool {
	mut run := job.run
	return run.wait(delay)
}

// Taking a burst linearizes dispatch against cancellation. A claimed callback
// may complete; its run remains registered until finish so stop still joins it.
pub fn (job &ErrorBurstJob) take() []string {
	mut owner := job.owner
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	current := owner.pending[job.key] or { return []string{} }
	if voidptr(current) != voidptr(job) || job.run.stopped() { return []string{} }
	owner.pending.delete(job.key)
	return job.messages.clone()
}

// Exact job identity prevents a stale timer/finalizer from touching a later
// burst for the same instance/stream. Registry release is idempotent too.
pub fn (job &ErrorBurstJob) finish() {
	mut owner := job.owner
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	if current := owner.pending[job.key] {
		if voidptr(current) == voidptr(job) { owner.pending.delete(job.key) }
	}
	mut registry := job.registry
	mut run := job.run
	registry.release(job.run_key, mut run)
}
