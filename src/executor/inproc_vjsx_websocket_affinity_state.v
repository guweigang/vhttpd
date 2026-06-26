module executor

import log
import upstream.transport

pub fn (e InProcVjsxExecutor) release_websocket_connection_affinity(frame transport.WorkerWebSocketFrame) {
	if isnil(e.state) || frame.id.trim_space() == '' {
		return
	}
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	lane_id := state.websocket_connection_lane_by_id[frame.id] or { '' }
	affinity_key := state.websocket_connection_affinity_key_by_id[frame.id] or { '' }
	state.websocket_connection_lane_by_id.delete(frame.id)
	state.websocket_connection_affinity_key_by_id.delete(frame.id)
	if affinity_key == '' {
		return
	}
	if affinity_key in state.websocket_affinity_ref_count_by_key {
		mut remaining := state.websocket_affinity_ref_count_by_key[affinity_key] - 1
		if remaining <= 0 {
			state.websocket_affinity_ref_count_by_key.delete(affinity_key)
			if lane_id != '' && !WebSocketAffinityPolicy.should_pin_lane(frame, affinity_key) {
				state.websocket_affinity_lane_by_key.delete(affinity_key)
			}
			state.websocket_mailbox_by_key.delete(affinity_key)
			state.websocket_mailbox_running_by_key.delete(affinity_key)
			mut next_pending_keys := []string{}
			for key in state.websocket_mailbox_pending_keys {
				if key != affinity_key {
					next_pending_keys << key
				}
			}
			state.websocket_mailbox_pending_keys = next_pending_keys
		} else {
			state.websocket_affinity_ref_count_by_key[affinity_key] = remaining
		}
	}
}

pub fn (e InProcVjsxExecutor) release_websocket_affinity_key(affinity_key string) {
	if isnil(e.state) {
		return
	}
	key := affinity_key.trim_space()
	if key == '' {
		return
	}
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	if key in state.websocket_affinity_ref_count_by_key {
		mut remaining := state.websocket_affinity_ref_count_by_key[key] - 1
		if remaining <= 0 {
			state.websocket_affinity_ref_count_by_key.delete(key)
			state.websocket_mailbox_by_key.delete(key)
			state.websocket_mailbox_running_by_key.delete(key)
			mut next_pending_keys := []string{}
			for pending_key in state.websocket_mailbox_pending_keys {
				if pending_key != key {
					next_pending_keys << pending_key
				}
			}
			state.websocket_mailbox_pending_keys = next_pending_keys
		} else {
			state.websocket_affinity_ref_count_by_key[key] = remaining
		}
	}
}

pub fn (e InProcVjsxExecutor) migrate_websocket_connection_affinity(frame transport.WorkerWebSocketFrame, affinity_key string, current_lane_id string) {
	if isnil(e.state) || frame.id.trim_space() == '' {
		return
	}
	new_key := affinity_key.trim_space()
	if new_key == '' {
		return
	}
	mut state := e.state
	state.mu.@lock()
	defer {
		state.mu.unlock()
	}
	old_key := state.websocket_connection_affinity_key_by_id[frame.id] or { '' }
	if old_key == new_key {
		return
	}
	old_lane := state.websocket_connection_lane_by_id[frame.id] or { '' }
	if old_key != '' && old_key in state.websocket_affinity_ref_count_by_key {
		mut remaining := state.websocket_affinity_ref_count_by_key[old_key] - 1
		if remaining <= 0 {
			state.websocket_affinity_ref_count_by_key.delete(old_key)
			if old_lane != '' && !WebSocketAffinityPolicy.should_pin_lane(frame, old_key) {
				state.websocket_affinity_lane_by_key.delete(old_key)
			}
		} else {
			state.websocket_affinity_ref_count_by_key[old_key] = remaining
		}
	}
	mut new_lane := if old_lane != '' {
		old_lane
	} else {
		state.websocket_affinity_lane_by_key[new_key] or { '' }
	}
	if new_lane == '' && current_lane_id.trim_space() != ''
		&& WebSocketAffinityPolicy.should_pin_lane(frame, new_key) {
		new_lane = current_lane_id.trim_space()
	}
	state.websocket_connection_affinity_key_by_id[frame.id] = new_key
	if new_lane != '' {
		state.websocket_connection_lane_by_id[frame.id] = new_lane
		state.websocket_affinity_lane_by_key[new_key] = new_lane
	}
	state.websocket_affinity_ref_count_by_key[new_key] = (state.websocket_affinity_ref_count_by_key[new_key] or {
		0
	}) + 1
	log.debug('[vhttpd] websocket affinity migrated socket=${frame.id} request_id=${frame.request_id} old_key=${old_key} new_key=${new_key} lane=${new_lane}')
}
