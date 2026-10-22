module feishu

import time

fn test_creation_grant_is_server_issued_bound_and_one_use() {
	mut s := FeishuState{}
	generation := s.issue_wire_creation('stream', 'main') or { panic(err) }
	assert generation.generation != '' && generation.token != ''
	assert s.admit_wire_initial_creation('other', 'main', generation.generation, generation.token) == none
	assert s.admit_wire_initial_creation('stream', 'other', generation.generation, generation.token) == none
	claim := s.admit_wire_initial_creation('stream', '', generation.generation, generation.token) or { panic('valid grant rejected') }
	assert s.admit_wire_initial_creation('stream', 'main', generation.generation, generation.token) == none
	s.finish_initial_send(claim)
	assert s.admit_wire_initial_creation('stream', 'main', generation.generation, generation.token) == none
	assert s.creation_grants.len == 0
}

fn test_creation_clear_before_delivery_rejects_late_bind_and_send() {
	for bind in [false, true] {
		mut s := FeishuState{}
		generation := if bind {
			s.issue_wire_bind_creation('stream', 'main', 'message') or { panic(err) }
		} else {
			s.issue_wire_creation('stream', 'main') or { panic(err) }
		}
		s.mu.@lock()
		released := s.release_wire_stream_unlocked('', 'stream', 'main', generation.generation) or { panic('pending grant not revoked') }
		assert released.retire_route && released.message_ids.len == 0
		assert !s.admit_wire_bind_unlocked('message', 'stream', 'main', '', generation.generation, generation.token)
		s.mu.unlock()
		assert s.admit_wire_initial_creation('stream', 'main', generation.generation, generation.token) == none
		assert bind || s.buffers.len == 0
	}
}

fn test_creation_replay_after_bind_and_clear_cannot_rebuild_old_target() {
	mut s := FeishuState{}
	generation := s.issue_wire_bind_creation('stream', 'main', 'message') or { panic(err) }
	s.mu.@lock()
	assert s.admit_wire_bind_unlocked('message', 'stream', 'main', '', generation.generation, generation.token)
	s.register_stream_buffer_unlocked('message', 'stream', 'main', '', '', '')
	bound := s.stream_generation_unlocked('message')
	_ := s.release_wire_stream_unlocked('message', 'stream', 'main', bound) or { panic('clear failed') }
	assert !s.admit_wire_bind_unlocked('message', 'stream', 'main', '', generation.generation, generation.token)
	s.mu.unlock()
	assert s.admit_wire_initial_creation('stream', 'main', generation.generation, generation.token) == none
	assert s.creation_grants.len == 0
}

fn test_creation_replay_after_send_completion_and_withdrawal_is_rejected() {
	mut s := FeishuState{}
	generation := s.issue_wire_creation('stream', 'main') or { panic(err) }
	claim := s.admit_wire_initial_creation('stream', 'main', generation.generation, generation.token) or { panic('grant rejected') }
	s.mu.@lock()
	assert s.commit_initial_send_generation_unlocked(claim, 'message', 'main', '', '', '', generation.generation)
	_ := s.release_wire_stream_unlocked('', 'stream', 'main', generation.generation) or { panic('clear failed') }
	s.mu.unlock()
	s.finish_initial_send(claim)
	assert s.admit_wire_initial_creation('stream', 'main', generation.generation, generation.token) == none
	fresh := s.issue_wire_creation('stream', 'main') or { panic(err) }
	assert fresh.generation != generation.generation && fresh.token != generation.token
	assert s.admit_wire_initial_creation('stream', 'main', generation.generation, generation.token) == none
	current := s.admit_wire_initial_creation('stream', 'main', fresh.generation, fresh.token) or { panic('fresh grant rejected') }
	s.finish_initial_send(current)
}

