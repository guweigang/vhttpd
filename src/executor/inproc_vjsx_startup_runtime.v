module executor

import log
import time

fn (e InProcVjsxExecutor) run_lane_startup(mut app AppFacade, idx int, lane VjsxExecutionLane) ! {
	if isnil(e.state) {
		return error('inproc_vjsx_executor_state_missing')
	}
	mut should_run := false
	mut state := e.state
	state.mu.@lock()
	if idx >= 0 && idx < state.hosts.len && state.hosts[idx].initialized
		&& !state.hosts[idx].startup_completed {
		should_run = true
	}
	state.mu.unlock()
	if !should_run {
		return
	}
	e.execute_startup_hook(mut app, idx, lane, 'startup')!
	state.mu.@lock()
	if idx >= 0 && idx < state.hosts.len {
		state.hosts[idx].startup_completed = true
	}
	state.mu.unlock()
}

fn (e InProcVjsxExecutor) run_app_startup(mut app AppFacade, idx int, lane VjsxExecutionLane) ! {
	if isnil(e.state) {
		return error('inproc_vjsx_executor_state_missing')
	}
	mut source_signature := ''
	mut state := e.state
	state.mu.@lock()
	if idx >= 0 && idx < state.hosts.len {
		source_signature = state.hosts[idx].source_signature
	}
	if state.app_startup_source_signature != source_signature {
		state.app_startup_source_signature = source_signature
		state.app_startup_running = false
		state.app_startup_completed = false
		state.app_startup_last_error = ''
	}
	state.mu.unlock()
	for {
		state.mu.@lock()
		if state.app_startup_source_signature != source_signature {
			state.app_startup_source_signature = source_signature
			state.app_startup_running = false
			state.app_startup_completed = false
			state.app_startup_last_error = ''
		}
		if state.app_startup_completed {
			state.mu.unlock()
			return
		}
		if state.app_startup_running {
			state.mu.unlock()
			time.sleep(time.millisecond * inproc_vjsx_startup_wait_poll_ms)
			continue
		}
		state.app_startup_running = true
		state.app_startup_last_error = ''
		state.mu.unlock()
		e.execute_startup_hook(mut app, idx, lane, 'app_startup') or {
			state.mu.@lock()
			state.app_startup_running = false
			state.app_startup_completed = false
			state.app_startup_last_error = err.msg()
			state.mu.unlock()
			return error(err.msg())
		}
		state.mu.@lock()
		state.app_startup_running = false
		state.app_startup_completed = true
		state.app_startup_last_error = ''
		state.mu.unlock()
		return
	}
}

fn (e InProcVjsxExecutor) run_startup_hooks(mut app AppFacade, idx int, lane VjsxExecutionLane) ! {
	log.debug('[vhttpd] startup_hooks begin lane=${lane.id} idx=${idx}')
	e.run_lane_startup(mut app, idx, lane)!
	e.run_app_startup(mut app, idx, lane)!
	log.debug('[vhttpd] startup_hooks done lane=${lane.id} idx=${idx}')
}
