module executor

import time

// A callback scope belongs to one host/session, even when its timer generation
// and lane ID are reused by a replacement. All mutable fields use state.mu.
@[heap]
struct VjsxLaneWakeupOwner {
	state   &VjsxExecutorState @[required]
	lane_id string
mut:
	retired   bool
	published bool
}

@[heap]
struct VjsxLaneWakeup {
	owner      &VjsxLaneWakeupOwner @[required]
	wake_at_ms i64
	generation u64
mut:
	finished bool
}

fn (mut state VjsxExecutorState) new_lane_wakeup_owner(lane_id string) !&VjsxLaneWakeupOwner {
	state.mu.@lock()
	defer { state.mu.unlock() }
	if state.stopping { return error('inproc_vjsx_executor_closed') }
	if lane_id.trim_space() == '' { return error('inproc_vjsx_executor_invalid_lane') }
	if old := state.lane_wakeup_owners[lane_id] { state.retire_lane_wakeup_owner_locked(old) }
	owner := &VjsxLaneWakeupOwner{ state: unsafe { &state }, lane_id: lane_id }
	state.lane_wakeup_owners[lane_id] = owner
	return owner
}

fn (mut state VjsxExecutorState) retire_lane_wakeup_owner_locked(owner &VjsxLaneWakeupOwner) {
	mut retired := unsafe { owner }
	retired.retired = true
	if current := state.lane_wakeup_owners[owner.lane_id] {
		if voidptr(current) == voidptr(owner) {
			state.lane_wakeup_owners.delete(owner.lane_id)
			state.lane_wakeup_by_id.delete(owner.lane_id)
		}
	}
}

fn (owner &VjsxLaneWakeupOwner) retire() {
	mut state := owner.state
	state.mu.@lock()
	defer { state.mu.unlock() }
	state.retire_lane_wakeup_owner_locked(owner)
}

// Reserve before spawn so close also waits for delayed task startup. Replacing
// a job invalidates its identity; identical time/generation values never alias.
fn (owner &VjsxLaneWakeupOwner) reserve(wake_at_ms i64, generation u64) ?&VjsxLaneWakeup {
	mut state := owner.state
	state.mu.@lock()
	defer { state.mu.unlock() }
	if state.stopping || owner.retired { return none }
	current := state.lane_wakeup_owners[owner.lane_id] or { return none }
	if voidptr(current) != voidptr(owner) { return none }
	job := &VjsxLaneWakeup{ owner: owner, wake_at_ms: wake_at_ms, generation: generation }
	state.lane_wakeup_by_id[owner.lane_id] = job
	state.lane_wakeup_workers++
	return job
}

fn (owner &VjsxLaneWakeupOwner) schedule(wake_at_ms i64, generation u64) {
	job := owner.reserve(wake_at_ms, generation) or { return }
	go job.deliver()
}

fn (owner &VjsxLaneWakeupOwner) cancel(generation u64) {
	mut state := owner.state
	state.mu.@lock()
	defer { state.mu.unlock() }
	if owner.retired { return }
	if job := state.lane_wakeup_by_id[owner.lane_id] {
		if voidptr(job.owner) == voidptr(owner) && job.generation == generation {
			state.lane_wakeup_by_id.delete(owner.lane_id)
		}
	}
}

// Called only while state.mu is held. Absence is explicit, with no dummy wakeup.
fn (job &VjsxLaneWakeup) current_locked() bool {
	state := job.owner.state
	if state.stopping || job.owner.retired || job.finished { return false }
	current := state.lane_wakeup_by_id[job.owner.lane_id] or { return false }
	return voidptr(current) == voidptr(job)
}

fn (job &VjsxLaneWakeup) claim() bool {
	mut state := job.owner.state
	state.mu.@lock()
	defer { state.mu.unlock() }
	if !job.current_locked() || !job.owner.published { return false }
	state.lane_wakeup_by_id.delete(job.owner.lane_id)
	return true
}

fn (mut job VjsxLaneWakeup) finish() {
	mut state := job.owner.state
	state.mu.@lock()
	defer { state.mu.unlock() }
	if job.finished { return }
	if current := state.lane_wakeup_by_id[job.owner.lane_id] {
		if voidptr(current) == voidptr(&job) { state.lane_wakeup_by_id.delete(job.owner.lane_id) }
	}
	job.finished = true
	state.lane_wakeup_workers--
}

fn (job &VjsxLaneWakeup) deliver() {
	mut active := unsafe { job }
	defer { active.finish() }
	mut state := job.owner.state
	for {
		state.mu.@lock()
		current := job.current_locked()
		published := job.owner.published
		state.mu.unlock()
		if !current { return }
		remaining := job.wake_at_ms - time.now().unix_milli()
		if remaining <= 0 && published { break }
		time.sleep(time.millisecond * if remaining > 0 && remaining < 10 { remaining } else { 10 })
	}
	if !job.claim() { return }
	exec := InProcVjsxExecutor{ state: state }
	lane := exec.lane_snapshot_by_id(job.owner.lane_id) or { return }
	exec.request_lane_pump_owned(lane, job.owner) or {} // stop closes task admission
}
