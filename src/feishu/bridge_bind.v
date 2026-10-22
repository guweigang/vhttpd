module feishu

// The old scope remains withdrawable during IO, but cannot admit commands or
// publish asynchronous work. Identity fences clear, replacement and disconnect.
pub struct BridgeBind {
pub:
	publication_id string
	message        string
	stream         string
	app            string
	source         BridgeBinding
	expected       string
	creation       string
	token          string
	buffer         StreamBuffer
}

// Registration invalidates stream-wide creators. A target CAS alone must not
// authorize cancelling creators belonging to another connection or app.
fn (s &FeishuState) bridge_bind_scope_owned_unlocked(owner &BridgeAuthority, stream string, app string) bool {
	if scope := s.initial_send_scopes[stream] {
		if !same_bridge_authority(scope.bridge_owner, owner) || creation_app(scope.app_name) != creation_app(app) {
			return false
		}
	}
	for _, buf in s.buffers {
		if buf.stream_id == stream && (!same_bridge_authority(buf.bridge_owner, owner) || creation_app(buf.app) != creation_app(app)) {
			return false
		}
	}
	for _, grant in s.creation_grants {
		if grant.stream_id == stream && (!same_bridge_authority(grant.bridge_owner, owner) || grant.app_name != creation_app(app)) {
			return false
		}
	}
	// An outstanding issuance has not acquired remote ownership yet. Wait for
	// it to finish instead of deleting its reservation during registration.
	for _, issue in s.creation_issues {
		if issue.stream_id == stream { return false }
	}
	return true
}

pub fn (mut s FeishuState) begin_bridge_bind_unlocked(message string, stream string, app string, expected string, creation string, token string) ?BridgeBind {
	source := s.wire_bind_bridge_binding_unlocked(message, token)
	owner := source.owner or { return none }
	if !bridge_authority_live(owner) { return none }
	if !s.bridge_bind_scope_owned_unlocked(owner, stream, app)
		|| !s.bridge_bind_scope_owned_unlocked(owner, source.stream, source.app) {
		return none
	}
	existing := message in s.buffers
	if !s.admit_wire_bind_unlocked(message, stream, app, expected, creation, token) { return none }
	if !existing {
		s.register_stream_buffer_unlocked(message, stream, app, '', '', '')
		s.retain_bridge_binding_unlocked(message, source)
	}
	mut buf := s.buffers[message] or { return none }
	if !existing { buf.generation = creation }
	buf.bind_pending = true
	// Invalidate already captured publishers even after this reservation ends.
	buf.identity = &StreamBufferIdentity{}
	s.buffers[message] = buf
	return BridgeBind{
		message:  message
		stream:   stream
		app:      app
		source:   source
		expected: if existing { source.generation } else { '' }
		creation: creation
		token:    token
		buffer:   buf
	}
}

fn (s &FeishuState) bridge_bind_current_unlocked(claim BridgeBind) bool {
	active := s.buffers[claim.message] or { return false }
	owner := claim.source.owner or { return false }
	identity := active.identity or { return false }
	captured := claim.buffer.identity or { return false }
	return active.bind_pending && voidptr(identity) == voidptr(captured)
		&& same_bridge_authority(active.bridge_owner, owner) && bridge_authority_live(owner)
}

pub fn (mut s FeishuState) complete_bridge_bind_unlocked(claim BridgeBind, generation string) bool {
	if generation == '' || !s.bridge_bind_current_unlocked(claim) { return false }
	owner := claim.source.owner or { return false }
	if !s.bridge_bind_scope_owned_unlocked(owner, claim.stream, claim.app)
		|| !s.bridge_bind_scope_owned_unlocked(owner, claim.source.stream, claim.source.app) {
		return false
	}
	s.register_stream_buffer_unlocked(claim.message, claim.stream, claim.app, '', '', '')
	mut buf := s.buffers[claim.message] or { return false }
	buf.bridge_replica = true
	buf.generation = generation
	s.buffers[claim.message] = buf
	s.retain_bridge_binding_unlocked(claim.message, BridgeBinding{
		owner:      claim.source.owner
		generation: generation
		stream:     claim.stream
		app:        claim.app
	})
	return true
}

pub fn (mut s FeishuState) abort_bridge_bind_unlocked(claim BridgeBind) ?WireStreamRelease {
	// Retirement may already have removed this owner; never look up a successor.
	active := s.buffers[claim.message] or { return none }
	identity := active.identity or { return none }
	captured := claim.buffer.identity or { return none }
	if !active.bind_pending || voidptr(identity) != voidptr(captured) { return none }
	return s.release_wire_stream_unlocked(claim.message, active.stream_id, active.app, active.generation)
}

// Exact source CAS / one-use first-bind grant. Replaying this operation after
// publication or clear cannot recreate the old target. Caller holds mu; the
// initiating host publishes Codex targets only after accepting the remote ACK.
pub fn (mut s FeishuState) publish_bridge_bind_unlocked(owner &BridgeAuthority, message string, stream string, app string, expected string, source_stream string, source_app string, creation string, token string) ?string {
	if !bridge_authority_live(owner) || message == '' || stream == '' { return none }
	if !s.bridge_bind_scope_owned_unlocked(owner, stream, app)
		|| !s.bridge_bind_scope_owned_unlocked(owner, source_stream, source_app) {
		return none
	}
	if buf := s.buffers[message] {
		if !same_bridge_authority(buf.bridge_owner, owner) || buf.stream_id != source_stream || creation_app(buf.app) != creation_app(source_app) {
			return none
		}
	} else {
		grant := s.creation_grants[token] or { return none }
		if !same_bridge_authority(grant.bridge_owner, owner) { return none }
	}
	if !s.admit_wire_bind_unlocked(message, stream, app, expected, creation, token) { return none }
	s.register_stream_buffer_unlocked(message, stream, app, '', '', '')
	generation := s.stream_generation_unlocked(message)
	s.retain_bridge_binding_unlocked(message, BridgeBinding{
		owner:      owner
		generation: generation
		stream:     stream
		app:        app
	})
	return generation
}
