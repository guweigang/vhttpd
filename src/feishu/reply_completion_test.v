module feishu

import time

fn test_reply_completion_never_publishes_buffers_and_spends_once_without_clear() {
	mut s := FeishuState{}
	for i in 0 .. 100 {
		scope := 'feishu:reply:${i}'
		lease := s.issue_wire_creation(scope, 'main') or { panic(err) }
		claim := s.admit_wire_initial_creation(scope, 'main', lease.generation, lease.token) or { panic('admit') }
		s.mu.@lock()
		assert s.complete_initial_reply_unlocked(claim, 'physical-${i}', lease.generation)
		assert !s.complete_initial_reply_unlocked(claim, 'physical-${i}', lease.generation)
		s.mu.unlock()
		s.finish_initial_send(claim)
		s.finish_initial_send(claim)
		assert s.admit_wire_initial_creation(scope, 'main', lease.generation, lease.token) == none
	}
	assert s.buffers.len == 0
	assert s.creation_grants.len == 0
	assert s.initial_send_count == 0
	assert s.initial_send_scopes.len == 0
	assert s.initial_send_mutations.len == 0
}

fn test_reply_aborted_send_releases_admission_and_never_replays() {
	mut s := FeishuState{}
	lease := s.issue_wire_creation('feishu:reply:failed', 'main') or { panic(err) }
	claim := s.admit_wire_initial_creation('feishu:reply:failed', 'main', lease.generation, lease.token) or { panic('admit') }
	// The defer on HTTP failure/interruption only releases the original claim.
	s.finish_initial_send(claim)
	assert s.admit_wire_initial_creation('feishu:reply:failed', 'main', lease.generation, lease.token) == none
	assert s.buffers.len == 0 && s.initial_send_count == 0 && s.initial_send_scopes.len == 0
}

fn test_reply_late_completion_is_fenced_by_revoke_rebind_and_bridge_disconnect() {
	for mode in ['clear', 'rebind', 'disconnect', 'empty', 'wrong_generation'] {
		mut s := FeishuState{}
		mut authority := new_bridge_authority()
		lease := s.issue_bridge_creation(mut authority, 'feishu:reply:late', 'main', '', 'issue') or { panic(err) }
		claim := s.admit_bridge_initial_creation(authority, 'feishu:reply:late', 'main', lease.generation, lease.token) or { panic('admit') }
		if mode == 'clear' { s.clear_stream_buffers('feishu:reply:late') }
		if mode == 'disconnect' { s.retire_bridge_authority_unlocked(mut authority) }
		if mode == 'rebind' {
			s.register_stream_buffer('physical', 'new', 'main', 'chat', 'chat_id', 'new')
		}
		s.mu.@lock()
		message := if mode == 'empty' { '' } else { 'physical' }
		generation := if mode == 'wrong_generation' { 'wrong' } else { lease.generation }
		assert !s.complete_initial_reply_unlocked(claim, message, generation)
		s.mu.unlock()
		s.finish_initial_send(claim)
		assert s.initial_send_count == 0 && s.initial_send_scopes.len == 0
		assert s.buffers.len == if mode == 'rebind' { 1 } else { 0 }
	}
}

fn test_unsubmitted_reply_grants_expire_and_capacity_is_reclaimed_without_refresh() {
	mut s := FeishuState{}
	old := s.issue_wire_creation_unlocked('feishu:reply:lost', 'main', '', time.now().unix() - creation_lifetime_seconds) or { panic(err) }
	assert s.admit_wire_initial_creation('feishu:reply:lost', 'main', old.generation, old.token) == none
	fresh := s.issue_wire_creation('feishu:reply:fresh', 'main') or { panic(err) }
	assert s.creation_grants.len == 1
	assert s.admit_wire_initial_creation('feishu:reply:lost', 'main', old.generation, old.token) == none
	assert s.admit_wire_initial_creation('feishu:reply:fresh', 'main', fresh.generation, fresh.token) != none
}

fn test_completed_reply_fences_older_peer_send_and_bind_without_permanent_tombstones() {
	mut s := FeishuState{}
	old := s.issue_wire_creation('old-stream', 'main') or { panic(err) }
	peer := s.admit_wire_initial_creation('old-stream', 'main', old.generation, old.token) or { panic('peer') }
	bind := s.issue_wire_bind_creation('bind-stream', 'main', 'physical') or { panic(err) }
	reply := s.issue_wire_creation('feishu:reply:physical', 'main') or { panic(err) }
	claim := s.admit_wire_initial_creation('feishu:reply:physical', 'main', reply.generation, reply.token) or { panic('reply') }
	s.mu.@lock()
	assert s.complete_initial_reply_unlocked(claim, 'physical', reply.generation)
	assert !s.commit_initial_send_generation_unlocked(peer, 'physical', 'main', '', '', '', old.generation)
	assert !s.admit_wire_bind_unlocked('physical', 'bind-stream', 'main', '', bind.generation, bind.token)
	s.mu.unlock()
	s.finish_initial_send(claim)
	s.finish_initial_send(peer)
	assert s.buffers.len == 0 && s.creation_grants.len == 0
	assert s.initial_send_count == 0 && s.initial_send_mutations.len == 0
}