fn test_creation_expiry_and_capacity_fail_closed_without_eviction() {
	mut s := FeishuState{}
	now := time.now().unix()
	expired := s.issue_wire_creation_unlocked('expired', 'main', '', now - creation_lifetime_seconds) or { panic(err) }
	assert s.admit_wire_initial_creation('expired', 'main', expired.generation, expired.token) == none
	mut first := CreationLease{}
	for i in 0 .. creation_limit {
		id := s.issue_wire_creation_unlocked('stream-${i}', 'main', '', now) or { panic(err) }
		if i == 0 { first = id }
	}
	if _ := s.issue_wire_creation('overflow', 'main') {
		assert false
	}
	assert s.creation_grants.len == creation_limit
	claim := s.admit_wire_initial_creation('stream-0', 'main', first.generation, first.token) or { panic('capacity evicted a live grant') }
	s.finish_initial_send(claim)
	assert s.creation_grants.len == creation_limit - 1
	assert s.admit_wire_initial_creation('expired', 'main', expired.generation, expired.token) == none
}

fn test_creation_trusted_replacement_and_clear_fence_outstanding_grants() {
	mut s := FeishuState{}
	generation := s.issue_wire_creation('stream', 'main') or { panic(err) }
	s.register_stream_buffer('message', 'stream', 'main', '', '', '')
	s.clear_buffer('message')
	assert s.admit_wire_initial_creation('stream', 'main', generation.generation, generation.token) == none
	fresh := s.issue_wire_creation('stream', 'main') or { panic(err) }
	s.clear_stream_buffers('stream')
	assert s.admit_wire_initial_creation('stream', 'main', fresh.generation, fresh.token) == none
}

fn test_creation_wrong_clear_does_not_revoke_authority_or_reissue_it() {
	mut s := FeishuState{}
	generation := s.issue_wire_creation('stream', 'main') or { panic(err) }
	s.mu.@lock()
	assert s.release_wire_stream_unlocked('', 'stream', 'other', generation.generation) == none
	assert s.release_wire_stream_unlocked('missing', 'stream', 'main', generation.generation) == none
	s.mu.unlock()
	peer := s.issue_wire_creation('stream', 'main') or { panic(err) }
	assert peer.generation == generation.generation && peer.token != generation.token
	claim := s.admit_wire_initial_creation('stream', 'main', generation.generation, generation.token) or { panic('wrong clear consumed grant') }
	s.finish_initial_send(claim)
}

fn test_creation_restart_and_bridge_mirror_reject_unknown_generations() {
	mut remote := FeishuState{}
	mut local := FeishuState{}
	generation := remote.issue_wire_creation('stream', 'main') or { panic(err) }
	assert local.admit_wire_initial_creation('stream', 'main', generation.generation, generation.token) == none
	issue := local.begin_creation_issue('stream', 'main') or { panic(err) }
	local.complete_creation_issue(issue, generation) or { panic(err) }
	left := local.admit_wire_initial_creation('stream', 'main', generation.generation, generation.token) or { panic('mirror rejected') }
	right := remote.admit_wire_initial_creation('stream', 'main', generation.generation, generation.token) or { panic('authority rejected') }
	assert local.admit_wire_initial_creation('stream', 'main', generation.generation, generation.token) == none
	assert remote.admit_wire_initial_creation('stream', 'main', generation.generation, generation.token) == none
	local.finish_initial_send(left)
	remote.finish_initial_send(right)
	mut restarted := FeishuState{}
	assert restarted.admit_wire_initial_creation('stream', 'main', generation.generation, generation.token) == none
}

fn test_creation_parallel_authorized_sends_share_generation_but_not_tokens() {
	mut s := FeishuState{}
	one := s.issue_wire_creation('stream', 'main') or { panic(err) }
	two := s.issue_wire_creation('stream', 'main') or { panic(err) }
	assert one.generation == two.generation && one.token != two.token
	a := s.admit_wire_initial_creation('stream', 'main', one.generation, one.token) or { panic('first rejected') }
	b := s.admit_wire_initial_creation('stream', 'main', two.generation, two.token) or { panic('peer rejected') }
	s.mu.@lock()
	assert s.commit_initial_send_generation_unlocked(b, 'two', 'main', '', '', '', two.generation)
	assert s.commit_initial_send_generation_unlocked(a, 'one', 'main', '', '', '', one.generation)
	s.mu.unlock()
	s.finish_initial_send(a)
	s.finish_initial_send(b)
	assert s.buffers.len == 2
}

