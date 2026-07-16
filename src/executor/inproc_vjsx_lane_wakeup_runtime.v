module executor

import time

fn (mut state VjsxExecutorState) schedule_lane_wakeup(lane_id string, wake_at_ms i64, generation u64) {
	if isnil(state) || lane_id.trim_space() == '' {
		return
	}
	state.mu.@lock()
	state.lane_wakeup_by_id[lane_id] = VjsxLaneWakeup{
		wake_at_ms: wake_at_ms
		generation: generation
	}
	state.mu.unlock()
	go state.deliver_lane_wakeup(lane_id, wake_at_ms, generation)
}

fn (mut state VjsxExecutorState) cancel_lane_wakeup(lane_id string, generation u64) {
	if isnil(state) || lane_id.trim_space() == '' {
		return
	}
	state.mu.@lock()
	current_wakeup := state.lane_wakeup_by_id[lane_id] or {
		state.mu.unlock()
		return
	}
	if current_wakeup.generation == generation {
		state.lane_wakeup_by_id.delete(lane_id)
	}
	state.mu.unlock()
}

fn (mut state VjsxExecutorState) deliver_lane_wakeup(lane_id string, wake_at_ms i64, generation u64) {
	if isnil(state) || lane_id.trim_space() == '' {
		return
	}
	delay_ms := wake_at_ms - time.now().unix_milli()
	if delay_ms > 0 {
		time.sleep(time.millisecond * int(delay_ms))
	}
	state.mu.@lock()
	current_wakeup := state.lane_wakeup_by_id[lane_id] or {
		state.mu.unlock()
		return
	}
	if current_wakeup.wake_at_ms != wake_at_ms || current_wakeup.generation != generation {
		state.mu.unlock()
		return
	}
	state.lane_wakeup_by_id.delete(lane_id)
	state.mu.unlock()
	lane_executor := InProcVjsxExecutor{
		state: unsafe { state }
	}
	lane := lane_executor.lane_snapshot_by_id(lane_id) or { return }
	lane_executor.request_lane_pump(lane) or {} // safe to ignore: lane shutdown in progress
}
