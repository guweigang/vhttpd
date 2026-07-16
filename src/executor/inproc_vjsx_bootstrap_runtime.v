module executor

import log

pub fn (e InProcVjsxExecutor) warmup(mut app AppFacade) ! {
	e.remember_app(mut app)
	e.bootstrap_placeholder()!
	for lane in e.lane_snapshot() {
		log.debug('[vhttpd] warmup request begin lane=${lane.id}')
		e.request_lane_warmup(mut app, lane)!
		log.debug('[vhttpd] warmup request done lane=${lane.id}')
	}
}

pub fn (e InProcVjsxExecutor) bootstrap_placeholder() ! {
	if isnil(e.state) {
		return error('inproc_vjsx_executor_state_missing')
	}
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	if state.facade.bootstrapped {
		return
	}
	if state.lanes.len == 0 {
		state.facade.last_error = 'inproc_vjsx_executor_no_lanes'
		return error(state.facade.last_error)
	}
	if state.facade.config.app_entry.trim_space() == '' {
		state.facade.last_error = 'inproc_vjsx_executor_missing_app_entry'
		return error(state.facade.last_error)
	}
	if !state.signature_refresh_started {
		state.signature_refresh_started = true
		go InProcVjsxSignatureRefresh.loop(mut state)
	}
	state.facade.bootstrapped = true
	state.facade.last_error = ''
}
