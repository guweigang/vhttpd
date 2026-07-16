module codex

import time

// ── ProviderRuntime state-transition methods ──

pub fn (mut rt ProviderRuntime) begin_turn_stream(stream_id string) string {
	thread_id := rt.current_thread_id()
	if thread_id != '' {
		rt.thread_stream_map[thread_id] = stream_id
	}
	rt.active_stream_id = stream_id
	rt.stream_map.delete(stream_id)
	return thread_id
}

pub fn (mut rt ProviderRuntime) add_stream_target(stream_id string, target CodexTarget) {
	rt.stream_map[stream_id] << target
}

pub fn (mut rt ProviderRuntime) remove_stream_target(stream_id string, platform string, message_id string) bool {
	if stream_id == '' {
		return false
	}
	targets := rt.stream_map[stream_id]
	if targets.len == 0 {
		return false
	}
	mut next := []CodexTarget{}
	mut removed := false
	for target in targets {
		if message_id != '' && target.message_id != message_id {
			next << target
			continue
		}
		if platform != '' && target.platform != platform {
			next << target
			continue
		}
		removed = true
	}
	if next.len == 0 {
		rt.stream_map.delete(stream_id)
	} else {
		rt.stream_map[stream_id] = next
	}
	return removed
}

pub fn (mut rt ProviderRuntime) clear_stream_targets(stream_id string) bool {
	if stream_id == '' {
		return false
	}
	if stream_id !in rt.stream_map {
		return false
	}
	rt.stream_map.delete(stream_id)
	if rt.active_stream_id == stream_id {
		rt.active_stream_id = ''
	}
	return true
}

pub fn (mut rt ProviderRuntime) clear_thread_binding(thread_id string) bool {
	if thread_id == '' {
		return false
	}
	mut cleared := false
	if thread_id in rt.thread_stream_map {
		rt.thread_stream_map.delete(thread_id)
		cleared = true
	}
	if rt.thread_id == thread_id {
		rt.thread_id = ''
		cleared = true
	}
	return cleared
}

pub fn (mut rt ProviderRuntime) note_frame_received() i64 {
	rt.received_frames++
	rt.last_frame_at_unix_ms = time.now().unix_milli()
	return rt.received_frames
}

pub fn (mut rt ProviderRuntime) schedule_read_fallback(stream_id string, thread_id string) ReadFallback {
	rt.read_fallback_seq++
	fallback := ReadFallback{
		token:                rt.read_fallback_seq
		stream_id:            stream_id
		thread_id:            thread_id
		scheduled_at_unix_ms: time.now().unix_milli()
	}
	rt.read_fallbacks[stream_id] = fallback
	return fallback
}

pub fn (mut rt ProviderRuntime) clear_read_fallback(stream_id string) bool {
	if stream_id == '' || stream_id !in rt.read_fallbacks {
		return false
	}
	rt.read_fallbacks.delete(stream_id)
	return true
}

pub fn (rt ProviderRuntime) read_fallback(stream_id string) (ReadFallback, bool) {
	if stream_id == '' || stream_id !in rt.read_fallbacks {
		return ReadFallback{}, false
	}
	return rt.read_fallbacks[stream_id], true
}

pub fn (mut rt ProviderRuntime) take_pending_rpc(id int) (PendingRpc, bool) {
	if id !in rt.pending_rpcs {
		return PendingRpc{}, false
	}
	pending := rt.pending_rpcs[id]
	rt.pending_rpcs.delete(id)
	return pending, true
}

pub fn (mut rt ProviderRuntime) capture_thread_id(thread_id string) bool {
	if thread_id == '' {
		return false
	}
	rt.thread_id = thread_id
	return true
}

pub fn (mut rt ProviderRuntime) ensure_thread_id(thread_id string) bool {
	if thread_id == '' || rt.thread_id != '' {
		return false
	}
	rt.thread_id = thread_id
	return true
}

pub fn (mut rt ProviderRuntime) repair_thread_stream_binding(thread_id string) string {
	if thread_id == '' {
		return ''
	}
	mut target_stream_id := rt.thread_stream_map[thread_id]
	current_stream_id := rt.current_stream_id()
	if target_stream_id == '' && current_stream_id != '' {
		target_stream_id = current_stream_id
		rt.thread_stream_map[thread_id] = target_stream_id
	}
	return target_stream_id
}

pub fn (rt ProviderRuntime) stream_targets(stream_id string) []CodexTarget {
	return rt.stream_map[stream_id].clone()
}

pub fn (rt ProviderRuntime) pending_stream_id() string {
	for _, p in rt.pending_rpcs {
		if p.stream_id != '' {
			return p.stream_id
		}
	}
	return ''
}

pub fn (mut rt ProviderRuntime) queue_error_burst(stream_id string, raw_payload string) bool {
	mut exists := false
	for msg in rt.err_bursts[stream_id] {
		if msg == raw_payload {
			exists = true
			break
		}
	}
	if !exists {
		rt.err_bursts[stream_id] << raw_payload
	}
	if rt.err_pending_flushes[stream_id] {
		return false
	}
	rt.err_pending_flushes[stream_id] = true
	return true
}

pub fn (mut rt ProviderRuntime) take_error_burst(stream_id string) []string {
	errors := rt.err_bursts[stream_id].clone()
	rt.err_bursts.delete(stream_id)
	rt.err_pending_flushes.delete(stream_id)
	return errors
}
