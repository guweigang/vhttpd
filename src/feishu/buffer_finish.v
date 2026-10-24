module feishu

@[heap]
struct BufferFinishIdentity {}

// An end-of-stream send registration, independent of reusable message IDs.
pub struct BufferFinish {
	token &BufferFinishIdentity @[required]
pub:
	buffer StreamBuffer
}

pub fn (mut s FeishuState) begin_buffer_finish(captured StreamBuffer) ?BufferFinish {
	s.mu.@lock()
	defer { s.mu.unlock() }
	mut active := s.buffers[captured.message_id] or { return none }
	if active.bridge_replica || !captured.same_identity(active) || active.sealed || active.finish != none || active.failure != none || active.content != captured.content {
		return none
	}
	token := &BufferFinishIdentity{}
	active.finish = token
	s.buffers[captured.message_id] = active
	return BufferFinish{ token: token, buffer: captured }
}

fn (claim BufferFinish) matches(active StreamBuffer) bool {
	token := active.finish or { return false }
	return claim.buffer.same_identity(active) && voidptr(claim.token) == voidptr(token)
}

pub fn (mut s FeishuState) cancel_buffer_finish(claim BufferFinish) bool {
	s.mu.@lock()
	defer { s.mu.unlock() }
	mut active := s.buffers[claim.buffer.message_id] or { return false }
	if !claim.matches(active) { return false }
	active.finish = none
	s.buffers[claim.buffer.message_id] = active
	return true
}

pub fn (mut s FeishuState) buffer_finish_is_current(claim BufferFinish) bool {
	s.mu.@lock()
	defer { s.mu.unlock() }
	return s.buffer_finish_is_current_unlocked(claim)
}

// Caller holds FeishuState.mu across any paired target metadata publication.
pub fn (s &FeishuState) buffer_finish_is_current_unlocked(claim BufferFinish) bool {
	active := s.buffers[claim.buffer.message_id] or { return false }
	return claim.matches(active) && !active.sealed && active.content == claim.buffer.content
}

pub fn (mut s FeishuState) commit_buffer_finish_claim(claim BufferFinish, rendered string, segment_index int, now i64) bool {
	s.mu.@lock()
	defer { s.mu.unlock() }
	if !s.buffer_finish_is_current_unlocked(claim) { return false }
	return s.commit_buffer_finish_unlocked(claim.buffer, rendered, segment_index, now)
}
