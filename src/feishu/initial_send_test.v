module feishu

fn initial_send_test_commit(mut state FeishuState, claim InitialSend, id string) bool {
	state.mu.@lock()
	defer { state.mu.unlock() }
	return state.commit_initial_send_unlocked(claim, id, 'main', 'chat', 'chat_id', 'content')
}

fn test_initial_send_revocation_without_buffer_and_fresh_generation() {
	mut state := FeishuState{}
	old := state.begin_initial_send('stream')
	state.clear_stream_buffers('stream')
	fresh := state.begin_initial_send('stream')
	state.finish_initial_send(old)
	assert !initial_send_test_commit(mut state, old, 'old')
	assert initial_send_test_commit(mut state, fresh, 'fresh')
	state.finish_initial_send(fresh)
	assert state.initial_send_scopes.len == 0
	assert state.initial_send_mutations.len == 0
	assert state.initial_send_count == 0
}

fn test_initial_send_copied_claim_releases_once_and_commit_is_one_shot() {
	mut state := FeishuState{}
	one := state.begin_initial_send('stream')
	two := state.begin_initial_send('stream')
	state.finish_initial_send(one)
	state.finish_initial_send(one)
	assert state.initial_send_count == 1
	assert initial_send_test_commit(mut state, two, 'two')
	assert !initial_send_test_commit(mut state, two, 'duplicate')
	state.finish_initial_send(two)
	assert state.initial_send_count == 0
	assert state.initial_send_scopes.len == 0
}

fn test_initial_send_result_id_rebind_and_delete_still_rejects_old_completion() {
	mut state := FeishuState{}
	old := state.begin_initial_send('old')
	state.register_stream_buffer('result', 'new', 'main', '', '', 'replacement')
	state.clear_buffer('result')
	assert state.buffers.len == 0
	assert !initial_send_test_commit(mut state, old, 'result')
	assert state.initial_send_mutations.len == 1
	state.finish_initial_send(old)
	assert state.initial_send_mutations.len == 0
}

fn test_initial_send_peer_completion_does_not_revoke_current_sends() {
	mut state := FeishuState{}
	one := state.begin_initial_send('stream')
	two := state.begin_initial_send('stream')
	assert initial_send_test_commit(mut state, two, 'two')
	state.finish_initial_send(two)
	assert initial_send_test_commit(mut state, one, 'one')
	state.finish_initial_send(one)
	assert state.buffers.len == 2
	assert state.initial_send_scopes.len == 0
	assert state.initial_send_mutations.len == 0
}

fn test_initial_send_all_release_paths_revoke_and_stale_clear_preserves_new_stream() {
	for mode in ['buffer', 'chain', 'stream'] {
		mut state := FeishuState{}
		state.register_stream_buffer('root', 'stream', 'main', '', '', '')
		claim := state.begin_initial_send('stream')
		match mode {
			'buffer' { state.clear_buffer('root') }
			'chain' { state.release_buffer_chain('root', 'stream') }
			else { state.clear_stream_buffers('stream') }
		}
		assert !initial_send_test_commit(mut state, claim, 'late')
		state.finish_initial_send(claim)
	}
	mut state := FeishuState{}
	state.register_stream_buffer('root', 'new', 'main', '', '', 'keep')
	claim := state.begin_initial_send('new')
	assert state.release_buffer_chain('root', 'old') == none
	assert initial_send_test_commit(mut state, claim, 'new-result')
	state.finish_initial_send(claim)
	assert state.buffers['root'].content == 'keep'
}

fn test_initial_send_message_only_withdrawal_and_empty_scope_leave_no_records() {
	mut state := FeishuState{}
	empty := state.begin_initial_send('')
	state.finish_initial_send(empty)
	assert state.initial_send_count == 0
	claim := state.begin_initial_send('stream')
	state.clear_buffer('future-id')
	assert !initial_send_test_commit(mut state, claim, 'future-id')
	assert initial_send_test_commit(mut state, claim, 'another-id')
	state.finish_initial_send(claim)
	assert state.initial_send_scopes.len == 0
	assert state.initial_send_mutations.len == 0
}

fn test_initial_send_foreign_state_cannot_commit_or_release_original_admission() {
	mut original := FeishuState{}
	mut foreign := FeishuState{}
	claim := original.begin_initial_send('stream')
	foreign.finish_initial_send(claim)
	assert foreign.initial_send_count == 0
	assert original.initial_send_count == 1
	assert !initial_send_test_commit(mut foreign, claim, 'foreign')
	assert initial_send_test_commit(mut original, claim, 'original')
	original.finish_initial_send(claim)
	assert original.initial_send_count == 0
	assert original.initial_send_scopes.len == 0
}
