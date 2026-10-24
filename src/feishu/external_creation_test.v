module feishu

import time

fn external_request(mut s FeishuState, id string, kind string, message_id string) ExternalCreationRequest {
	discovery := s.external_creation_discovery() or { panic(err) }
	return ExternalCreationRequest{ epoch: discovery.epoch, issued_at: discovery.issued_at, request_id: id.repeat(64), stream_id: 'stream', instance: 'main', kind: kind, message_id: message_id }
}

fn test_external_creation_replay_after_consumption_and_withdrawal_never_remints() {
	mut s := FeishuState{}
	req := external_request(mut s, 'a', 'send', '')
	first := s.begin_external_creation(req) or { panic(err) }
	if _ := s.begin_external_creation(req) {
		assert false
	}
	lease := s.complete_external_local(first) or { panic(err) }
	claim := s.admit_wire_initial_creation('stream', 'main', lease.generation, lease.token) or { panic('missing ticket') }
	s.mu.@lock()
	_ := s.release_wire_stream_unlocked('', 'stream', 'main', lease.generation) or { panic('clear failed') }
	s.mu.unlock()
	s.finish_initial_send(claim)
	duplicate := s.begin_external_creation(req) or { panic(err) }
	assert duplicate.cached && duplicate.lease == lease
	assert s.admit_wire_initial_creation('stream', 'main', duplicate.lease.generation, duplicate.lease.token) == none
	assert s.creation_grants.len == 0 && s.creation_issues.len == 0
}

fn test_external_creation_revoke_fences_late_native_and_remote_completion() {
	for remote in [false, true] {
		mut s := FeishuState{}
		req := external_request(mut s, 'b', 'bind', 'message')
		attempt := s.begin_external_creation(req) or { panic(err) }
		s.revoke_external_creation(req) or { panic(err) }
		if remote {
			mut other := FeishuState{}
			lease := other.issue_wire_bind_creation('stream', 'main', 'message') or { panic(err) }
			if _ := s.complete_external_remote(attempt, lease) {
				assert false
			}
		} else {
			if _ := s.complete_external_local(attempt) {
				assert false
			}
		}
		s.finish_external_creation(attempt)
		if _ := s.begin_external_creation(req) {
			assert false
		}
		assert s.creation_grants.len == 0 && s.creation_issues.len == 0
	}
}

fn test_external_creation_unknown_epoch_expiry_conflict_and_restart_fail_closed() {
	mut s := FeishuState{}
	req := external_request(mut s, 'c', 'send', '')
	for bad in [ExternalCreationRequest{ ...req, epoch: 'old' },
		ExternalCreationRequest{ ...req, issued_at: time.now().unix() - 301 },
		ExternalCreationRequest{ ...req, issued_at: time.now().unix() + 60 },
		ExternalCreationRequest{ ...req, kind: 'other' },
		ExternalCreationRequest{ ...req, request_id: 'bad' },
		ExternalCreationRequest{ ...req, kind: 'bind' }] {
		if _ := s.begin_external_creation(bad) {
			assert false
		}
	}
	attempt := s.begin_external_creation(req) or { panic(err) }
	_ := s.complete_external_local(attempt) or { panic(err) }
	if _ := s.begin_external_creation(ExternalCreationRequest{ ...req, stream_id: 'other' }) {
		assert false
	}
	mut restarted := FeishuState{}
	_ := restarted.external_creation_discovery() or { panic(err) }
	if _ := restarted.begin_external_creation(req) {
		assert false
	}
	assert restarted.creation_grants.len == 0
}

fn test_external_creation_physical_replacement_fences_issuance_and_caches_failure() {
	mut s := FeishuState{}
	req := external_request(mut s, 'd', 'bind', 'message')
	attempt := s.begin_external_creation(req) or { panic(err) }
	s.register_stream_buffer('message', 'other-stream', 'main', '', '', '')
	s.clear_buffer('message')
	if _ := s.complete_external_local(attempt) {
		assert false
	}
	s.finish_external_creation(attempt)
	if _ := s.begin_external_creation(req) {
		assert false
	}
	assert s.creation_grants.len == 0
}

