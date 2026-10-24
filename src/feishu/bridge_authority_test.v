module feishu

import time

fn test_bridge_disconnect_retires_grants_and_create_replay_stays_spent() {
	mut s := FeishuState{}
	mut old := new_bridge_authority()
	lease := s.issue_bridge_creation(mut old, 'stream', 'main', '', 'request') or { panic(err) }
	s.revoke_wire_creation('stream', 'main', lease)
	replay := s.issue_bridge_creation(mut old, 'stream', 'main', '', 'request') or { panic(err) }
	assert replay == lease
	assert s.admit_wire_initial_creation('stream', 'main', lease.generation, lease.token) == none
	s.mu.@lock()
	_ := s.retire_bridge_authority_unlocked(mut old)
	s.mu.unlock()
	if _ := s.issue_bridge_creation(mut old, 'stream', 'main', '', 'fresh') {
		assert false
	}
	mut next := new_bridge_authority()
	fresh := s.issue_bridge_creation(mut next, 'stream', 'main', '', 'request') or { panic(err) }
	assert fresh != lease && fresh.generation != lease.generation
	assert !s.bridge_request_allowed(next, 'send', 'stream', 'main', lease.generation, '')
}

fn test_bridge_disconnected_http_claim_cannot_publish_after_reconnect() {
	mut s := FeishuState{}
	mut old := new_bridge_authority()
	lease := s.issue_bridge_creation(mut old, 'stream', 'main', '', 'first') or { panic(err) }
	claim := s.admit_wire_initial_creation('stream', 'main', lease.generation, lease.token) or { panic('admission') }
	s.mu.@lock()
	_ := s.retire_bridge_authority_unlocked(mut old)
	s.mu.unlock()
	mut next := new_bridge_authority()
	fresh := s.issue_bridge_creation(mut next, 'stream', 'main', '', 'first') or { panic(err) }
	current := s.admit_wire_initial_creation('stream', 'main', fresh.generation, fresh.token) or { panic('new admission') }
	s.mu.@lock()
	assert s.commit_initial_send_generation_unlocked(current, 'message', 'main', '', '', 'new', fresh.generation)
	assert !s.commit_initial_send_generation_unlocked(claim, 'message', 'main', '', '', 'old', lease.generation)
	_ := s.retire_bridge_authority_unlocked(mut old)
	assert s.buffers['message'].content == 'new'
	s.mu.unlock()
	s.finish_initial_send(claim)
	s.finish_initial_send(current)
	assert s.initial_send_count == 0
}

fn test_bridge_retirement_preserves_native_replacement_and_other_connection() {
	mut s := FeishuState{}
	mut old := new_bridge_authority()
	lease := s.issue_bridge_creation(mut old, 'old-stream', 'main', '', 'first') or { panic(err) }
	claim := s.admit_wire_initial_creation('old-stream', 'main', lease.generation, lease.token) or { panic('admission') }
	s.mu.@lock()
	assert s.commit_initial_send_generation_unlocked(claim, 'message', 'main', '', '', 'old', lease.generation)
	s.mu.unlock()
	s.register_stream_buffer('message', 'old-stream', 'main', '', '', 'replacement')
	mut other := new_bridge_authority()
	peer := s.issue_bridge_creation(mut other, 'other-stream', 'main', '', 'first') or { panic(err) }
	s.mu.@lock()
	_ := s.retire_bridge_authority_unlocked(mut old)
	assert s.buffers['message'].content == 'replacement'
	s.mu.unlock()
	pending := s.admit_wire_initial_creation('other-stream', 'main', peer.generation, peer.token) or { panic('other connection retired') }
	s.finish_initial_send(pending)
	s.finish_initial_send(claim)
}

fn test_bridge_retired_result_cannot_install_local_grant_or_external_lease() {
	mut local := FeishuState{}
	mut owner := new_bridge_authority()
	issue := local.begin_creation_issue('stream', 'main') or { panic(err) }
	discovery := local.external_creation_discovery() or { panic(err) }
	request := ExternalCreationRequest{ epoch: discovery.epoch, issued_at: discovery.issued_at, request_id: 'a'.repeat(64), stream_id: 'external', instance: 'main', kind: 'send' }
	attempt := local.begin_external_creation(request) or { panic(err) }
	local.mu.@lock()
	_ := local.retire_bridge_authority_unlocked(mut owner)
	local.mu.unlock()
	lease := CreationLease{ generation: 'remote', token: 'a'.repeat(64) }
	if _ := local.complete_bridge_creation_issue(issue, lease, owner) {
		assert false
	}
	if _ := local.complete_external_remote_owned(attempt, lease, owner) {
		assert false
	}
	local.finish_creation_issue(issue)
	local.finish_external_creation(attempt)
	assert local.creation_grants.len == 0 && local.creation_issues.len == 0
}

