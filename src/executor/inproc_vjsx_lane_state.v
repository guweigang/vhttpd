module executor

import application_logs

pub fn (e InProcVjsxExecutor) record_lane_success(lane_id string) {
	if lane_id == '' {
		return
	}
	maintain_inproc_vjsx_allocator(true)
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	for i, lane in state.lanes {
		if lane.id != lane_id {
			continue
		}
		state.lanes[i].served_requests++
		state.lanes[i].healthy = true
		state.lanes[i].dirty = false
		state.lanes[i].last_error = ''
		if i < state.hosts.len {
			state.hosts[i].dirty = false
		}
		break
	}
}

pub fn (e InProcVjsxExecutor) record_lane_error(lane_id string, err_msg string) {
	if lane_id == '' {
		return
	}
	maintain_inproc_vjsx_allocator(true)
	mut state := e.state
	state.mu.@lock()
	scope := state.application_log_scope
	mut logs := application_logs.shared()
	logs.append(scope,application_logs.Record{source:'console',level:'error',lane_id:lane_id,message:err_msg})
	defer {
		state.mu.unlock()
	}
	for i, lane in state.lanes {
		if lane.id != lane_id {
			continue
		}
		state.lanes[i].healthy = false
		state.lanes[i].dirty = true
		state.lanes[i].last_error = err_msg
		if i < state.hosts.len {
			state.hosts[i].dirty = true
		}
		break
	}
}

pub fn (e InProcVjsxExecutor) record_lane_soft_error(lane_id string, err_msg string) {
	if lane_id == '' {
		return
	}
	maintain_inproc_vjsx_allocator(true)
	normalized := InProcVjsxError.normalize_message(err_msg, 'inproc_vjsx_executor_unknown_error')
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	for i, lane in state.lanes {
		if lane.id != lane_id {
			continue
		}
		state.lanes[i].healthy = true
		state.lanes[i].dirty = false
		state.lanes[i].last_error = normalized
		if i < state.hosts.len {
			state.hosts[i].dirty = false
		}
		break
	}
}

pub fn (e InProcVjsxExecutor) lane_index_by_id(lane_id string) int {
	if lane_id == '' {
		return -1
	}
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	for i, lane in state.lanes {
		if lane.id == lane_id {
			return i
		}
	}
	return -1
}