fn test_external_creation_revoked_intent_requires_explicit_fresh_request() {
	mut s := FeishuState{}
	req := external_request(mut s, 'e', 'send', '')
	attempt := s.begin_external_creation(req) or { panic(err) }
	lease := s.complete_external_local(attempt) or { panic(err) }
	s.revoke_external_creation(req) or { panic(err) }
	if _ := s.begin_external_creation(req) {
		assert false
	}
	fresh := external_request(mut s, 'f', 'send', '')
	next := s.begin_external_creation(fresh) or { panic(err) }
	new_lease := s.complete_external_local(next) or { panic(err) }
	assert new_lease.token != lease.token
	assert s.admit_wire_initial_creation('stream', 'main', lease.generation, lease.token) == none
}

fn test_external_creation_memo_capacity_never_evicts_live_revocation() {
	mut s := FeishuState{}
	req := external_request(mut s, 'a', 'send', '')
	attempt := s.begin_external_creation(req) or { panic(err) }
	_ := s.complete_external_local(attempt) or { panic(err) }
	_ := s.revoke_external_creation(req) or { panic(err) }
	memo := s.external_creation_memos[req.request_id] or { panic('missing memo') }
	for i in 0 .. creation_limit { s.external_creation_memos['capacity_${i}'] = memo }
	if _ := s.begin_external_creation(external_request(mut s, 'b', 'send', '')) {
		assert false
	}
	if _ := s.begin_external_creation(req) {
		assert false
	}
	assert s.creation_grants.len == 0
	s.external_creation_memos.clear()
	expired := ExternalCreationRequest{ ...req, issued_at: time.now().unix() - creation_lifetime_seconds }
	if _ := s.begin_external_creation(expired) {
		assert false
	}
}

fn test_remote_creation_revoke_preserves_peer_and_checks_exact_scope() {
	mut s := FeishuState{}
	lease := s.issue_wire_creation('stream', 'main') or { panic(err) }
	peer := s.issue_wire_creation('stream', 'main') or { panic(err) }
	s.revoke_wire_creation('other', 'main', lease)
	assert lease.token in s.creation_grants
	s.revoke_wire_creation('stream', 'other', lease)
	assert lease.token in s.creation_grants
	s.revoke_wire_creation('stream', 'main', CreationLease{ generation: 'old', token: lease.token })
	assert lease.token in s.creation_grants
	s.revoke_wire_creation('stream', 'main', lease)
	assert s.admit_wire_initial_creation('stream', 'main', lease.generation, lease.token) == none
	claim := s.admit_wire_initial_creation('stream', 'main', peer.generation, peer.token) or { panic('peer revoked') }
	s.finish_initial_send(claim)
}

fn test_external_revocation_before_first_issuance_blocks_reordered_post() {
	mut s := FeishuState{}
	req := external_request(mut s, '9', 'send', '')
	_ := s.revoke_external_creation(req) or { panic(err) }
	if _ := s.begin_external_creation(req) {
		assert false
	}
	assert s.creation_grants.len == 0 && s.creation_issues.len == 0
	_ := s.revoke_external_creation(req) or { panic(err) }
}

fn test_external_expired_issuance_is_pruned_without_renewing_old_intent() {
	mut s := FeishuState{}
	base := external_request(mut s, '8', 'send', '')
	req := ExternalCreationRequest{ ...base, issued_at: base.issued_at - creation_lifetime_seconds + 1 }
	attempt := s.begin_external_creation(req) or { panic(err) }
	lease := s.complete_external_local(attempt) or { panic(err) }
	time.sleep(1100 * time.millisecond)
	fresh := external_request(mut s, '7', 'send', '')
	next := s.begin_external_creation(fresh) or { panic(err) }
	assert req.request_id !in s.external_creation_memos
	if _ := s.begin_external_creation(req) {
		assert false
	}
	assert s.admit_wire_initial_creation('stream', 'main', lease.generation, lease.token) == none
	s.finish_external_creation(next)
}

fn test_external_failed_target_reservation_cannot_mint_after_withdrawal() {
	mut s := FeishuState{}
	s.register_stream_buffer('message', 'other-stream', 'main', '', '', '')
	req := external_request(mut s, '6', 'bind', 'message')
	if _ := s.begin_external_creation(req) {
		assert false
	}
	s.clear_buffer('message')
	if _ := s.begin_external_creation(req) {
		assert false
	}
	assert s.creation_grants.len == 0 && s.creation_issues.len == 0
	fresh := external_request(mut s, '5', 'bind', 'message')
	attempt := s.begin_external_creation(fresh) or { panic(err) }
	_ := s.complete_external_local(attempt) or { panic(err) }
}
