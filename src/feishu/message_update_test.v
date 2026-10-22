module feishu

import upstream

fn message_update_state() &FeishuState {
	mut s := &FeishuState{}
	s.register_stream_buffer('message', 'stream', 'main', 'chat', 'chat_id', 'queued')
	return s
}

fn test_message_update_admission_requires_live_exact_scope_generation_and_owner() {
	mut s := message_update_state()
	gen := s.buffers['message'].generation
	for args in [['', 'main', gen], ['other', 'main', gen], ['stream', 'other', gen],
		['stream', 'main', ''], ['stream', 'main', 'old']] {
		assert s.admit_wire_message_update('message', args[0], args[1], args[2], false) == none
	}
	assert s.admit_wire_message_update('missing', 'stream', 'main', gen, false) == none
	assert s.admit_wire_message_update('message', 'stream', 'main', gen, true) == none
	claim := s.admit_wire_message_update('message', 'stream', 'main', gen, false) or { panic('claim') }
	assert s.message_update_is_current(claim)
	assert s.admit_wire_message_update('message', 'stream', 'main', gen, false) == none
	assert s.cancel_message_update(claim)
	assert !s.cancel_message_update(claim)
}

fn test_message_update_cancels_old_stream_publishers_and_never_refreshes_them() {
	mut s := message_update_state()
	buf := s.buffer_snapshot('message') or { panic('snapshot') }
	old := s.admit_wire_stream_command('message', 'stream', 'main', buf.generation) or { panic('stream') }
	finish := s.begin_buffer_finish(buf) or { panic('finish') }
	claim := s.admit_wire_message_update('message', 'stream', 'main', buf.generation, false) or { panic('claim') }
	assert s.pending_buffer_snapshots(10000000000000).len == 0
	assert !s.buffer_finish_is_current(finish)
	assert !s.commit_buffer_preview(buf, 'late', 1000)
	assert s.stream_command_snapshot(old) == none
	assert s.admit_wire_stream_command('message', 'stream', 'main', buf.generation) == none
	assert s.cancel_message_update(claim)
	assert s.stream_command_snapshot(old) == none
	assert !s.cancel_buffer_finish(finish)
}

fn test_message_update_completion_preserves_binding_and_excludes_old_stream_content() {
	mut s := message_update_state()
	gen := s.buffers['message'].generation
	claim := s.admit_wire_message_update('message', 'stream', 'main', gen, false) or { panic('claim') }
	assert s.complete_message_update(claim)
	assert !s.complete_message_update(claim)
	assert !s.cancel_message_update(claim)
	assert s.buffers['message'].generation == gen
	assert s.buffers['message'].message_only
	assert s.buffers['message'].content == ''
	assert s.admit_wire_stream_command('message', 'stream', 'main', gen) == none
	assert s.append_buffer_patch('message', 'main', 'late') == none
	assert s.buffers['message'].content == ''
	next := s.admit_wire_message_update('message', 'stream', 'main', gen, false) or { panic('repeat update') }
	assert s.complete_message_update(next)
}

fn test_message_update_late_completion_and_failure_cannot_touch_rebound_or_recreated_same_id() {
	for mode in ['rebind', 'clear', 'recreate'] {
		mut s := message_update_state()
		claim := s.admit_wire_message_update('message', 'stream', 'main', s.buffers['message'].generation, false) or { panic('claim') }
		if mode != 'rebind' { s.clear_stream_buffers('stream') }
		if mode != 'clear' {
			s.register_stream_buffer('message', 'stream', 'main', 'chat', 'chat_id', 'replacement')
		}
		assert !s.message_update_is_current(claim)
		assert !s.complete_message_update(claim)
		assert !s.cancel_message_update(claim)
		if mode != 'clear' {
			assert s.buffers['message'].content == 'replacement'
			assert s.buffers['message'].generation != claim.buffer.generation
		}
	}
}

fn test_message_update_claims_cannot_cross_state_or_cancel_a_later_update() {
	mut first := message_update_state()
	mut other := message_update_state()
	claim := first.admit_wire_message_update('message', 'stream', 'main', first.buffers['message'].generation, false) or { panic('claim') }
	assert !other.complete_message_update(claim)
	assert first.cancel_message_update(claim)
	next := first.admit_wire_message_update('message', 'stream', 'main', claim.buffer.generation, false) or { panic('next') }
	assert !first.cancel_message_update(claim)
	assert first.message_update_is_current(next)
	assert first.complete_message_update(next)
}

fn test_message_update_bridge_connection_ownership_and_expiry_fence_receipts() {
	mut s := FeishuState{}
	mut owner := new_bridge_authority()
	other := new_bridge_authority()
	lease := s.issue_bridge_creation(mut owner, 'stream', 'main', 'message', 'intent') or { panic(err) }
	s.mu.@lock()
	gen := s.publish_bridge_bind_unlocked(owner, 'message', 'stream', 'main', '', 'stream', 'main', lease.generation, lease.token) or { panic('bind') }
	s.mu.unlock()
	assert s.admit_bridge_message_update(other, 'message', 'stream', 'main', gen) == none
	claim := s.admit_bridge_message_update(owner, 'message', 'stream', 'main', gen) or { panic('owner claim') }
	s.mu.@lock()
	_ := s.retire_bridge_authority_unlocked(mut owner)
	s.mu.unlock()
	assert !s.complete_message_update(claim)
	assert s.buffers.len == 0
}

fn test_message_update_bridge_proof_requires_captured_generation_and_message_state() {
	mut s := message_update_state()
	claim := s.admit_wire_message_update('message', 'stream', 'main', s.buffers['message'].generation, false) or { panic('claim') }
	for state in ['', 'open', 'sealed', 'removed'] {
		assert !valid_message_update_result(claim, claim.buffer.generation, state)
	}
	assert !valid_message_update_result(claim, '', 'message')
	assert !valid_message_update_result(claim, 'new-generation', 'message')
	assert valid_message_update_result(claim, claim.buffer.generation, 'message')
	assert valid_bridge_stream_result('update', claim.buffer.generation, claim.buffer.generation, 'message')
}

fn test_message_update_template_renders_captured_content_once_even_after_replacement() {
	for captured in ['', 'old {{content}} "quote"\nline\\end'] {
		req := UpdateMessageRequest.from_upstream_request(upstream.UpstreamSendRequest{
			metadata: {
				'feishu_update_captured_content': captured
			}
		})
		assert req.buffer_content_captured
		escaped := captured.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')
		assert req.render_buffer_content('prefix {{content}} suffix', 'new generation') == 'prefix ' + escaped + ' suffix'
	}
}
