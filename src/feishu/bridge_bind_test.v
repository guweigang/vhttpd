module feishu

fn bind_fixture(mut local FeishuState, mut remote FeishuState, mut owner BridgeAuthority) CreationLease {
	lease := remote.issue_bridge_creation(mut owner, 'old', 'main', 'message', 'bind') or { panic(err) }
	issue := local.begin_creation_issue_for_target('old', 'main', 'message') or { panic(err) }
	local.complete_bridge_creation_issue(issue, lease, owner) or { panic(err) }
	local.finish_creation_issue(issue)
	return lease
}

fn test_bridge_bind_roundtrip_uses_remote_generation_and_fences_pending_commands() {
	mut local := FeishuState{}
	mut remote := FeishuState{}
	mut owner := new_bridge_authority()
	lease := bind_fixture(mut local, mut remote, mut owner)
	claim := local.begin_bridge_bind_unlocked('message', 'old', 'main', '', lease.generation, lease.token) or { panic('claim') }
	assert local.admit_wire_stream_command('message', 'old', 'main', lease.generation) == none
	assert local.begin_bridge_bind_unlocked('message', 'next', 'main', lease.generation, '', '') == none
	generation := remote.publish_bridge_bind_unlocked(owner, 'message', 'old', 'main', '', 'old', 'main', lease.generation, lease.token) or { panic('publish') }
	assert local.complete_bridge_bind_unlocked(claim, generation)
	assert local.buffers['message'].generation == remote.buffers['message'].generation
	old_command := local.admit_wire_stream_command('message', 'old', 'main', generation) or { panic('command') }
	rebind := local.begin_bridge_bind_unlocked('message', 'next', 'main', generation, '', '') or { panic('rebind') }
	assert local.stream_command_snapshot(old_command) == none
	next := remote.publish_bridge_bind_unlocked(owner, 'message', 'next', 'main', rebind.expected, rebind.source.stream, rebind.source.app, '', '') or { panic('remote rebind') }
	assert local.complete_bridge_bind_unlocked(rebind, next)
	assert next != generation
	assert local.buffers['message'].generation == remote.buffers['message'].generation
	assert local.admit_wire_stream_command('message', 'next', 'main', next) != none
	assert remote.admit_wire_stream_command('message', 'next', 'main', next) != none
	assert local.stream_command_snapshot(old_command) == none
}

fn test_bridge_bind_clear_before_remote_publish_spends_first_bind_forever() {
	mut local := FeishuState{}
	mut remote := FeishuState{}
	mut owner := new_bridge_authority()
	lease := bind_fixture(mut local, mut remote, mut owner)
	claim := local.begin_bridge_bind_unlocked('message', 'old', 'main', '', lease.generation, lease.token) or { panic('claim') }
	assert local.release_wire_stream_unlocked('message', 'old', 'main', lease.generation) != none
	assert remote.release_bridge_stream_unlocked(owner, 'message', 'old', 'main', lease.generation) != none
	assert remote.publish_bridge_bind_unlocked(owner, 'message', 'old', 'main', '', 'old', 'main', lease.generation, lease.token) == none
	assert !local.complete_bridge_bind_unlocked(claim, 'late')
	assert local.buffers.len == 0 && remote.buffers.len == 0
}

fn test_bridge_bind_clear_after_remote_publish_requires_exact_compensation() {
	mut local := FeishuState{}
	mut remote := FeishuState{}
	mut owner := new_bridge_authority()
	lease := bind_fixture(mut local, mut remote, mut owner)
	claim := local.begin_bridge_bind_unlocked('message', 'old', 'main', '', lease.generation, lease.token) or { panic('claim') }
	generation := remote.publish_bridge_bind_unlocked(owner, 'message', 'old', 'main', '', 'old', 'main', lease.generation, lease.token) or { panic('publish') }
	assert local.release_wire_stream_unlocked('message', 'old', 'main', lease.generation) != none
	assert remote.release_bridge_stream_unlocked(owner, 'message', 'old', 'main', lease.generation) == none
	assert !local.complete_bridge_bind_unlocked(claim, generation)
	assert remote.release_bridge_stream_unlocked(owner, 'message', 'old', 'main', generation) != none
	assert remote.publish_bridge_bind_unlocked(owner, 'message', 'old', 'main', '', 'old', 'main', lease.generation, lease.token) == none
}

