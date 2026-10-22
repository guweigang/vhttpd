module feishu

import time

// An authority is a connection lifetime, not a reconnectable client ID.
@[heap]
pub struct BridgeAuthority {
mut:
	deadline                   i64
	retired                    bool
	creation_capacity_rejected bool
	active_dispatches          int
	creations                  map[string]BridgeCreationMemo
}

struct BridgeCreationMemo {
	stream  string
	app     string
	target  string
	lease   CreationLease
	failure string
}

pub fn new_bridge_authority() &BridgeAuthority { return &BridgeAuthority{} }

fn same_bridge_authority(a ?&BridgeAuthority, b ?&BridgeAuthority) bool {
	if first := a {
		second := b or { return false }
		return voidptr(first) == voidptr(second)
	}
	return b == none
}

pub fn (mut s FeishuState) issue_bridge_creation(mut owner BridgeAuthority, stream string, app string, target string, request_id string) !CreationLease {
	s.mu.@lock()
	defer { s.mu.unlock() }
	if !bridge_authority_live(owner) { return error('bridge_authority_retired') }
	if request_id == '' || request_id.len > 128 { return error('bridge_creation_request') }
	if memo := owner.creations[request_id] {
		if memo.stream != stream || memo.app != app || memo.target != target {
			return error('bridge_creation_conflict')
		}
		if memo.failure != '' { return error(memo.failure) }
		return memo.lease
	}
	// Retain replay evidence for the entire connection lifetime. Capacity rotates
	// the connection instead of evicting evidence and reminting an old request.
	if owner.creations.len >= creation_limit { return error('bridge_creation_capacity') }
	lease := s.issue_wire_creation_owned_unlocked(stream, app, target, owner, time.now().unix()) or {
		owner.creations[request_id] = BridgeCreationMemo{ stream: stream, app: app, target: target, failure: err.msg() }
		return err
	}
	owner.creations[request_id] = BridgeCreationMemo{ stream: stream, app: app, target: target, lease: lease }
	return lease
}

@[heap]
struct BridgeDispatchRegistration {
	owner       &BridgeAuthority  @[required]
	state_owner &InitialSendOwner @[required]
mut:
	released bool
}

pub struct BridgeDispatch {
	registration &BridgeDispatchRegistration @[required]
}

// The inbound callback owns its reply until it has been written or has failed.
// Idle creation rotation must not interrupt that handoff after the last clear.
pub fn (mut s FeishuState) begin_bridge_dispatch(mut owner BridgeAuthority) ?BridgeDispatch {
	s.mu.@lock()
	defer { s.mu.unlock() }
	if !bridge_authority_live(owner) { return none }
	owner.active_dispatches++
	return BridgeDispatch{ registration: &BridgeDispatchRegistration{ owner: &owner, state_owner: s.initial_send_owner } }
}

pub fn (mut s FeishuState) finish_bridge_dispatch(dispatch BridgeDispatch) {
	s.mu.@lock()
	defer { s.mu.unlock() }
	mut registration := dispatch.registration
	if voidptr(registration.state_owner) != voidptr(s.initial_send_owner) { return }
	if registration.released { return }
	registration.released = true
	mut owner := registration.owner
	owner.active_dispatches--
}

// A correlated, empty capacity rejection did not mutate remote resources.
pub fn (mut s FeishuState) note_bridge_creation_capacity(mut owner BridgeAuthority) {
	s.mu.@lock()
	defer { s.mu.unlock() }
	if bridge_authority_live(owner) { owner.creation_capacity_rejected = true }
}

