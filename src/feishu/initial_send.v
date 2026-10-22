module feishu

@[heap]
struct InitialSendOwner {}

@[heap]
struct InitialSendScope {
	owner      &InitialSendOwner @[required]
	generation string
	app_name   string
mut:
	bridge_owner ?&BridgeAuthority
	pending      int
}

@[heap]
struct InitialSendRegistration {
	scope &InitialSendScope @[required]
mut:
	released  bool
	published bool
}

// An HTTP operation retains publication admission, never a borrowed buffer.
pub struct InitialSend {
	registration &InitialSendRegistration @[required]
	sequence     u64
	stream_id    string
}

pub fn (mut s FeishuState) begin_initial_send(stream_id string) InitialSend {
	s.mu.@lock()
	defer { s.mu.unlock() }
	return s.begin_initial_send_unlocked(stream_id, '', '')
}

fn (mut s FeishuState) begin_initial_send_unlocked(stream_id string, app_name string, generation string) InitialSend {
	mut scope := s.initial_send_scopes[stream_id] or { &InitialSendScope{ owner: s.initial_send_owner, generation: generation, app_name: app_name } }
	if stream_id != '' {
		scope.pending++
		s.initial_send_scopes[stream_id] = scope
		s.initial_send_count++
	}
	return InitialSend{
		stream_id:    stream_id
		sequence:     s.initial_send_sequence
		registration: &InitialSendRegistration{ scope: scope }
	}
}

// Completion/error releases only this operation. Copies cannot release peers.
pub fn (mut s FeishuState) finish_initial_send(claim InitialSend) {
	s.mu.@lock()
	defer { s.mu.unlock() }
	mut registration := claim.registration
	if voidptr(registration.scope.owner) != voidptr(s.initial_send_owner) { return }
	if registration.released { return }
	registration.released = true
	if claim.stream_id == '' { return }
	mut scope := registration.scope
	scope.pending--
	if current := s.initial_send_scopes[claim.stream_id] {
		if scope.pending == 0 && voidptr(scope) == voidptr(current) {
			s.initial_send_scopes.delete(claim.stream_id)
		}
	}
	s.initial_send_count--
	if s.initial_send_count == 0 {
		s.initial_send_mutations.clear()
		s.initial_send_sequence = 0
	}
}

// Caller holds mu. Removing admission also works before any buffer exists.
pub fn (mut s FeishuState) revoke_initial_sends_unlocked(stream_id string) bool {
	if stream_id == '' || stream_id !in s.initial_send_scopes { return false }
	s.initial_send_scopes.delete(stream_id)
	return true
}

fn (mut s FeishuState) note_initial_send_message_unlocked(message_id string) {
	// Outstanding first-bind grants also retain physical publication ownership.
	s.revoke_bind_creations_unlocked(message_id)
	if message_id == '' || s.initial_send_count == 0 { return }
	s.initial_send_sequence++
	s.initial_send_mutations[message_id] = s.initial_send_sequence
}

// Reserved producer namespace: replies spend creation authority but never own a
// streaming buffer or Codex target. Cleanup is optional after send completion.
pub fn is_one_shot_reply_stream(stream_id string) bool {
	return stream_id.starts_with('feishu:reply:') && stream_id.len > 'feishu:reply:'.len
}

fn (s &FeishuState) initial_send_can_complete_unlocked(claim InitialSend, message_id string) bool {
	mut registration := claim.registration
	if voidptr(registration.scope.owner) != voidptr(s.initial_send_owner) { return false }
	if registration.released || registration.published || claim.stream_id == '' || message_id.trim_space() == '' {
		return false
	}
	current := s.initial_send_scopes[claim.stream_id] or { return false }
	if voidptr(current) != voidptr(registration.scope) || message_id in s.buffers
		|| s.initial_send_mutations[message_id] > claim.sequence {
		return false
	}
	if owner := registration.scope.bridge_owner {
		if !bridge_authority_live(owner) { return false }
	}
	return true
}

// Caller holds mu. HTTP results still need the original scope, physical ID and
// live bridge owner; success does not publish any resource requiring later clear.
pub fn (mut s FeishuState) complete_initial_reply_unlocked(claim InitialSend, message_id string, generation string) bool {
	if !is_one_shot_reply_stream(claim.stream_id) || generation == ''
		|| claim.registration.scope.generation != generation
		|| !s.initial_send_can_complete_unlocked(claim, message_id) {
		return false
	}
	// Retain only the existing in-flight mutation fence: a peer's older HTTP
	// result or first-bind grant must not claim this physical reply afterward.
	s.note_initial_send_message_unlocked(message_id)
	mut registration := claim.registration
	registration.published = true
	return true
}

// Caller holds mu through any paired target publication. A result ID touched
// since admission remains unavailable even if its replacement was deleted.
pub fn (mut s FeishuState) commit_initial_send_unlocked(claim InitialSend, message_id string, app_name string, receive_id string, receive_id_type string, content string) bool {
	if !s.initial_send_can_complete_unlocked(claim, message_id) { return false }
	mut registration := claim.registration
	registration.published = true
	s.register_stream_buffer_content_unlocked(message_id, claim.stream_id, app_name, receive_id, receive_id_type, content)
	mut buf := s.buffers[message_id] or { return false }
	buf.bridge_owner = registration.scope.bridge_owner
	buf.bridge_generation = registration.scope.generation
	buf.bridge_stream = claim.stream_id
	buf.bridge_app = app_name
	s.buffers[message_id] = buf
	return true
}

// A producer may allocate a fresh stream generation before sending its placeholder,
// so following commands in the same batch can carry it. Bridge mirrors retain the
// remote receipt's generation. This runs only after local publication admission.
pub fn (mut s FeishuState) commit_initial_send_generation_unlocked(claim InitialSend, message_id string, app_name string, receive_id string, receive_id_type string, content string, generation string) bool {
	if claim.registration.scope.generation != '' && generation != claim.registration.scope.generation {
		return false
	}
	if !s.commit_initial_send_unlocked(claim, message_id, app_name, receive_id, receive_id_type, content) {
		return false
	}
	if generation != '' {
		mut buf := s.buffers[message_id] or { return false }
		buf.generation = generation
		s.buffers[message_id] = buf
	}
	return true
}