fn test_bridge_bind_disconnect_and_native_replacement_reject_late_completion() {
	for replacement in [false, true] {
		mut local := FeishuState{}
		mut remote := FeishuState{}
		mut owner := new_bridge_authority()
		lease := bind_fixture(mut local, mut remote, mut owner)
		claim := local.begin_bridge_bind_unlocked('message', 'old', 'main', '', lease.generation, lease.token) or { panic('claim') }
		if replacement {
			local.register_stream_buffer('message', 'replacement', 'main', '', '', 'keep')
		}
		_ := local.retire_bridge_authority_unlocked(mut owner)
		assert !local.complete_bridge_bind_unlocked(claim, 'late')
		assert local.abort_bridge_bind_unlocked(claim) == none
		if replacement {
			assert local.buffers['message'].content == 'keep'
		} else {
			assert local.buffers.len == 0
		}
		assert remote.publish_bridge_bind_unlocked(owner, 'message', 'old', 'main', '', 'old', 'main', lease.generation, lease.token) == none
	}
}

fn test_bridge_rebind_replay_and_foreign_owner_cannot_replace_current_generation() {
	mut s := FeishuState{}
	mut owner := new_bridge_authority()
	lease := s.issue_bridge_creation(mut owner, 'old', 'main', 'message', 'bind') or { panic(err) }
	first := s.publish_bridge_bind_unlocked(owner, 'message', 'old', 'main', '', 'old', 'main', lease.generation, lease.token) or { panic('first') }
	next := s.publish_bridge_bind_unlocked(owner, 'message', 'new', 'main', first, 'old', 'main', '', '') or { panic('next') }
	assert s.publish_bridge_bind_unlocked(owner, 'message', 'new', 'main', first, 'old', 'main', '', '') == none
	assert s.publish_bridge_bind_unlocked(new_bridge_authority(), 'message', 'evil', 'main', next, 'new', 'main', '', '') == none
	assert s.release_bridge_stream_unlocked(owner, 'message', 'old', 'main', first) == none
	assert s.buffers['message'].generation == next
	assert s.release_bridge_stream_unlocked(owner, 'message', 'new', 'main', next) != none
	assert s.publish_bridge_bind_unlocked(owner, 'message', 'new', 'main', first, 'old', 'main', '', '') == none
}

fn test_bridge_bind_cannot_cancel_foreign_destination_creators_or_native_buffers() {
	mut s := FeishuState{}
	mut owner := new_bridge_authority()
	lease := s.issue_bridge_creation(mut owner, 'old', 'main', 'message', 'bind') or { panic(err) }
	first := s.publish_bridge_bind_unlocked(owner, 'message', 'old', 'main', '', 'old', 'main', lease.generation, lease.token) or { panic('first') }
	mut foreign := new_bridge_authority()
	peer := s.issue_bridge_creation(mut foreign, 'destination', 'main', '', 'peer') or { panic(err) }
	assert s.publish_bridge_bind_unlocked(owner, 'message', 'destination', 'main', first, 'old', 'main', '', '') == none
	assert s.creation_grants[peer.token].generation == peer.generation
	assert s.begin_bridge_bind_unlocked('message', 'destination', 'main', first, '', '') == none
	s.register_stream_buffer('native', 'native-stream', 'main', '', '', 'keep')
	assert s.publish_bridge_bind_unlocked(owner, 'message', 'native-stream', 'main', first, 'old', 'main', '', '') == none
	assert s.buffers['native'].content == 'keep'
	assert s.buffers['message'].generation == first
}

fn test_bridge_bind_completion_rechecks_destination_ownership_after_network_io() {
	mut local := FeishuState{}
	mut remote := FeishuState{}
	mut owner := new_bridge_authority()
	lease := bind_fixture(mut local, mut remote, mut owner)
	claim := local.begin_bridge_bind_unlocked('message', 'old', 'main', '', lease.generation, lease.token) or { panic('claim') }
	assert local.complete_bridge_bind_unlocked(claim, 'first')
	rebind := local.begin_bridge_bind_unlocked('message', 'new', 'main', 'first', '', '') or { panic('rebind') }
	issue := local.begin_creation_issue_for_target('new', 'main', 'other') or { panic(err) }
	assert !local.complete_bridge_bind_unlocked(rebind, 'late')
	assert local.abort_bridge_bind_unlocked(rebind) != none
	assert issue.id in local.creation_issues
	local.finish_creation_issue(issue)
	assert local.buffers.len == 0
}
