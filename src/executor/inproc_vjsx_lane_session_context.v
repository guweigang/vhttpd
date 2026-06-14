module executor

import upstream.transport

fn (e InProcVjsxExecutor) activate_lane_request_context(idx int, mut app AppFacade, lane_id string, req HttpLogicDispatchRequest) {
	if isnil(e.state) || idx < 0 {
		return
	}
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	if idx >= state.hosts.len {
		return
	}
	normalized_path, _ := transport.WorkerHttpRequestCodec.normalize_request_target(req.path)
	state.hosts[idx].request_ctx = InProcVjsxRequestContext{
		active:     true
		app:        app
		lane_id:    lane_id
		request_id: req.request_id
		trace_id:   req.trace_id
		method:     req.method.to_upper()
		path:       normalized_path
	}
	state.hosts[idx].app_ref = app
}

fn (e InProcVjsxExecutor) clear_lane_request_context(idx int) {
	if isnil(e.state) || idx < 0 {
		return
	}
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	if idx >= state.hosts.len {
		return
	}
	state.hosts[idx].request_ctx = InProcVjsxRequestContext{}
}

pub fn (e InProcVjsxExecutor) pump_all_lane_sessions() ! {
	if isnil(e.state) {
		return
	}
	mut state := e.state
	state.mu.@lock()
	lanes := state.lanes.clone()
	state.mu.unlock()
	// WebSocket timers still live inside each lane-owned QuickJS session. Hosts
	// must explicitly pump them from the lane worker thread instead of touching
	// RuntimeSession from the caller thread.
	for lane in lanes {
		e.request_lane_pump(lane)!
	}
}