fn test_creation_last_target_clear_revokes_unspent_peer_tickets() {
	mut s := FeishuState{}
	one := s.issue_wire_creation('stream', 'main') or { panic(err) }
	two := s.issue_wire_creation('stream', 'main') or { panic(err) }
	a := s.admit_wire_initial_creation('stream', 'main', one.generation, one.token) or { panic('first rejected') }
	s.mu.@lock()
	assert s.commit_initial_send_generation_unlocked(a, 'one', 'main', '', '', '', one.generation)
	s.mu.unlock()
	s.finish_initial_send(a)
	s.mu.@lock()
	_ := s.release_wire_stream_unlocked('one', 'stream', 'main', one.generation) or { panic('clear failed') }
	s.mu.unlock()
	assert s.admit_wire_initial_creation('stream', 'main', two.generation, two.token) == none
	assert s.creation_grants.len == 0
}

fn test_creation_late_bridge_issuance_cannot_restore_revoked_authority() {
	for bound in [false, true] {
		mut s := FeishuState{}
		mut remote := FeishuState{}
		old := s.issue_wire_creation('stream', 'main') or { panic(err) }
		if bound {
			claim := s.admit_wire_initial_creation('stream', 'main', old.generation, old.token) or { panic('admission failed') }
			s.mu.@lock()
			assert s.commit_initial_send_generation_unlocked(claim, 'message', 'main', '', '', '', old.generation)
			s.mu.unlock()
			s.finish_initial_send(claim)
		}
		issue := s.begin_creation_issue('stream', 'main') or { panic(err) }
		s.mu.@lock()
		_ := s.release_wire_stream_unlocked('', 'stream', 'main', old.generation) or { panic('clear failed') }
		s.mu.unlock()
		late := remote.issue_wire_creation('stream', 'main') or { panic(err) }
		if _ := s.complete_creation_issue(issue, late) {
			assert false
		}
		assert s.creation_grants.len == 0 && s.creation_issues.len == 0
		assert s.admit_wire_initial_creation('stream', 'main', late.generation, late.token) == none
	}
}

fn test_creation_remote_issuance_completion_is_single_owner_and_expiring() {
	mut s := FeishuState{}
	mut remote := FeishuState{}
	issue := s.begin_creation_issue('stream', 'main') or { panic(err) }
	lease := remote.issue_wire_creation('stream', 'main') or { panic(err) }
	s.complete_creation_issue(issue, lease) or { panic(err) }
	claim := s.admit_wire_initial_creation('stream', 'main', lease.generation, lease.token) or { panic('mirror failed') }
	s.finish_initial_send(claim)
	if _ := s.complete_creation_issue(issue, lease) {
		assert false
	}
	expired := s.begin_creation_issue('expired', 'main') or { panic(err) }
	old := s.creation_issues[expired.id]
	s.creation_issues[expired.id] = CreationGrant{ ...old, expires_at: time.now().unix() - 1 }
	if _ := s.complete_creation_issue(expired, lease) {
		assert false
	}
	assert s.creation_issues.len == 0
}

fn test_creation_failure_withdrawal_retires_tickets_without_revoking_admitted_peers() {
	for admit_peer in [false, true] {
		mut s := FeishuState{}
		s.register_stream_buffer('message', 'stream', 'main', '', '', '')
		generation := s.buffers['message'].generation
		command := s.admit_wire_stream_command('message', 'stream', 'main', generation) or { panic('missing command') }
		old := s.issue_wire_creation('stream', 'main') or { panic(err) }
		failure := s.begin_stream_failure(command) or { panic('missing failure') }
		assert s.admit_wire_initial_creation('stream', 'main', old.generation, old.token) == none
		fresh := s.issue_wire_creation('stream', 'main') or { panic(err) }
		if admit_peer {
			peer := s.admit_wire_initial_creation('stream', 'main', fresh.generation, fresh.token) or { panic('peer rejected') }
			assert s.finish_stream_failure(failure)
			s.mu.@lock()
			assert s.commit_initial_send_generation_unlocked(peer, 'peer', 'main', '', '', '', fresh.generation)
			s.mu.unlock()
			s.finish_initial_send(peer)
			assert 'peer' in s.buffers
		} else {
			issue := s.begin_creation_issue('stream', 'main') or { panic(err) }
			assert s.finish_stream_failure(failure)
			assert s.admit_wire_initial_creation('stream', 'main', fresh.generation, fresh.token) == none
			assert s.creation_grants.len == 0 && s.creation_issues.len == 0
			if _ := s.complete_creation_issue(issue, fresh) {
				assert false
			}
		}
	}
}

