module executor

import log
import time

fn (e InProcVjsxExecutor) run_lane_startup(mut app EmbeddedHost, idx int, lane VjsxExecutionLane) ! {
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
	e.execute_runtime_hook(mut app, idx, lane, 'startup', none)!
	state.mu.@lock()
	if idx >= 0 && idx < state.hosts.len {
		state.hosts[idx].startup_completed = true
	}
	state.mu.unlock()
}

fn (e InProcVjsxExecutor) run_app_startup(mut app EmbeddedHost, idx int, lane VjsxExecutionLane) ! {
	mut state := e.state
	for {
		state.mu.@lock()
		source_signature := state.hosts[idx].source_signature
		if state.stopping {
			state.mu.unlock()
			return error('inproc_vjsx_executor_closed')
		}
		// A lane prepared before a source refresh cannot replace the current
		// generation's startup state while waiting for another lane.
		if source_signature != state.cached_source_signature {
			state.mu.unlock()
			return
		}
		if state.app_startup_running {
			state.mu.unlock()
			time.sleep(time.millisecond * inproc_vjsx_startup_wait_poll_ms)
			continue
		}
		if state.app_startup_source_signature != source_signature {
			state.app_startup_source_signature = source_signature
			state.app_startup_completed = false
		}
		if state.app_startup_completed {
			state.mu.unlock()
			return
		}
		state.app_startup_running = true
		state.app_startup_last_error = ''
		state.mu.unlock()
		jobs := e.execute_runtime_hook(mut app, idx, lane, 'app_startup', none) or {
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
		if !state.stopping && state.cached_source_signature == source_signature {
			state.job_schedule = new_vjsx_job_schedule(source_signature, jobs)
		}
		state.app_startup_last_error = ''
		state.mu.unlock()
		return
	}
}

fn (e InProcVjsxExecutor) run_startup_hooks(mut app EmbeddedHost, idx int, lane VjsxExecutionLane) ! {
	log.debug('[vhttpd] startup_hooks begin lane=${lane.id} idx=${idx}')
	e.run_lane_startup(mut app, idx, lane)!
	e.run_app_startup(mut app, idx, lane)!
	log.debug('[vhttpd] startup_hooks done lane=${lane.id} idx=${idx}')
}