// Caller holds mu AND the bridge connection registry lock. A creation failure
// cannot rotate a connection that still owns useful authority or publication IO.
pub fn (mut s FeishuState) retire_idle_creation_capacity_unlocked(mut owner BridgeAuthority) bool {
	if !owner.creation_capacity_rejected || !bridge_authority_live(owner) { return false }
	// Issuances reserve before borrowing a connection. Include reservations not
	// yet assigned remote authority, including ACK-to-local-publication gaps.
	if s.creation_issues.len > 0 || owner.active_dispatches > 0 { return false }
	for _, grant in s.creation_grants {
		if same_bridge_authority(grant.bridge_owner, owner) { return false }
	}
	for _, scope in s.initial_send_scopes {
		if same_bridge_authority(scope.bridge_owner, owner) { return false }
	}
	for _, buf in s.buffers {
		if same_bridge_authority(buf.bridge_owner, owner) { return false }
	}
	_ := s.retire_bridge_authority_unlocked(mut owner)
	return true
}

// Caller holds mu through paired registry cleanup. Removing scopes and buffers
// also invalidates HTTP completion, rollover, finish and failure publications.
pub fn (mut s FeishuState) retire_bridge_authority_unlocked(mut owner BridgeAuthority) []WireStreamRelease {
	owner.retired = true
	owner.creations.clear()
	mut scopes := map[string]string{}
	for token, grant in s.creation_grants {
		if same_bridge_authority(grant.bridge_owner, owner) {
			scopes[grant.stream_id] = grant.generation
			s.creation_grants.delete(token)
		}
	}
	for id, grant in s.creation_issues {
		if same_bridge_authority(grant.bridge_owner, owner) { s.creation_issues.delete(id) }
	}
	for stream, scope in s.initial_send_scopes {
		if same_bridge_authority(scope.bridge_owner, owner) {
			scopes[stream] = scope.generation
			s.initial_send_scopes.delete(stream)
		}
	}
	mut released := []WireStreamRelease{}
	for id, buf in s.buffers {
		if !same_bridge_authority(buf.bridge_owner, owner) { continue }
		scopes[buf.stream_id] = buf.generation
		s.note_initial_send_message_unlocked(id)
		s.buffers.delete(id)
		released << WireStreamRelease{ stream_id: buf.stream_id, generation: buf.generation, message_ids: [id] }
	}
	for stream, generation in scopes {
		mut remaining := stream in s.initial_send_scopes
		for _, buf in s.buffers { if buf.stream_id == stream { remaining = true } }
		for _, grant in s.creation_grants { if grant.stream_id == stream { remaining = true } }
		for _, issue in s.creation_issues { if issue.stream_id == stream { remaining = true } }
		if !remaining {
			released << WireStreamRelease{ stream_id: stream, generation: generation, retire_route: true }
		}
	}
	return released
}

pub fn (mut s FeishuState) bridge_request_allowed(owner &BridgeAuthority, action string, stream string, app string, generation string, target string) bool {
	s.mu.@lock()
	defer { s.mu.unlock() }
	if !bridge_authority_live(owner) { return false }
	if action in ['create', 'revoke_creation', 'clear', 'update', 'bind'] { return true }
	if stream.trim_space() == '' && action == 'send' { return false }
	if scope := s.initial_send_scopes[stream] {
		if action == 'send' && scope.generation == generation && creation_app(scope.app_name) == creation_app(app) && same_bridge_authority(scope.bridge_owner, owner) {
			return true
		}
	}
	if buf := s.buffers[target] {
		return buf.stream_id == stream && buf.generation == generation && creation_app(buf.app) == creation_app(app) && (buf.bridge_owner == none || same_bridge_authority(buf.bridge_owner, owner))
	}
	// On the remote endpoint the initial ticket has not been consumed yet.
	for _, grant in s.creation_grants {
		if action == 'send' && grant.stream_id == stream && grant.generation == generation && grant.app_name == creation_app(app) && (grant.bridge_owner == none || same_bridge_authority(grant.bridge_owner, owner)) {
			return true
		}
	}
	return false
}

pub fn (mut s FeishuState) complete_bridge_creation_issue(issue CreationIssue, lease CreationLease, owner &BridgeAuthority) ! {
	s.mu.@lock()
	defer { s.mu.unlock() }
	if !bridge_authority_live(owner) { return error('bridge_authority_retired') }
	s.complete_creation_issue_unlocked(issue, lease)!
	grant := s.creation_grants[lease.token] or { return error('feishu_creation_retired') }
	s.creation_grants[lease.token] = CreationGrant{ ...grant, bridge_owner: owner }
}

