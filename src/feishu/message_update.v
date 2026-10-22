module feishu

@[heap]
struct MessageUpdateIdentity {}

// A whole-card update retains the original binding while replacing streaming
// content. Neither HTTP completion nor an ID lookup grants new ownership.
pub struct MessageUpdate {
	owner &StreamCommandOwner    @[required]
	token &MessageUpdateIdentity @[required]
pub:
	buffer StreamBuffer
	source BridgeBinding
}

pub fn (mut s FeishuState) admit_wire_message_update(message string, stream string, app string, generation string, bridge bool) ?MessageUpdate {
	s.mu.@lock()
	defer { s.mu.unlock() }
	return s.begin_message_update_unlocked(message, stream, app, generation, bridge)
}

pub fn (mut s FeishuState) admit_bridge_message_update(authority &BridgeAuthority, message string, stream string, app string, generation string) ?MessageUpdate {
	s.mu.@lock()
	defer { s.mu.unlock() }
	buf := s.buffers[message] or { return none }
	if !same_bridge_authority(buf.bridge_owner, authority) || !bridge_authority_live(authority) {
		return none
	}
	return s.begin_message_update_unlocked(message, stream, app, generation, false)
}

fn (mut s FeishuState) begin_message_update_unlocked(message string, stream string, app string, generation string, bridge bool) ?MessageUpdate {
	mut buf := s.buffer_snapshot_unlocked(message) or { return none }
	if stream == '' || generation == '' || buf.generation != generation || buf.stream_id != stream || creation_app(buf.app) != creation_app(app)
		|| buf.bind_pending || buf.failure != none || buf.bridge_operation != none || buf.message_update != none
		|| (bridge && (buf.bridge_owner == none || !buf.bridge_replica)) || (!bridge && buf.bridge_replica) {
		return none
	}
	if owner := buf.bridge_owner {
		if !bridge_authority_live(owner) { return none }
	}
	token := &MessageUpdateIdentity{}
	buf.message_update = token
	buf.finish = none
	buf.rollover = none
	// Old preview/finish/append snapshots cannot publish during or after the update.
	buf.identity = &StreamBufferIdentity{}
	s.buffers[message] = buf
	return MessageUpdate{
		owner:  s.stream_command_owner
		token:  token
		buffer: buf
		source: BridgeBinding{
			owner:      buf.bridge_owner
			generation: if buf.bridge_generation != '' {
				buf.bridge_generation
			} else {
				buf.generation
			}
			stream:     if buf.bridge_generation != '' { buf.bridge_stream } else { buf.stream_id }
			app:        if buf.bridge_generation != '' { buf.bridge_app } else { buf.app }
		}
	}
}

fn (s &FeishuState) message_update_current_unlocked(claim MessageUpdate) bool {
	if voidptr(claim.owner) != voidptr(s.stream_command_owner) { return false }
	active := s.buffers[claim.buffer.message_id] or { return false }
	token := active.message_update or { return false }
	identity := active.identity or { return false }
	captured := claim.buffer.identity or { return false }
	if voidptr(token) != voidptr(claim.token) || voidptr(identity) != voidptr(captured)
		|| active.generation != claim.buffer.generation || active.stream_id != claim.buffer.stream_id || active.app != claim.buffer.app
		|| active.bind_pending || active.failure != none {
		return false
	}
	if owner := active.bridge_owner {
		if !bridge_authority_live(owner) { return false }
	}
	return true
}

pub fn (mut s FeishuState) message_update_is_current(claim MessageUpdate) bool {
	s.mu.@lock()
	defer { s.mu.unlock() }
	return s.message_update_current_unlocked(claim)
}

pub fn (mut s FeishuState) cancel_message_update(claim MessageUpdate) bool {
	s.mu.@lock()
	defer { s.mu.unlock() }
	if !s.message_update_current_unlocked(claim) { return false }
	mut buf := s.buffers[claim.buffer.message_id] or { return false }
	buf.message_update = none
	s.buffers[buf.message_id] = buf
	return true
}

pub fn (mut s FeishuState) complete_message_update(claim MessageUpdate) bool {
	s.mu.@lock()
	defer { s.mu.unlock() }
	if !s.message_update_current_unlocked(claim) { return false }
	mut buf := s.buffers[claim.buffer.message_id] or { return false }
	buf.message_update = none
	buf.message_only = true
	buf.content = ''
	buf.rendered_content = ''
	buf.rollover_content = ''
	buf.sealed = true
	s.buffers[buf.message_id] = buf
	return true
}

pub fn valid_message_update_result(claim MessageUpdate, generation string, state string) bool {
	return generation != '' && generation == claim.source.generation && state == 'message'
}
