module executor

import time

pub fn (e InProcVjsxExecutor) select_next_lane() !VjsxExecutionLane {
	if isnil(e.state) {
		return error('inproc_vjsx_executor_state_missing')
	}
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	if state.lanes.len == 0 {
		return error('inproc_vjsx_executor_no_lanes')
	}
	for offset in 0 .. state.lanes.len {
		idx := (state.rr_index + offset) % state.lanes.len
		if state.lanes[idx].inflight > 0 {
			continue
		}
		if !state.lanes[idx].healthy && !state.lanes[idx].dirty {
			continue
		}
		state.lanes[idx].inflight++
		state.rr_index = (idx + 1) % state.lanes.len
		return state.lanes[idx]
	}
	return error('inproc_vjsx_executor_no_available_lane')
}

fn (e InProcVjsxExecutor) force_select_lane_by_id(lane_id string) !VjsxExecutionLane {
	if isnil(e.state) {
		return error('inproc_vjsx_executor_state_missing')
	}
	if lane_id.trim_space() == '' {
		return error('inproc_vjsx_executor_lane_id_missing')
	}
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	for idx, lane in state.lanes {
		if lane.id != lane_id {
			continue
		}
		state.lanes[idx].inflight++
		return state.lanes[idx]
	}
	return error('inproc_vjsx_executor_lane_not_found')
}

fn (e InProcVjsxExecutor) select_lane_by_id(lane_id string) !VjsxExecutionLane {
	if isnil(e.state) {
		return error('inproc_vjsx_executor_state_missing')
	}
	if lane_id.trim_space() == '' {
		return error('inproc_vjsx_executor_lane_id_missing')
	}
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	for idx, lane in state.lanes {
		if lane.id != lane_id {
			continue
		}
		if state.lanes[idx].inflight > 0 {
			return error('inproc_vjsx_executor_no_available_lane')
		}
		if !state.lanes[idx].healthy && !state.lanes[idx].dirty {
			return error('inproc_vjsx_executor_no_available_lane')
		}
		state.lanes[idx].inflight++
		state.rr_index = (idx + 1) % state.lanes.len
		return state.lanes[idx]
	}
	return error('inproc_vjsx_executor_lane_not_found')
}

pub fn (e InProcVjsxExecutor) acquire_next_lane(timeout_ms int) !VjsxExecutionLane {
	mut remaining_ms := if timeout_ms > 0 { timeout_ms } else { 0 }
	deadline := time.now().add(time.millisecond * remaining_ms)
	for {
		lane := e.select_next_lane() or {
			if err.msg() != 'inproc_vjsx_executor_no_available_lane' {
				return error(err.msg())
			}
			if remaining_ms <= 0 || time.now() >= deadline {
				return error(err.msg())
			}
			time.sleep(time.millisecond * inproc_vjsx_lane_wait_poll_ms)
			remaining_ms -= inproc_vjsx_lane_wait_poll_ms
			continue
		}
		return lane
	}
	return error('inproc_vjsx_executor_no_available_lane')
}

fn (e InProcVjsxExecutor) acquire_lane_by_id(lane_id string, timeout_ms int) !VjsxExecutionLane {
	mut remaining_ms := if timeout_ms > 0 { timeout_ms } else { 0 }
	deadline := time.now().add(time.millisecond * remaining_ms)
	for {
		lane := e.select_lane_by_id(lane_id) or {
			if err.msg() == 'inproc_vjsx_executor_lane_not_found' {
				return error(err.msg())
			}
			if err.msg() != 'inproc_vjsx_executor_no_available_lane' {
				return error(err.msg())
			}
			if remaining_ms <= 0 || time.now() >= deadline {
				return error(err.msg())
			}
			time.sleep(time.millisecond * inproc_vjsx_lane_wait_poll_ms)
			remaining_ms -= inproc_vjsx_lane_wait_poll_ms
			continue
		}
		return lane
	}
	return error('inproc_vjsx_executor_no_available_lane')
}

pub fn (e InProcVjsxExecutor) release_lane(lane_id string) {
	if isnil(e.state) || lane_id == '' {
		return
	}
	mut state := e.state
	state.mu.@lock()
	for i, lane in state.lanes {
		if lane.id != lane_id {
			continue
		}
		if state.lanes[i].inflight > 0 {
			state.lanes[i].inflight--
		}
		break
	}
	state.mu.unlock()
	e.try_schedule_websocket_mailboxes()
}

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
