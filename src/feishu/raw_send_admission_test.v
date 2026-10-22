module feishu

fn test_raw_send_cannot_erase_scope_to_bypass_creation_or_revocation() {
	mut state := FeishuState{}
	mut owner := new_bridge_authority()
	lease := state.issue_wire_creation('stream', 'main') or { panic(err) }
	for stream in ['', ' ', '\t'] {
		assert state.admit_wire_initial_creation(stream, 'main', '', '') == none
		assert state.admit_wire_initial_creation(stream, 'main', lease.generation, lease.token) == none
		assert state.admit_bridge_initial_creation(owner, stream, 'main', '', '') == none
		assert !state.bridge_request_allowed(owner, 'send', stream, 'main', '', '')
	}
	state.revoke_wire_creation('stream', 'main', lease)
	assert state.admit_wire_initial_creation('stream', 'main', lease.generation, lease.token) == none
	assert state.admit_wire_initial_creation('', 'main', lease.generation, lease.token) == none
	assert state.buffers.len == 0 && state.initial_send_count == 0
}

fn test_raw_send_completion_cannot_replace_the_issued_generation() {
	mut state := FeishuState{}
	lease := state.issue_wire_creation('stream', 'main') or { panic(err) }
	claim := state.admit_wire_initial_creation('stream', 'main', lease.generation, lease.token) or { panic('admit') }
	state.mu.@lock()
	for generation in ['', 'wrong'] {
		assert !state.commit_initial_send_generation_unlocked(claim, 'message', 'main', '', '', 'old', generation)
		assert state.buffers.len == 0
	}
	assert state.commit_initial_send_generation_unlocked(claim, 'message', 'main', '', '', 'current', lease.generation)
	state.mu.unlock()
	state.finish_initial_send(claim)
	assert state.buffers['message'].generation == lease.generation
}
