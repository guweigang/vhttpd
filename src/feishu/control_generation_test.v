module feishu

fn test_wire_clear_requires_owner_and_preserves_foreign_pending_send() {
	mut s := FeishuState{}
	claim := s.begin_wire_initial_send('stream', 'main', 'pending') or { panic('missing') }
	s.register_stream_buffer('message', 'other', 'main', '', '', 'keep')
	// Registration above is for another stream and must not revoke this claim.
	s.mu.@lock()
	assert s.release_wire_stream_unlocked('message', 'stream', 'main', 'pending') == none
	assert s.release_wire_stream_unlocked('', 'stream', 'wrong-app', 'pending') == none
	assert s.release_wire_stream_unlocked('', 'stream', 'main', '') == none
	assert s.commit_initial_send_generation_unlocked(claim, 'result', 'main', '', '', '', 'pending')
	s.mu.unlock()
	s.finish_initial_send(claim)
	assert s.buffers['message'].content == 'keep'
}

fn test_wire_clear_pending_before_first_result_revokes_only_matching_generation() {
	mut s := FeishuState{}
	claim := s.begin_wire_initial_send('stream', 'main', 'first') or { panic('missing') }
	assert s.begin_wire_initial_send('stream', 'main', 'late') == none
	s.mu.@lock()
	assert s.release_wire_stream_unlocked('', 'stream', 'main', 'late') == none
	released := s.release_wire_stream_unlocked('', 'stream', 'main', 'first') or { panic('missing release') }
	assert released.message_ids.len == 0
	assert released.retire_route
	assert !s.commit_initial_send_generation_unlocked(claim, 'old', 'main', '', '', '', 'first')
	s.mu.unlock()
	current := s.begin_wire_initial_send('stream', 'main', 'second') or { panic('missing replacement') }
	s.finish_initial_send(claim)
	s.mu.@lock()
	assert s.release_wire_stream_unlocked('', 'stream', 'main', 'first') == none
	assert s.commit_initial_send_generation_unlocked(current, 'new', 'main', '', '', '', 'second')
	s.mu.unlock()
	s.finish_initial_send(current)
}

fn test_wire_clear_selects_only_captured_generation_and_app() {
	mut s := FeishuState{}
	for id in ['old', 'current', 'other-app'] {
		s.register_stream_buffer(id, 'stream', if id == 'other-app' { 'secondary' } else { 'main' }, '', '', id)
	}
	old := s.buffers['old'].generation
	s.mu.@lock()
	released := s.release_wire_stream_unlocked('', 'stream', 'main', old) or { panic('missing release') }
	s.mu.unlock()
	assert released.message_ids == ['old']
	assert !released.retire_route
	assert s.buffers.len == 2
	assert s.buffers['current'].content == 'current'
}

fn test_wire_clear_chain_stops_at_recreated_same_stream_successor() {
	mut s := FeishuState{}
	s.register_stream_buffer('root', 'stream', 'main', '', '', '')
	s.register_stream_buffer('child', 'stream', 'main', '', '', 'new')
	s.buffers['root'].next_message_id = 'child'
	generation := s.buffers['root'].generation
	s.mu.@lock()
	released := s.release_wire_stream_unlocked('root', 'stream', 'main', generation) or { panic('missing release') }
	s.mu.unlock()
	assert released.message_ids == ['root']
	assert !released.retire_route
	assert s.buffers['child'].content == 'new'
}

fn test_wire_initial_send_rejects_owned_stream_before_http_admission() {
	mut s := FeishuState{}
	s.register_stream_buffer('message', 'stream', 'main', '', '', 'keep')
	current := s.buffers['message'].generation
	assert s.begin_wire_initial_send('stream', 'main', 'old') == none
	assert s.begin_wire_initial_send('stream', 'main', '') == none
	claim := s.begin_wire_initial_send('stream', 'main', current) or { panic('missing current') }
	assert s.begin_wire_initial_send('stream', 'other', current) == none
	s.finish_initial_send(claim)
	assert s.buffers['message'].content == 'keep'
}

fn test_wire_bind_compare_and_replace_does_not_refresh_withdrawn_admission() {
	mut s := FeishuState{}
	s.mu.@lock()
	assert s.wire_bind_is_current_unlocked('message', '')
	s.register_stream_buffer_unlocked('message', 'stream', 'main', '', '', '')
	old := s.stream_generation_unlocked('message')
	assert !s.wire_bind_is_current_unlocked('message', '')
	assert s.wire_bind_is_current_unlocked('message', old)
	s.register_stream_buffer_unlocked('message', 'stream', 'main', '', '', '')
	assert !s.wire_bind_is_current_unlocked('message', old)
	s.mu.unlock()
	s.clear_buffer('message')
	s.mu.@lock()
	assert !s.wire_bind_is_current_unlocked('message', old)
	s.mu.unlock()
}

fn test_target_only_clear_preserves_peer_initial_send_of_the_same_generation() {
	mut s := FeishuState{}
	s.register_stream_buffer('root', 'stream', 'main', '', '', '')
	generation := s.buffers['root'].generation
	claim := s.begin_wire_initial_send('stream', 'main', generation) or { panic('missing peer') }
	s.mu.@lock()
	released := s.release_wire_stream_unlocked('root', 'stream', 'main', generation) or { panic('missing release') }
	assert !released.retire_route
	assert s.commit_initial_send_generation_unlocked(claim, 'peer', 'main', '', '', '', generation)
	s.mu.unlock()
	s.finish_initial_send(claim)
	assert s.buffers['peer'].generation == generation
}

fn test_legacy_chain_release_cannot_revoke_a_mismatched_owner_scope() {
	mut s := FeishuState{}
	s.register_stream_buffer('root', 'new', 'main', '', '', 'keep')
	claim := s.begin_wire_initial_send('old', 'main', 'pending') or { panic('missing') }
	assert s.release_buffer_chain('root', 'old') == none
	s.mu.@lock()
	assert s.commit_initial_send_generation_unlocked(claim, 'peer', 'main', '', '', '', 'pending')
	s.mu.unlock()
	s.finish_initial_send(claim)
	assert s.buffers['root'].content == 'keep'
}

fn test_clear_chain_does_not_follow_recreated_successor_even_with_same_wire_generation() {
	for wire in [false, true] {
		mut s := FeishuState{}
		s.register_stream_buffer('root', 'stream', 'main', '', '', '')
		s.register_stream_buffer('child', 'stream', 'main', '', '', '')
		generation := s.buffers['root'].generation
		s.buffers['child'].generation = generation
		s.buffers['root'].next_message_id = 'child'
		s.buffers['root'].next_identity = s.buffers['child'].identity
		// A replacement can belong to the same logical stream generation, but it
		// does not belong to the predecessor's captured physical buffer chain.
		s.register_stream_buffer('child', 'stream', 'main', '', '', 'replacement')
		s.buffers['child'].generation = generation
		if wire {
			s.mu.@lock()
			released := s.release_wire_stream_unlocked('root', 'stream', 'main', generation) or { panic('missing') }
			s.mu.unlock()
			assert released.message_ids == ['root']
		} else {
			released := s.release_buffer_chain('root', 'stream') or { panic('missing') }
			assert released.cleared == 1
		}
		assert s.buffers['child'].content == 'replacement'
	}
}
