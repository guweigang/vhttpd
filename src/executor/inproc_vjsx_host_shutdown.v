module executor

fn (e InProcVjsxExecutor) reset_lane_host(idx int) {
	if isnil(e.state) {
		return
	}
	mut state := e.state
	state.mu.@lock()
	if idx < 0 || idx >= state.hosts.len {
		state.mu.unlock()
		return
	}
	lane_id := if idx < state.lanes.len { state.lanes[idx].id } else { '' }
	if lane_id != '' {
		state.lane_wakeup_by_id.delete(lane_id)
	}
	mut stale := state.hosts[idx]
	state.hosts[idx] = VjsxLaneHost.empty()
	state.mu.unlock()
	stale.destroy()
}

pub fn (e InProcVjsxExecutor) close() {
	if isnil(e.state) {
		return
	}
	mut stale_hosts := []VjsxLaneHost{}
	mut reset_hosts := []VjsxLaneHost{}
	mut state := e.state
	state.mu.@lock()
	for i in 0 .. state.lane_workers.len {
		if state.lane_workers[i].started {
			state.lane_workers[i].stop_ch <- true
			state.lane_workers[i].started = false
		}
	}
	stale_hosts = state.hosts.clone()
	for _ in 0 .. stale_hosts.len {
		reset_hosts << VjsxLaneHost.empty()
	}
	state.hosts = reset_hosts
	for i in 0 .. state.lanes.len {
		state.lanes[i].healthy = true
		state.lanes[i].dirty = false
		state.lanes[i].inflight = 0
		state.lanes[i].last_error = ''
	}
	state.rr_index = 0
	state.warmup_source_signature = ''
	state.warmup_running = false
	state.warmup_completed = false
	state.warmup_last_error = ''
	state.app_startup_source_signature = ''
	state.app_startup_running = false
	state.app_startup_completed = false
	state.app_startup_last_error = ''
	state.facade.bootstrapped = false
	state.facade.last_error = ''
	state.lane_wakeup_by_id = map[string]VjsxLaneWakeup{}
	state.signature_refresh_stop = true
	state.signature_refresh_started = false
	state.cached_source_probe = ''
	state.cached_source_signature = ''
	state.signature_last_checked_at = 0
	state.signature_last_probe_at = 0
	state.signature_pending_since = 0
	state.signature_last_error = ''
	state.mu.unlock()
	for mut host in stale_hosts {
		host.destroy()
	}
}