fn test_creation_first_bind_ticket_is_bound_to_physical_target_and_operation() {
	mut s := FeishuState{}
	lease := s.issue_wire_bind_creation('stream', 'main', 'message') or { panic(err) }
	assert s.admit_wire_initial_creation('stream', 'main', lease.generation, lease.token) == none
	s.mu.@lock()
	assert !s.admit_wire_bind_unlocked('other', 'stream', 'main', '', lease.generation, lease.token)
	assert s.admit_wire_bind_unlocked('message', 'stream', 'main', '', lease.generation, lease.token)
	s.mu.unlock()
	send := s.issue_wire_creation('stream', 'main') or { panic(err) }
	s.mu.@lock()
	assert !s.admit_wire_bind_unlocked('message', 'stream', 'main', '', send.generation, send.token)
	s.mu.unlock()
}

fn test_creation_cross_stream_rebind_and_withdrawal_retire_first_bind_ticket() {
	mut s := FeishuState{}
	old := s.issue_wire_bind_creation('old', 'main', 'message') or { panic(err) }
	s.register_stream_buffer('message', 'replacement', 'main', '', '', '')
	s.clear_buffer('message')
	s.mu.@lock()
	assert !s.admit_wire_bind_unlocked('message', 'old', 'main', '', old.generation, old.token)
	s.mu.unlock()
	fresh := s.issue_wire_bind_creation('old', 'main', 'message') or { panic(err) }
	assert fresh.token != old.token && fresh.generation != old.generation
	s.mu.@lock()
	assert !s.admit_wire_bind_unlocked('message', 'old', 'main', '', old.generation, old.token)
	assert s.admit_wire_bind_unlocked('message', 'old', 'main', '', fresh.generation, fresh.token)
	s.mu.unlock()
}

fn test_creation_message_clear_before_bind_delivery_revokes_only_valid_authority() {
	mut s := FeishuState{}
	lease := s.issue_wire_bind_creation('stream', 'main', 'message') or { panic(err) }
	peer := s.issue_wire_bind_creation('stream', 'main', 'peer') or { panic(err) }
	assert peer.generation != lease.generation
	s.mu.@lock()
	assert s.release_wire_stream_unlocked('message', 'foreign', 'main', lease.generation) == none
	released := s.release_wire_stream_unlocked('message', 'stream', 'main', lease.generation) or { panic('unbound target clear failed') }
	assert released.message_ids.len == 0 && !released.retire_route
	assert !s.admit_wire_bind_unlocked('message', 'stream', 'main', '', lease.generation, lease.token)
	assert s.admit_wire_bind_unlocked('peer', 'stream', 'main', '', peer.generation, peer.token)
	s.mu.unlock()
}

fn test_creation_late_bind_issuance_cannot_cross_physical_target_replacement() {
	mut s := FeishuState{}
	mut remote := FeishuState{}
	issue := s.begin_creation_issue_for_target('old', 'main', 'message') or { panic(err) }
	remote_lease := remote.issue_wire_bind_creation('old', 'main', 'message') or { panic(err) }
	s.register_stream_buffer('message', 'new', 'main', '', '', '')
	s.clear_buffer('message')
	if _ := s.complete_creation_issue(issue, remote_lease) {
		assert false
	}
	assert s.creation_grants.len == 0 && s.creation_issues.len == 0
}