fn test_bridge_clear_captures_connection_and_cannot_clear_another_owner() {
	mut s := FeishuState{}
	mut old := new_bridge_authority()
	mut other := new_bridge_authority()
	lease := s.issue_bridge_creation(mut old, 'stream', 'main', '', 'first') or { panic(err) }
	s.mu.@lock()
	assert s.release_bridge_stream_unlocked(other, '', 'stream', 'main', lease.generation) == none
	released := s.release_bridge_stream_unlocked(old, '', 'stream', 'main', lease.generation) or { panic('missing') }
	assert same_bridge_authority(released.bridge_owner, old)
	s.mu.unlock()
	replay := s.issue_bridge_creation(mut old, 'stream', 'main', '', 'first') or { panic(err) }
	assert replay == lease
	assert s.admit_wire_initial_creation('stream', 'main', lease.generation, lease.token) == none
}

fn test_bridge_create_intent_capacity_retains_replay_evidence() {
	mut s := FeishuState{}
	mut owner := new_bridge_authority()
	lease := s.issue_bridge_creation(mut owner, 'stream', 'main', '', 'first') or { panic(err) }
	s.revoke_wire_creation('stream', 'main', lease)
	memo := owner.creations['first']
	for i in 0 .. creation_limit - 1 { owner.creations['fill-${i}'] = memo }
	if _ := s.issue_bridge_creation(mut owner, 'stream', 'main', '', 'fresh') {
		assert false
	}
	assert (s.issue_bridge_creation(mut owner, 'stream', 'main', '', 'first') or { panic(err) }) == lease
	assert s.creation_grants.len == 0
}

fn test_bridge_expired_lease_never_revives_on_heartbeat_or_late_completion() {
	mut s := FeishuState{}
	mut owner := new_bridge_authority()
	s.start_bridge_lease(mut owner)
	lease := s.issue_bridge_creation(mut owner, 'stream', 'main', '', 'first') or { panic(err) }
	claim := s.admit_bridge_initial_creation(owner, 'stream', 'main', lease.generation, lease.token) or { panic('admission') }
	owner.deadline = time.now().unix() - 1
	assert !s.touch_bridge_lease(mut owner)
	assert s.bridge_lease_expired(owner)
	if _ := s.issue_bridge_creation(mut owner, 'stream', 'main', '', 'new') {
		assert false
	}
	s.mu.@lock()
	assert !s.commit_initial_send_generation_unlocked(claim, 'late', 'main', '', '', '', lease.generation)
	_ := s.retire_bridge_authority_unlocked(mut owner)
	s.mu.unlock()
	s.finish_initial_send(claim)
	assert s.buffers.len == 0 && s.creation_grants.len == 0
}

fn test_bridge_first_bind_retains_connection_owner_until_disconnect() {
	mut s := FeishuState{}
	mut owner := new_bridge_authority()
	lease := s.issue_bridge_creation(mut owner, 'stream', 'main', 'message', 'bind') or { panic(err) }
	s.mu.@lock()
	binding := s.wire_bind_bridge_binding_unlocked('message', lease.token)
	assert s.admit_wire_bind_unlocked('message', 'stream', 'main', '', lease.generation, lease.token)
	s.register_stream_buffer_unlocked('message', 'stream', 'main', '', '', '')
	s.retain_bridge_binding_unlocked('message', binding)
	assert s.buffers['message'].generation != lease.generation
	_ := s.retire_bridge_authority_unlocked(mut owner)
	assert s.buffers.len == 0
	s.mu.unlock()
}

fn test_bridge_wire_rebind_clear_retains_original_remote_scope() {
	mut s := FeishuState{}
	mut owner := new_bridge_authority()
	lease := s.issue_bridge_creation(mut owner, 'remote-stream', 'main', '', 'send') or { panic(err) }
	claim := s.admit_bridge_initial_creation(owner, 'remote-stream', 'main', lease.generation, lease.token) or { panic('admission') }
	s.mu.@lock()
	assert s.commit_initial_send_generation_unlocked(claim, 'message', 'main', '', '', 'old', lease.generation)
	binding := s.wire_bind_bridge_binding_unlocked('message', '')
	assert s.admit_wire_bind_unlocked('message', 'local-new-stream', 'main', lease.generation, '', '')
	s.register_stream_buffer_unlocked('message', 'local-new-stream', 'main', '', '', '')
	s.retain_bridge_binding_unlocked('message', binding)
	generation := s.buffers['message'].generation
	released := s.release_wire_stream_unlocked('message', 'local-new-stream', 'main', generation) or { panic('release') }
	assert released.generation == generation && generation != lease.generation
	assert released.bridge_generation == lease.generation
	assert released.bridge_stream == 'remote-stream'
	assert same_bridge_authority(released.bridge_owner, owner)
	s.mu.unlock()
	s.finish_initial_send(claim)
}

fn test_bridge_expired_local_credentials_cannot_bind_before_cleanup_runs() {
	mut s := FeishuState{}
	mut owner := new_bridge_authority()
	lease := s.issue_bridge_creation(mut owner, 'stream', 'main', 'message', 'bind') or { panic(err) }
	owner.deadline = time.now().unix() - 1
	s.mu.@lock()
	assert !s.admit_wire_bind_unlocked('message', 'stream', 'main', '', lease.generation, lease.token)
	assert s.buffers.len == 0
	s.mu.unlock()
}
