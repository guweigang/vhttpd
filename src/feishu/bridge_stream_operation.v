module feishu

@[heap]
struct BridgeStreamOperationIdentity {}

// Admission replicas retain lifecycle, not remote content/rollover topology.
// One request per physical mirror prevents same-generation ACK reordering.
pub struct BridgeStreamOperation {
	token &BridgeStreamOperationIdentity @[required]
	owner &StreamCommandOwner            @[required]
pub:
	buffer StreamBuffer
	source BridgeBinding
}

pub fn (mut s FeishuState) begin_bridge_stream_operation(command StreamCommand, require_owner bool) ?BridgeStreamOperation {
	s.mu.@lock()
	defer { s.mu.unlock() }
	mut buf := s.stream_command_snapshot_unlocked(command) or { return none }
	if buf.bridge_operation != none || (require_owner && buf.bridge_owner == none) { return none }
	token := &BridgeStreamOperationIdentity{}
	buf.bridge_replica = true
	buf.bridge_operation = token
	buf.identity = &StreamBufferIdentity{}
	s.buffers[buf.message_id] = buf
	return BridgeStreamOperation{
		token:  token
		owner:  command.owner
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

fn (s &FeishuState) bridge_stream_operation_matches_unlocked(op BridgeStreamOperation) bool {
	if voidptr(op.owner) != voidptr(s.stream_command_owner) { return false }
	buf := s.buffers[op.buffer.message_id] or { return false }
	token := buf.bridge_operation or { return false }
	identity := buf.identity or { return false }
	captured := op.buffer.identity or { return false }
	return voidptr(token) == voidptr(op.token) && voidptr(identity) == voidptr(captured)
		&& buf.generation == op.buffer.generation && buf.stream_id == op.buffer.stream_id && buf.app == op.buffer.app
}

pub fn (mut s FeishuState) abort_bridge_stream_operation_unlocked(op BridgeStreamOperation) ?WireStreamRelease {
	if !s.bridge_stream_operation_matches_unlocked(op) { return none }
	return s.release_wire_stream_unlocked(op.buffer.message_id, op.buffer.stream_id, op.buffer.app, op.buffer.generation)
}

pub fn valid_bridge_stream_result(action string, generation string, expected string, state string) bool {
	return generation != '' && generation == expected && if action == 'update' {
		state == 'message'
	} else if action == 'fail' {
		state == 'removed'
	} else {
		action in ['append', 'finish'] && state in ['open', 'sealed']
	}
}

// Caller holds Feishu.mu through any paired Codex withdrawal.
pub fn (mut s FeishuState) complete_bridge_stream_operation_unlocked(op BridgeStreamOperation, action string, generation string, state string) bool {
	if !valid_bridge_stream_result(action, generation, op.source.generation, state)
		|| !s.bridge_stream_operation_matches_unlocked(op) {
		return false
	}
	if owner := op.source.owner {
		if !bridge_authority_live(owner) { return false }
	}
	if op.buffer.sealed && state == 'open' { return false }
	if action == 'fail' { return true } // caller withdraws through abort under this lock
	mut buf := s.buffers[op.buffer.message_id] or { return false }
	buf.bridge_operation = none
	buf.sealed = state == 'sealed'
	if buf.sealed { buf.content = '' }
	s.buffers[buf.message_id] = buf
	return true
}
