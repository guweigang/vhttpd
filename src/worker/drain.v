module worker

pub struct DrainStatus {
pub:
	engine            string
	worker_count      int
	draining_count    int
	inflight_requests i64
	ready_count       int
	changed           bool
}

pub fn (mut state WorkerState) drain(kind string) DrainStatus {
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	mut draining_count := 0
	mut inflight_requests := i64(0)
	mut ready_count := 0
	mut changed := false
	for idx, managed in state.worker_backend.managed_workers {
		mut worker_item := managed
		if !worker_item.draining {
			worker_item.draining = true
			state.worker_backend.managed_workers[idx] = worker_item
			changed = true
		}
		if worker_item.draining {
			draining_count++
		}
		inflight_requests += worker_item.inflight_requests
		if worker_item.draining && worker_item.inflight_requests == 0 {
			ready_count++
		}
	}
	return DrainStatus{
		engine:            kind
		worker_count:      state.worker_backend.managed_workers.len
		draining_count:    draining_count
		inflight_requests: inflight_requests
		ready_count:       ready_count
		changed:           changed
	}
}

pub fn (mut state WorkerState) resume(kind string) DrainStatus {
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	mut inflight_requests := i64(0)
	mut changed := false
	for idx, managed in state.worker_backend.managed_workers {
		mut worker_item := managed
		if worker_item.draining {
			worker_item.draining = false
			state.worker_backend.managed_workers[idx] = worker_item
			changed = true
		}
		inflight_requests += worker_item.inflight_requests
	}
	return DrainStatus{
		engine:            kind
		worker_count:      state.worker_backend.managed_workers.len
		draining_count:    0
		inflight_requests: inflight_requests
		ready_count:       0
		changed:           changed
	}
}

pub fn (mut state WorkerState) drain_status(kind string) DrainStatus {
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	mut draining_count := 0
	mut inflight_requests := i64(0)
	mut ready_count := 0
	for worker_item in state.worker_backend.managed_workers {
		if worker_item.draining {
			draining_count++
		}
		inflight_requests += worker_item.inflight_requests
		if worker_item.draining && worker_item.inflight_requests == 0 {
			ready_count++
		}
	}
	return DrainStatus{
		engine:            kind
		worker_count:      state.worker_backend.managed_workers.len
		draining_count:    draining_count
		inflight_requests: inflight_requests
		ready_count:       ready_count
		changed:           false
	}
}
