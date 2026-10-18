module executor

import time

fn (e InProcVjsxExecutor) reset_lane_host(idx int) {
	mut state := e.state
	state.mu.@lock()
	if idx < 0 || idx >= state.hosts.len {
		state.mu.unlock()
		return
	}
	lane_id := if idx < state.lanes.len { state.lanes[idx].id } else { '' }
	if owner := state.hosts[idx].wakeup_owner { state.retire_lane_wakeup_owner_locked(owner) }
	state.detach_task_session_locked(lane_id)
	mut stale := state.hosts[idx]
	state.hosts[idx] = VjsxLaneHost.empty()
	state.mu.unlock()
	stale.destroy()
}

pub fn (e InProcVjsxExecutor) close() {
	mut state := e.state
	state.mu.@lock()
	if state.stopping {
		state.mu.unlock()
		// Every concurrent closer observes completion of the same teardown.
		for {
			state.mu.@lock()
			closed := state.closed
			state.mu.unlock()
			if closed { return }
			time.sleep(time.millisecond)
		}
	}
	state.stopping = true
	state.signature_refresh_stop = true
	for _, owner in state.lane_wakeup_owners {
		mut retiring := unsafe { owner }
		retiring.retired = true
	}
	state.lane_wakeup_owners.clear()
	state.lane_wakeup_by_id.clear()
	mut workers := state.lane_workers.clone()
	refresh_started := state.signature_refresh_started
	mut refresh_thread := state.signature_refresh_thread
	mut cancelled := []InProcVjsxWebSocketTask{}
	for _, queue in state.websocket_mailbox_by_key { cancelled << queue }
	state.websocket_mailbox_by_key.clear()
	state.websocket_mailbox_pending_keys.clear()
	state.mu.unlock()
	for task in cancelled { e.cancel_websocket_task(task) }
	// Notify every worker before joining any one of them. Admission is closed,
	// so each worker can drain its finite queues without racing a new producer.
	for worker in workers {
		if worker.started { worker.stop_ch <- true }
	}
	// Workers finish all accepted queue entries before exiting.
	for mut worker in workers {
		if worker.started { worker.thread.wait() }
	}
	if refresh_started { refresh_thread.wait() }
	// Direct HTTP/plugin calls and schedulers also hold lanes outside worker threads.
	for {
		state.mu.@lock()
		mut busy := state.mailbox_schedulers > 0 || state.host_builders > 0 || state.lane_wakeup_workers > 0
		for lane in state.lanes { busy = busy || lane.inflight > 0 }
		state.mu.unlock()
		if !busy { break }
		time.sleep(time.millisecond)
	}
	mut stale_hosts := []VjsxLaneHost{}
	mut reset_hosts := []VjsxLaneHost{}
	state.mu.@lock()
	for i in 0 .. state.lane_workers.len { state.lane_workers[i].started = false }
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
	state.lane_wakeup_by_id = map[string]&VjsxLaneWakeup{}
	state.signature_refresh_stop = true
	state.signature_refresh_started = false
	state.cached_source_probe = ''
	state.cached_source_signature = ''
	state.signature_last_checked_at = 0
	state.signature_last_probe_at = 0
	state.signature_pending_since = 0
	state.signature_last_error = ''
	state.mu.unlock()
	for mut host in stale_hosts { host.destroy() }
	state.mu.@lock()
	state.websocket_mailbox_running_by_key.clear()
	state.websocket_affinity_lane_by_key.clear()
	state.websocket_affinity_ref_count_by_key.clear()
	state.websocket_connection_lane_by_id.clear()
	state.websocket_connection_affinity_key_by_id.clear()
	state.websocket_connection_actor_key_by_id.clear()
	state.websocket_connection_actor_class_by_id.clear()
	state.tasks.clear()
	state.active_task_by_lane.clear()
	state.app_ref = none
	state.closed = true
	state.mu.unlock()
}
