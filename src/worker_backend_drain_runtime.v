module main

import worker

struct EngineDrainStatus {
pub:
	engine            string
	worker_count      int
	draining_count    int
	inflight_requests i64
	ready_count       int
	changed           bool
}

fn (mut runtime EngineRuntime) drain_engine(kind string) !EngineDrainStatus {
	if kind == '' || kind == 'main' || kind == 'primary' || kind == runtime.primary_kind() {
		return drain_worker_state(mut runtime.primary, if kind == '' { 'main' } else { kind })
	}
	mut state := runtime.additional[kind] or { return error('unknown_executor_kind:${kind}') }
	return drain_worker_state(mut *state, kind)
}

fn (mut runtime EngineRuntime) engine_drain_status(kind string) !EngineDrainStatus {
	if kind == '' || kind == 'main' || kind == 'primary' || kind == runtime.primary_kind() {
		return worker_state_drain_status(mut runtime.primary,
			if kind == '' { 'main' } else { kind })
	}
	mut state := runtime.additional[kind] or { return error('unknown_executor_kind:${kind}') }
	return worker_state_drain_status(mut *state, kind)
}

fn (mut app App) drain_engine(kind string) !EngineDrainStatus {
	status := app.engines.drain_engine(kind)!
	app.emit('admin.worker.drain', {
		'engine':            status.engine
		'worker_count':      '${status.worker_count}'
		'draining_count':    '${status.draining_count}'
		'inflight_requests': '${status.inflight_requests}'
		'ready_count':       '${status.ready_count}'
		'changed':           '${status.changed}'
	})
	return status
}

fn (mut app App) engine_drain_status(kind string) !EngineDrainStatus {
	return app.engines.engine_drain_status(kind)
}

fn drain_worker_state(mut state worker.WorkerState, kind string) EngineDrainStatus {
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
	return EngineDrainStatus{
		engine:            kind
		worker_count:      state.worker_backend.managed_workers.len
		draining_count:    draining_count
		inflight_requests: inflight_requests
		ready_count:       ready_count
		changed:           changed
	}
}

fn worker_state_drain_status(mut state worker.WorkerState, kind string) EngineDrainStatus {
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
	return EngineDrainStatus{
		engine:            kind
		worker_count:      state.worker_backend.managed_workers.len
		draining_count:    draining_count
		inflight_requests: inflight_requests
		ready_count:       ready_count
		changed:           false
	}
}
