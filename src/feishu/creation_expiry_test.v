module feishu

import time

fn test_expired_first_bind_clear_cannot_revoke_a_live_peer_ticket() {
	mut s := FeishuState{}
	old := s.issue_wire_bind_creation('old', 'main', 'physical') or { panic(err) }
	peer := s.issue_wire_bind_creation('new', 'main', 'physical') or { panic(err) }
	grant := s.creation_grants[old.token]
	s.creation_grants[old.token] = CreationGrant{ ...grant, expires_at: time.now().unix() - 1 }
	s.mu.@lock()
	assert s.release_wire_stream_unlocked('physical', 'old', 'main', old.generation) == none
	assert s.admit_wire_bind_unlocked('physical', 'new', 'main', '', peer.generation, peer.token)
	s.mu.unlock()
}

fn test_discovery_reclaims_expired_grants_reservations_and_memos_together() {
	mut s := FeishuState{}
	discovery := s.external_creation_discovery() or { panic(err) }
	req := ExternalCreationRequest{ epoch: discovery.epoch, issued_at: discovery.issued_at, request_id: 'a'.repeat(64), stream_id: 'lost', instance: 'main', kind: 'send' }
	attempt := s.begin_external_creation(req) or { panic(err) }
	lease := s.complete_external_local(attempt) or { panic(err) }
	pending := s.begin_creation_issue('interrupted', 'main') or { panic(err) }
	grant := s.creation_grants[lease.token]
	issue := s.creation_issues[pending.id]
	s.creation_grants[lease.token] = CreationGrant{ ...grant, expires_at: time.now().unix() - 1 }
	s.creation_issues[pending.id] = CreationGrant{ ...issue, expires_at: time.now().unix() - 1 }
	s.external_creation_memos[req.request_id] = &ExternalCreationMemo{ request: req, expires_at: time.now().unix() - 1, pending: false, lease: lease }
	_ := s.external_creation_discovery() or { panic(err) }
	assert s.creation_grants.len == 0 && s.creation_issues.len == 0
	assert s.external_creation_memos.len == 0
}

fn test_expired_external_replay_reclaims_capacity_without_renewing_intent() {
	mut s := FeishuState{}
	discovery := s.external_creation_discovery() or { panic(err) }
	req := ExternalCreationRequest{ epoch: discovery.epoch, issued_at: discovery.issued_at - creation_lifetime_seconds, request_id: 'b'.repeat(64), stream_id: 'old', instance: 'main', kind: 'send' }
	memo := &ExternalCreationMemo{ request: req, expires_at: time.now().unix() - 1, pending: false, failure: 'feishu_creation_retired' }
	for i in 0 .. creation_limit { s.external_creation_memos['old-${i}'] = memo }
	if _ := s.begin_external_creation(req) {
		assert false
	}
	assert s.external_creation_memos.len == 0
	assert s.creation_grants.len == 0 && s.creation_issues.len == 0
}

fn test_expired_reservations_release_capacity_without_evicting_live_authority() {
	mut s := FeishuState{}
	now := time.now().unix()
	live := s.issue_wire_creation('live', 'main') or { panic(err) }
	pending := s.begin_creation_issue('live-pending', 'main') or { panic(err) }
	for i in 0 .. creation_limit - 2 {
		if i % 2 == 0 {
			s.creation_grants['expired-${i}'] = CreationGrant{ stream_id: 'abandoned', generation: 'expired', app_name: 'main', expires_at: now - 1 }
		} else {
			s.creation_issues['expired-${i}'] = CreationGrant{ stream_id: 'interrupted', app_name: 'main', expires_at: now - 1 }
		}
	}
	assert s.creation_grants.len + s.creation_issues.len == creation_limit
	s.prune_expired_creations()
	assert s.creation_grants.len == 1 && s.creation_issues.len == 1
	fresh := s.issue_wire_creation('fresh', 'main') or { panic(err) }
	assert fresh.token != live.token
	claim := s.admit_wire_initial_creation('live', 'main', live.generation, live.token) or { panic('live grant evicted') }
	s.finish_initial_send(claim)
	mut remote := FeishuState{}
	lease := remote.issue_wire_creation('live-pending', 'main') or { panic(err) }
	s.complete_creation_issue(pending, lease) or { panic(err) }
	assert s.creation_issues.len == 0
	assert s.creation_grants.len == 2
}

