module feishu

fn stream_command_state() &FeishuState {
	mut state := &FeishuState{}
	state.register_stream_buffer('message', 'stream', 'main', 'chat', 'chat_id', 'old')
	return state
}

fn test_stream_admission_requires_live_stream_and_app_and_keeps_current_deltas() {
	mut s := stream_command_state()
	assert s.admit_stream_command('missing', 'stream', 'main') == none
	assert s.admit_stream_command('message', 'old', 'main') == none
	assert s.admit_stream_command('message', '', 'main') == none
	assert s.admit_stream_command('message', 'stream', 'other') == none
	cmd := s.admit_stream_command('message', 'stream', 'main') or { panic('missing') }
	s.append_stream_command(cmd, ' one') or { panic(err) }
	s.append_stream_command(cmd, ' two') or { panic(err) }
	assert s.buffers['message'].content == 'old one two'
}

fn test_stream_admission_rejects_same_stream_rebind_clear_and_recreation() {
	for mode in ['rebind', 'clear', 'recreate'] {
		mut s := stream_command_state()
		cmd := s.admit_stream_command('message', 'stream', 'main') or { panic('missing') }
		if mode != 'rebind' { s.clear_buffer('message') }
		if mode != 'clear' { s.register_stream_buffer('message', 'stream', 'main', '', '', 'new') }
		assert s.stream_command_snapshot(cmd) == none
		assert s.begin_stream_failure(cmd) == none
		mut rejected := false
		s.append_stream_command(cmd, 'stale') or { rejected = true }
		assert rejected
		if mode != 'clear' {
			assert s.buffers['message'].content == 'new'
		}
	}
}

fn test_stream_failure_closes_admission_and_retires_only_original_generation() {
	mut s := stream_command_state()
	cmd := s.admit_stream_command('message', 'stream', 'main') or { panic('missing') }
	snapshot := s.buffer_snapshot('message') or { panic('missing') }
	fail := s.begin_stream_failure(cmd) or { panic('missing') }
	assert s.admit_stream_command('message', 'stream', 'main') == none
	assert s.begin_buffer_finish(snapshot) == none
	assert !s.commit_buffer_preview(snapshot, 'stale', 1000)
	assert s.pending_buffer_snapshots(9999999999999).len == 0
	assert s.append_buffer_patch('message', 'main', 'stale') == none
	s.register_stream_buffer('message', 'stream', 'main', '', '', '')
	assert s.buffers['message'].content == ''
	assert !s.finish_stream_failure(fail)
	assert s.admit_stream_command('message', 'stream', 'main') != none
}

fn test_stream_failure_cancels_previous_finish_and_rollover_claims() {
	for mode in ['finish', 'rollover'] {
		mut s := stream_command_state()
		cmd := s.admit_stream_command('message', 'stream', 'main') or { panic('missing') }
		if mode == 'finish' {
			snapshot := s.buffer_snapshot('message') or { panic('missing') }
			finish := s.begin_buffer_finish(snapshot) or { panic('missing') }
			fail := s.begin_stream_failure(cmd) or { panic('missing') }
			assert !s.buffer_finish_is_current(finish)
			assert !s.commit_buffer_finish_claim(finish, 'old', 1, 1000)
			assert s.finish_stream_failure(fail)
			assert !s.finish_stream_failure(fail)
		} else {
			s.buffers['message'].sealed = true
			rollover := s.append_buffer_patch('message', 'main', 'next') or { panic('missing') }
			fail := s.begin_stream_failure(cmd) or { panic('missing') }
			assert !s.commit_buffer_rollover(rollover, 'late', 1000)
			assert s.finish_stream_failure(fail)
		}
	}
}

fn test_stream_failure_cleanup_preserves_new_initial_send_scope() {
	mut s := stream_command_state()
	old := s.begin_initial_send('stream')
	cmd := s.admit_stream_command('message', 'stream', 'main') or { panic('missing') }
	fail := s.begin_stream_failure(cmd) or { panic('missing') }
	fresh := s.begin_initial_send('stream')
	assert s.finish_stream_failure(fail)
	s.mu.@lock()
	assert !s.commit_initial_send_unlocked(old, 'old', 'main', '', '', '')
	assert s.commit_initial_send_unlocked(fresh, 'fresh', 'main', '', '', 'fresh')
	s.mu.unlock()
	s.finish_initial_send(old)
	s.finish_initial_send(fresh)
	assert s.buffers['fresh'].content == 'fresh'
}

fn test_stream_admission_and_failure_reject_foreign_state() {
	mut one := stream_command_state()
	mut two := stream_command_state()
	cmd := one.admit_stream_command('message', 'stream', 'main') or { panic('missing') }
	assert two.stream_command_snapshot(cmd) == none
	assert two.begin_stream_failure(cmd) == none
	fail := one.begin_stream_failure(cmd) or { panic('missing') }
	assert !two.finish_stream_failure(fail)
	assert two.buffers['message'].content == 'old'
	assert one.finish_stream_failure(fail)
}

fn test_stream_append_cannot_follow_rebound_same_stream_successor() {
	mut s := stream_command_state()
	s.buffers['message'].sealed = true
	rollover := s.append_buffer_patch('message', 'main', 'next') or { panic('missing') }
	assert s.commit_buffer_rollover(rollover, 'next', 1000)
	cmd := s.admit_stream_command('message', 'stream', 'main') or { panic('missing') }
	s.append_stream_command(cmd, ' live') or { panic(err) }
	assert s.buffers['next'].content == 'next live'
	s.register_stream_buffer('next', 'stream', 'main', '', '', 'replacement')
	mut rejected := false
	s.append_stream_command(cmd, 'stale') or { rejected = true }
	assert rejected
	assert s.append_buffer_patch('message', 'main', 'also stale') == none
	assert s.buffers['next'].content == 'replacement'
}
