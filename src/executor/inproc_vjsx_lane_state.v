module executor

pub fn (e InProcVjsxExecutor) record_lane_success(lane_id string) {
	if isnil(e.state) || lane_id == '' {
		return
	}
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
	if isnil(e.state) || lane_id == '' {
		return
	}
	mut state := e.state
	state.mu.@lock()
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
	if isnil(e.state) || lane_id == '' {
		return
	}
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
	if isnil(e.state) || lane_id == '' {
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