fn test_expired_external_completion_and_finish_cannot_recreate_pruned_reservation() {
	mut s := FeishuState{}
	discovery := s.external_creation_discovery() or { panic(err) }
	req := ExternalCreationRequest{ epoch: discovery.epoch, issued_at: discovery.issued_at - creation_lifetime_seconds, request_id: 'c'.repeat(64), stream_id: 'interrupted', instance: 'main', kind: 'send' }
	issue := CreationIssue{ id: 'expired-issue' }
	s.creation_issues[issue.id] = CreationGrant{ stream_id: req.stream_id, app_name: 'main', expires_at: time.now().unix() - 1 }
	memo := &ExternalCreationMemo{ request: req, issue: issue, expires_at: time.now().unix() - 1 }
	s.external_creation_memos[req.request_id] = memo
	attempt := ExternalCreationAttempt{ memo: memo }
	s.finish_external_creation(attempt)
	assert s.creation_issues.len == 0 && s.external_creation_memos.len == 0
	mut remote := FeishuState{}
	lease := remote.issue_wire_creation(req.stream_id, 'main') or { panic(err) }
	if _ := s.complete_external_local(attempt) {
		assert false
	}
	if _ := s.complete_external_remote(attempt, lease) {
		assert false
	}
	if _ := s.begin_external_creation(req) {
		assert false
	}
	assert s.creation_grants.len == 0 && s.buffers.len == 0
}

fn test_cleanup_keeps_unexpired_revocation_evidence_and_releases_only_expired_memos() {
	mut s := FeishuState{}
	discovery := s.external_creation_discovery() or { panic(err) }
	req := ExternalCreationRequest{ epoch: discovery.epoch, issued_at: discovery.issued_at, request_id: 'd'.repeat(64), stream_id: 'revoked', instance: 'main', kind: 'send' }
	_ := s.revoke_external_creation(req) or { panic(err) }
	old_req := ExternalCreationRequest{ ...req, issued_at: discovery.issued_at - creation_lifetime_seconds, request_id: 'e'.repeat(64) }
	memo := &ExternalCreationMemo{ request: old_req, expires_at: time.now().unix() - 1, pending: false, failure: 'feishu_creation_retired' }
	for i in 0 .. creation_limit - 1 { s.external_creation_memos['expired-${i}'] = memo }
	s.prune_expired_creations()
	assert s.external_creation_memos.len == 1
	if _ := s.begin_external_creation(req) {
		assert false
	}
	if _ := s.begin_external_creation(old_req) {
		assert false
	}
	fresh_req := ExternalCreationRequest{ ...req, request_id: 'f'.repeat(64), stream_id: 'fresh' }
	attempt := s.begin_external_creation(fresh_req) or { panic(err) }
	_ := s.complete_external_local(attempt) or { panic(err) }
	assert s.external_creation_memos.len == 2 && s.creation_grants.len == 1
}

fn test_bridge_replay_evidence_rotates_authority_at_capacity_instead_of_reminting() {
	mut s := FeishuState{}
	mut owner := new_bridge_authority()
	lease := s.issue_bridge_creation(mut owner, 'old', 'main', '', 'old-request') or { panic(err) }
	grant := s.creation_grants[lease.token]
	s.creation_grants[lease.token] = CreationGrant{ ...grant, expires_at: time.now().unix() - 1 }
	memo := owner.creations['old-request']
	for i in 0 .. creation_limit - 1 { owner.creations['memo-${i}'] = memo }
	s.prune_expired_creations()
	assert s.creation_grants.len == 0
	if _ := s.issue_bridge_creation(mut owner, 'fresh', 'main', '', 'new-request') {
		assert false
	}
	assert (s.issue_bridge_creation(mut owner, 'old', 'main', '', 'old-request') or { panic(err) }) == lease
	assert s.admit_bridge_initial_creation(owner, 'old', 'main', lease.generation, lease.token) == none
	_ := s.retire_bridge_authority_unlocked(mut owner)
	mut fresh_owner := new_bridge_authority()
	fresh := s.issue_bridge_creation(mut fresh_owner, 'fresh', 'main', '', 'new-request') or { panic(err) }
	assert fresh.token != lease.token && owner.creations.len == 0
	if _ := s.issue_bridge_creation(mut owner, 'old', 'main', '', 'old-request') {
		assert false
	}
	assert s.admit_bridge_initial_creation(fresh_owner, 'old', 'main', lease.generation, lease.token) == none
}
