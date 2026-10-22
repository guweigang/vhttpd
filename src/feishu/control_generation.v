module feishu

import time

pub struct WireStreamRelease {
pub:
	bridge_owner      ?&BridgeAuthority
	bridge_generation string
	bridge_stream     string
	bridge_app        string
	generation        string
	stream_id         string
	message_ids       []string
	retire_route      bool
}

// Caller holds mu across the paired target publication. Replacement needs the
// generation observed by the producer, never a fresh lookup at ingress.
pub fn (s &FeishuState) wire_bind_is_current_unlocked(message_id string, generation string) bool {
	if current := s.buffers[message_id] {
		if current.bind_pending { return false }
		if owner := current.bridge_owner {
			if !bridge_authority_live(owner) { return false }
		}
		return generation != '' && generation == current.generation
	}
	return generation == ''
}

// Select, validate and retire under one lock. A stale target cannot revoke
// pending sends or expand its authority into another generation's successors.
pub fn (mut s FeishuState) release_wire_stream_unlocked(message_id string, stream_id string, app_name string, generation string) ?WireStreamRelease {
	s.prune_creations_unlocked(time.now().unix())
	if generation == '' { return none }
	mut stream := stream_id
	mut owner_app := app_name
	mut ids := []string{}
	mut bridge_owner := ?&BridgeAuthority(none)
	mut bridge_generation := generation
	mut bridge_stream := stream_id
	mut bridge_app := app_name
	if message_id != '' {
		root := s.buffers[message_id] or { return s.release_unbound_creation_unlocked(message_id, stream_id, app_name, generation) }
		if root.generation != generation || (stream != '' && root.stream_id != stream)
			|| (app_name != '' && root.app != app_name) {
			return none
		}
		bridge_owner = root.bridge_owner
		bridge_generation = root.bridge_generation
		bridge_stream = root.bridge_stream
		bridge_app = root.bridge_app
		stream = root.stream_id
		owner_app = root.app
		mut current := root
		mut visited := map[string]bool{}
		for current.message_id !in visited {
			if current.stream_id != stream || current.app != root.app || current.generation != generation {
				break
			}
			visited[current.message_id] = true
			ids << current.message_id
			next := s.buffers[current.next_message_id] or { break }
			if expected := current.next_identity {
				actual := next.identity or { break }
				if voidptr(expected) != voidptr(actual) { break }
			}
			current = next
		}
	} else {
		if stream == '' { return none }
		for id, buf in s.buffers {
			if buf.stream_id == stream && buf.generation == generation && (app_name == '' || buf.app == app_name) {
				bridge_owner = buf.bridge_owner
				bridge_generation = buf.bridge_generation
				bridge_stream = buf.bridge_stream
				bridge_app = buf.bridge_app
				ids << id
			}
		}
	}
	mut revoked := false
	if message_id == '' {
		if scope := s.initial_send_scopes[stream] {
			if scope.generation == generation && (owner_app == '' || scope.app_name == owner_app) {
				bridge_owner = scope.bridge_owner
				s.initial_send_scopes.delete(stream)
				revoked = true
			}
		}
	}
	if message_id == '' {
		for token, grant in s.creation_grants {
			if grant.generation == generation && grant.stream_id == stream && (owner_app == '' || grant.app_name == creation_app(owner_app)) {
				bridge_owner = grant.bridge_owner
				s.creation_grants.delete(token)
				revoked = true
			}
		}
	}
	if ids.len == 0 && !revoked { return none }
	for id in ids {
		s.note_initial_send_message_unlocked(id)
		s.buffers.delete(id)
	}
	mut remaining := false
	for _, buf in s.buffers {
		if buf.stream_id == stream {
			remaining = true
			break
		}
	}
	if stream in s.initial_send_scopes { remaining = true }
	mut generation_remaining := false
	for _, buf in s.buffers {
		if buf.stream_id == stream && buf.generation == generation && (owner_app == '' || buf.app == owner_app) {
			generation_remaining = true
		}
	}
	if scope := s.initial_send_scopes[stream] {
		if scope.generation == generation && (owner_app == '' || creation_app(scope.app_name) == creation_app(owner_app)) {
			generation_remaining = true
		}
	}
	if message_id == '' || !generation_remaining {
		for token, grant in s.creation_grants {
			if grant.stream_id == stream && grant.generation == generation && (owner_app == '' || grant.app_name == creation_app(owner_app)) {
				s.creation_grants.delete(token)
			}
		}
		for id, issue in s.creation_issues {
			if issue.stream_id == stream && (issue.generation == '' || issue.generation == generation) && (owner_app == '' || issue.app_name == creation_app(owner_app)) {
				s.creation_issues.delete(id)
			}
		}
	}
	for _, grant in s.creation_grants { if grant.stream_id == stream { remaining = true } }
	for _, issue in s.creation_issues { if issue.stream_id == stream { remaining = true } }
	return WireStreamRelease{ bridge_owner: bridge_owner, bridge_generation: bridge_generation, bridge_stream: bridge_stream, bridge_app: bridge_app, stream_id: stream, message_ids: ids, retire_route: !remaining, generation: generation }
}

// Trusted/internal scope helper retained for callers that already own creation
// authority. Wire ingress must use admit_wire_initial_creation to spend a ticket.
pub fn (mut s FeishuState) begin_wire_initial_send(stream_id string, app_name string, generation string) ?InitialSend {
	s.mu.@lock()
	defer { s.mu.unlock() }
	if stream_id != '' {
		if scope := s.initial_send_scopes[stream_id] {
			if scope.generation != generation || scope.app_name != app_name { return none }
		}
		for _, buf in s.buffers {
			if buf.stream_id == stream_id && (generation == '' || buf.generation != generation || (app_name != '' && buf.app != '' && buf.app != app_name)) {
				return none
			}
		}
	}
	return s.begin_initial_send_unlocked(stream_id, app_name, generation)
}