pub fn (mut s FeishuState) release_bridge_stream_unlocked(owner &BridgeAuthority, target string, stream string, app string, generation string) ?WireStreamRelease {
	if !bridge_authority_live(owner) { return none }
	mut owned := false
	if buf := s.buffers[target] {
		owned = same_bridge_authority(buf.bridge_owner, owner) && buf.generation == generation
	} else if target == '' {
		for _, buf in s.buffers {
			if buf.stream_id == stream && buf.generation == generation && same_bridge_authority(buf.bridge_owner, owner) {
				owned = true
			}
		}
		if scope := s.initial_send_scopes[stream] {
			if scope.generation == generation && same_bridge_authority(scope.bridge_owner, owner) {
				owned = true
			}
		}
	}
	for _, grant in s.creation_grants {
		if grant.stream_id == stream && grant.generation == generation && (target == '' || grant.message_id == target) && same_bridge_authority(grant.bridge_owner, owner) {
			owned = true
		}
	}
	if !owned { return none }
	return s.release_wire_stream_unlocked(target, stream, app, generation)
}

pub fn (mut s FeishuState) admit_bridge_initial_creation(owner &BridgeAuthority, stream string, app string, generation string, token string) ?InitialSend {
	s.mu.@lock()
	defer { s.mu.unlock() }
	if !bridge_authority_live(owner) { return none }
	if stream != '' {
		grant := s.creation_grants[token] or { return none }
		if grant.stream_id != stream || grant.generation != generation || grant.app_name != creation_app(app) || grant.message_id != '' || grant.expires_at <= time.now().unix() {
			return none
		}
		if grant.bridge_owner != none && !same_bridge_authority(grant.bridge_owner, owner) {
			return none
		}
		s.creation_grants[token] = CreationGrant{ ...grant, bridge_owner: owner }
	}
	return s.admit_wire_initial_creation_unlocked(stream, app, generation, token)
}

fn bridge_authority_live(owner &BridgeAuthority) bool {
	return !owner.retired && (owner.deadline == 0 || owner.deadline > time.now().unix())
}

pub fn (mut s FeishuState) start_bridge_lease(mut owner BridgeAuthority) {
	s.mu.@lock()
	owner.deadline = time.now().unix() + 45
	s.mu.unlock()
}

pub fn (mut s FeishuState) touch_bridge_lease(mut owner BridgeAuthority) bool {
	s.mu.@lock()
	defer { s.mu.unlock() }
	if !bridge_authority_live(owner) { return false }
	owner.deadline = time.now().unix() + 45
	return true
}

pub fn (mut s FeishuState) bridge_lease_expired(owner &BridgeAuthority) bool {
	s.mu.@lock()
	defer { s.mu.unlock() }
	return !bridge_authority_live(owner)
}

pub struct BridgeBinding {
pub:
	owner      ?&BridgeAuthority
	generation string
	stream     string
	app        string
}

// Capture before first-bind consumption or replacement removes old ownership.
pub fn (s &FeishuState) wire_bind_bridge_binding_unlocked(message string, token string) BridgeBinding {
	if buf := s.buffers[message] {
		return BridgeBinding{ owner: buf.bridge_owner, generation: buf.bridge_generation, stream: buf.bridge_stream, app: buf.bridge_app }
	}
	if grant := s.creation_grants[token] {
		return BridgeBinding{ owner: grant.bridge_owner, generation: grant.generation, stream: grant.stream_id, app: grant.app_name }
	}
	return BridgeBinding{}
}

pub fn (mut s FeishuState) retain_bridge_binding_unlocked(message string, binding BridgeBinding) {
	mut buf := s.buffers[message] or { return }
	buf.bridge_owner = binding.owner
	buf.bridge_generation = binding.generation
	buf.bridge_stream = binding.stream
	buf.bridge_app = binding.app
	s.buffers[message] = buf
}
