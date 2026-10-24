module feishu

fn test_capacity_rotation_preserves_live_grants_bindings_and_publication_scopes() {
	for mode in ['grant', 'buffer', 'send', 'issue'] {
		mut s := FeishuState{}
		mut owner := new_bridge_authority()
		s.note_bridge_creation_capacity(mut owner)
		lease := s.issue_bridge_creation(mut owner, 'active', 'main', '', 'active') or { panic(err) }
		mut claim := ?InitialSend(none)
		if mode in ['buffer', 'send'] {
			admitted := s.admit_bridge_initial_creation(owner, 'active', 'main', lease.generation, lease.token) or { panic('admit') }
			claim = admitted
			if mode == 'buffer' {
				s.mu.@lock()
				assert s.commit_initial_send_generation_unlocked(admitted, 'physical', 'main', '', '', '', lease.generation)
				s.mu.unlock()
				s.finish_initial_send(admitted)
			}
		}
		if mode == 'issue' {
			s.revoke_wire_creation('active', 'main', lease)
			_ := s.begin_creation_issue('ack-gap', 'main') or { panic(err) }
		}
		s.mu.@lock()
		assert !s.retire_idle_creation_capacity_unlocked(mut owner)
		s.mu.unlock()
		assert !s.bridge_lease_expired(owner)
		if mode == 'grant' {
			assert s.admit_bridge_initial_creation(owner, 'active', 'main', lease.generation, lease.token) != none
		}
		if mode == 'buffer' {
			assert s.buffers['physical'].generation == lease.generation
		}
		if pending := claim { s.finish_initial_send(pending) }
	}
}

fn test_capacity_rotation_requires_rejection_and_drain_without_reminting_old_authority() {
	mut s := FeishuState{}
	mut owner := new_bridge_authority()
	s.mu.@lock()
	assert !s.retire_idle_creation_capacity_unlocked(mut owner)
	s.mu.unlock()
	lease := s.issue_bridge_creation(mut owner, 'old', 'main', '', 'old-request') or { panic(err) }
	s.revoke_wire_creation('old', 'main', lease)
	s.note_bridge_creation_capacity(mut owner)
	s.mu.@lock()
	assert s.retire_idle_creation_capacity_unlocked(mut owner)
	assert !s.retire_idle_creation_capacity_unlocked(mut owner)
	s.mu.unlock()
	assert owner.creations.len == 0 && s.bridge_lease_expired(owner)
	if _ := s.issue_bridge_creation(mut owner, 'old', 'main', '', 'old-request') {
		assert false
	}
	mut current := new_bridge_authority()
	fresh := s.issue_bridge_creation(mut current, 'old', 'main', '', 'fresh-request') or { panic(err) }
	assert fresh.token != lease.token
	assert s.admit_bridge_initial_creation(current, 'old', 'main', lease.generation, lease.token) == none
}

fn test_late_capacity_retirement_cannot_clear_reconnected_same_id_binding() {
	mut s := FeishuState{}
	mut old := new_bridge_authority()
	s.note_bridge_creation_capacity(mut old)
	s.mu.@lock()
	assert s.retire_idle_creation_capacity_unlocked(mut old)
	s.mu.unlock()
	mut current := new_bridge_authority()
	lease := s.issue_bridge_creation(mut current, 'stream', 'main', '', 'fresh') or { panic(err) }
	claim := s.admit_bridge_initial_creation(current, 'stream', 'main', lease.generation, lease.token) or { panic('fresh') }
	s.mu.@lock()
	assert s.commit_initial_send_generation_unlocked(claim, 'same-physical', 'main', '', '', 'new', lease.generation)
	assert !s.retire_idle_creation_capacity_unlocked(mut old)
	_ := s.retire_bridge_authority_unlocked(mut old)
	assert s.buffers['same-physical'].generation == lease.generation
	s.mu.unlock()
	s.finish_initial_send(claim)
	s.note_bridge_creation_capacity(mut old)
	assert !s.bridge_lease_expired(current)
}

fn test_idle_rotation_waits_for_callback_reply_and_dispatch_copies_release_once() {
	mut s := FeishuState{}
	mut old := new_bridge_authority()
	s.note_bridge_creation_capacity(mut old)
	first := s.begin_bridge_dispatch(mut old) or { panic('dispatch') }
	second := s.begin_bridge_dispatch(mut old) or { panic('dispatch') }
	mut stranger := FeishuState{}
	stranger.finish_bridge_dispatch(first)
	assert old.active_dispatches == 2
	s.finish_bridge_dispatch(first)
	s.finish_bridge_dispatch(first)
	s.mu.@lock()
	assert !s.retire_idle_creation_capacity_unlocked(mut old)
	s.mu.unlock()
	s.finish_bridge_dispatch(second)
	s.mu.@lock()
	assert s.retire_idle_creation_capacity_unlocked(mut old)
	s.mu.unlock()
	mut next := new_bridge_authority()
	current := s.begin_bridge_dispatch(mut next) or { panic('current') }
	s.finish_bridge_dispatch(first)
	assert next.active_dispatches == 1
	s.finish_bridge_dispatch(current)
}
