module feishu

import time

@[heap]
struct BufferRolloverIdentity {}

// A claim retains metadata and identity, not ownership of the native HTTP call.
pub struct BufferRollover {
	token &BufferRolloverIdentity @[required]
pub:
	buffer        StreamBuffer
	content       string
	segment_index int
}

// Append or reserve exactly one successor send. Concurrent deltas accumulate
// behind the same claim. Existing links never authorize crossing stream owners.
pub fn (mut s FeishuState) append_buffer_patch(message_id string, app_name string, text string) ?BufferRollover {
	if message_id == '' { return none }
	s.mu.@lock()
	defer { s.mu.unlock() }
	if message_id !in s.buffers {
		s.buffers[message_id] = StreamBuffer{ message_id: message_id, app: app_name, last_flush: time.now().unix_milli(), segment_index: 1 }
	}
	root := s.buffers[message_id] or { return none }
	mut current := message_id
	mut visited := map[string]bool{}
	for current != '' {
		if current in visited { return none }
		visited[current] = true
		mut buf := s.buffer_snapshot_unlocked(current) or { return none }
		if buf.stream_id != root.stream_id || buf.app != root.app { return none }
		if !buf.sealed {
			buf.content += text
			buf.last_delta = time.now().unix_milli()
			s.buffers[current] = buf
			return none
		}
		if buf.next_message_id != '' {
			current = buf.next_message_id
			continue
		}
		if buf.receive_id.trim_space() == '' || buf.receive_id_type.trim_space() == '' {
			return none
		}
		buf.rollover_content += text
		if buf.rollover != none {
			s.buffers[current] = buf
			return none
		}
		token := &BufferRolloverIdentity{}
		buf.rollover = token
		s.buffers[current] = buf
		return BufferRollover{
			token:         token
			buffer:        buf
			content:       buf.rollover_content
			segment_index: if buf.segment_index > 0 {
				buf.segment_index + 1
			} else {
				2
			}
		}
	}
	return none
}

fn (claim BufferRollover) owns(active StreamBuffer) bool {
	token := active.rollover or { return false }
	return claim.buffer.same_identity(active) && voidptr(token) == voidptr(claim.token)
		&& active.sealed && active.next_message_id == ''
}

pub fn (mut s FeishuState) cancel_buffer_rollover(claim BufferRollover) bool {
	s.mu.@lock()
	defer { s.mu.unlock() }
	mut active := s.buffers[claim.buffer.message_id] or { return false }
	if !claim.owns(active) { return false }
	active.rollover = none
	// Keep unsent text for a later patch/retry; clearing the buffer still releases it.
	s.buffers[claim.buffer.message_id] = active
	return true
}

pub fn (mut s FeishuState) commit_buffer_rollover(claim BufferRollover, message_id string, now i64) bool {
	s.mu.@lock()
	defer { s.mu.unlock() }
	return s.commit_buffer_rollover_unlocked(claim, message_id, now)
}

// Caller holds FeishuState.mu. The root adapter publishes Codex target metadata
// before releasing this lock, so session clear cannot slip between publications.
pub fn (mut s FeishuState) commit_buffer_rollover_unlocked(claim BufferRollover, message_id string, now i64) bool {
	mut active := s.buffers[claim.buffer.message_id] or { return false }
	if !claim.owns(active) { return false }
	if message_id == '' || message_id in s.buffers {
		active.rollover = none
		s.buffers[claim.buffer.message_id] = active
		return false
	}
	s.buffers[message_id] = StreamBuffer{
		identity:         &StreamBufferIdentity{}
		message_id:       message_id
		app:              active.app
		content:          active.rollover_content
		rendered_content: claim.content
		last_delta:       now
		last_flush:       now
		stream_id:        active.stream_id
		receive_id:       active.receive_id
		receive_id_type:  active.receive_id_type
		segment_index:    claim.segment_index
	}
	active.next_message_id = message_id
	active.rollover = none
	active.rollover_content = ''
	s.buffers[claim.buffer.message_id] = active
	return true
}
