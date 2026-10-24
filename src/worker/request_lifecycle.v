module worker

pub fn (mut state WorkerState) request_started(socket_path string) bool {
	state.mu.@lock()
	defer { state.mu.unlock() }
	if state.backend_admission_error_unlocked() != '' { return false }
	idx := state.index_by_socket_unlocked(socket_path)
	if idx < 0 || idx >= state.worker_backend.managed_workers.len {
		return false
	}
	mut managed := state.worker_backend.managed_workers[idx]
	managed.inflight_requests++
	state.worker_backend.managed_workers[idx] = managed
	return true
}

pub fn (mut state WorkerState) request_released(socket_path string) bool {
	return state.complete_request(LifecyclePort{}, socket_path, none, false)
}

pub fn (mut state WorkerState) request_finished(port LifecyclePort, socket_path string) bool {
	return state.complete_request(port, socket_path, none, true)
}

fn (mut state WorkerState) complete_request(port LifecyclePort, socket_path string, expected ?&SlotGeneration, served bool) bool {
	mut max_request_fields := map[string]string{}
	state.mu.@lock()
	idx := state.index_by_socket_unlocked(socket_path)
	if idx < 0 || idx >= state.worker_backend.managed_workers.len {
		state.mu.unlock()
		return false
	}
	generation := state.slot_generation_unlocked(socket_path)
	if token := expected {
		if voidptr(token) != voidptr(generation) {
			state.mu.unlock()
			return false
		}
	}
	mut managed := state.worker_backend.managed_workers[idx]
	if managed.inflight_requests > 0 { managed.inflight_requests-- }
	if served { managed.served_requests++ }
	if served && state.worker_backend.max_requests > 0 && !managed.draining && managed.served_requests >= state.worker_backend.max_requests {
		managed.draining = true
		max_request_fields = {
			'worker_id':       '${managed.id}'
			'socket':          managed.socket_path
			'served_requests': '${managed.served_requests}'
			'max_requests':    '${state.worker_backend.max_requests}'
		}
	}
	state.worker_backend.managed_workers[idx] = managed
	should_restart := managed.draining && managed.inflight_requests == 0 && state.backend_admission_error_unlocked() == ''
	state.mu.unlock()
	if max_request_fields.len > 0 {
		port.emit_fn('worker.max_requests_reached', max_request_fields)
	}
	if should_restart {
		state.restart_slot_generation(port, idx, generation, if served {
			'max_requests_reached'
		} else {
			'drain_complete'
		})
	}
	return true
}
