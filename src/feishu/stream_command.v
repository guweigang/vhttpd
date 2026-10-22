module feishu

@[heap]
struct StreamCommandOwner {}

@[heap]
struct StreamFailureIdentity {}

// Opaque local admission. An ID lookup cannot refresh its generation later.
pub struct StreamCommand {
	owner  &StreamCommandOwner @[required]
	buffer StreamBuffer
}

pub struct StreamAppendResult {
pub:
	rollover ?BufferRollover
}

pub struct StreamFailure {
	command StreamCommand
	token   &StreamFailureIdentity @[required]
}

pub fn (mut s FeishuState) admit_stream_command(message_id string, stream_id string, app_name string) ?StreamCommand {
	s.mu.@lock()
	defer { s.mu.unlock() }
	buf := s.buffer_snapshot_unlocked(message_id) or { return none }
	if owner := buf.bridge_owner {
		if !bridge_authority_live(owner) { return none }
	}
	if buf.message_only || buf.message_update != none || buf.bridge_operation != none || buf.bind_pending || buf.stream_id != stream_id || (app_name != '' && buf.app != app_name) || buf.failure != none {
		return none
	}
	return StreamCommand{ owner: s.stream_command_owner, buffer: buf }
}

// Wire admission never supplies a missing generation from the current registry.
pub fn (mut s FeishuState) admit_wire_stream_command(message_id string, stream_id string, app_name string, generation string) ?StreamCommand {
	s.mu.@lock()
	defer { s.mu.unlock() }
	buf := s.buffer_snapshot_unlocked(message_id) or { return none }
	if buf.message_only || buf.message_update != none || buf.bridge_operation != none || buf.bind_pending || generation == '' || generation != buf.generation || buf.stream_id != stream_id
		|| (app_name != '' && buf.app != app_name) || buf.failure != none {
		return none
	}
	return StreamCommand{ owner: s.stream_command_owner, buffer: buf }
}

// Caller holds mu while publishing the corresponding receipt/target.
pub fn (s &FeishuState) stream_generation_unlocked(message_id string) string {
	return (s.buffers[message_id] or { return '' }).generation
}

fn (s &FeishuState) stream_command_snapshot_unlocked(command StreamCommand) ?StreamBuffer {
	if voidptr(command.owner) != voidptr(s.stream_command_owner) { return none }
	active := s.buffers[command.buffer.message_id] or { return none }
	if !command.buffer.same_identity(active) || active.stream_id != command.buffer.stream_id
		|| active.app != command.buffer.app || active.failure != none {
		return none
	}
	return active
}

pub fn (mut s FeishuState) stream_command_snapshot(command StreamCommand) ?StreamBuffer {
	s.mu.@lock()
	defer { s.mu.unlock() }
	return s.stream_command_snapshot_unlocked(command)
}

pub fn (mut s FeishuState) append_stream_command(command StreamCommand, text string) !StreamAppendResult {
	s.mu.@lock()
	defer { s.mu.unlock() }
	buf := s.stream_command_snapshot_unlocked(command) or { return error('feishu_stream_command_retired') }
	mut linked := buf
	mut visited := map[string]bool{}
	for linked.sealed && linked.next_message_id != '' {
		if linked.message_id in visited { return error('feishu_stream_command_retired') }
		visited[linked.message_id] = true
		expected := linked.next_identity or { return error('feishu_stream_command_retired') }
		next := s.buffers[linked.next_message_id] or { return error('feishu_stream_command_retired') }
		actual := next.identity or { return error('feishu_stream_command_retired') }
		if voidptr(expected) != voidptr(actual) || next.app != buf.app || next.stream_id != buf.stream_id || next.failure != none {
			return error('feishu_stream_command_retired')
		}
		linked = next
	}
	return StreamAppendResult{ rollover: s.append_buffer_patch_unlocked(buf.message_id, buf.app, text) }
}

// Failure closes this generation's command admission and cancels its async
// publishers before HTTP. The original operation owns exact final cleanup.
pub fn (mut s FeishuState) begin_stream_failure(command StreamCommand) ?StreamFailure {
	s.mu.@lock()
	defer { s.mu.unlock() }
	mut active := s.stream_command_snapshot_unlocked(command) or { return none }
	token := &StreamFailureIdentity{}
	active.failure = token
	active.finish = none
	active.rollover = none
	s.revoke_creations_unlocked(active.stream_id)
	s.revoke_initial_sends_unlocked(active.stream_id)
	s.buffers[active.message_id] = active
	return StreamFailure{ command: command, token: token }
}

pub fn (mut s FeishuState) finish_stream_failure(claim StreamFailure) bool {
	s.mu.@lock()
	defer { s.mu.unlock() }
	return s.finish_stream_failure_release_unlocked(claim) != none
}

pub fn (mut s FeishuState) finish_stream_failure_release_unlocked(claim StreamFailure) ?WireStreamRelease {
	command := claim.command
	if voidptr(command.owner) != voidptr(s.stream_command_owner) { return none }
	active := s.buffers[command.buffer.message_id] or { return none }
	current := active.failure or { return none }
	if !command.buffer.same_identity(active) || active.app != command.buffer.app
		|| active.stream_id != command.buffer.stream_id || voidptr(current) != voidptr(claim.token) {
		return none
	}
	return s.release_wire_stream_unlocked(active.message_id, active.stream_id, active.app, active.generation)
}
