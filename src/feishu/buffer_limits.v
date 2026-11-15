module feishu

pub const buffer_limit = 4096
pub const buffer_content_limit = 1024 * 1024
pub const buffer_ttl_ms = i64(30 * 60 * 1000)

pub fn (s &FeishuState) buffer_capacity_unlocked(message string, content string) bool {
	return message != '' && message.len <= 4096 && content.len <= buffer_content_limit
		&& (message in s.buffers || s.buffers.len < buffer_limit)
}

pub fn (mut s FeishuState) prune_expired_buffers_unlocked(now i64) []WireStreamRelease {
	mut released := []WireStreamRelease{}
	for message in s.buffers.keys() {
		buf := s.buffers[message] or { continue }
		if buf.finish != none || buf.rollover != none || buf.failure != none
			|| buf.bind_pending || buf.bridge_operation != none || buf.message_update != none { continue }
		last := if buf.last_delta > 0 { buf.last_delta } else { buf.last_flush }
		if last <= 0 || now < last || now - last < buffer_ttl_ms { continue }
		mut busy := false
		for _, peer in s.buffers {
			if peer.stream_id != buf.stream_id || peer.generation != buf.generation { continue }
			peer_last := if peer.last_delta > 0 { peer.last_delta } else { peer.last_flush }
			if peer_last > now - buffer_ttl_ms { busy = true; break }
			if peer.finish != none || peer.rollover != none || peer.failure != none
				|| peer.bind_pending || peer.bridge_operation != none || peer.message_update != none {
				busy = true
				break
			}
		}
		if busy { continue }
		if release := s.release_wire_stream_unlocked(message, buf.stream_id, buf.app, buf.generation) {
			released << release
		}
	}
	return released
}
