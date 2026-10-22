module feishu

import rand
import crypto.rand as crypto_rand
import time

const creation_limit = 4096
const creation_lifetime_seconds = 300

// Only outstanding, expiring grants are retained. A consumed/revoked UUID is
// absent forever; ingress cannot issue it again from a command's generation.
pub struct CreationLease {
pub:
	generation string
	token      string
}

struct CreationGrant {
	bridge_owner ?&BridgeAuthority
	message_id   string
	generation   string
	stream_id    string
	app_name     string
	expires_at   i64
}

fn creation_app(app_name string) string {
	return if app_name == '' { 'main' } else { app_name }
}

// Reuse the provider's existing maintenance run and trusted ingress paths.
// Expiration removes authority, never a live buffer or an admitted HTTP claim.
pub fn (mut s FeishuState) prune_expired_creations() {
	s.mu.@lock()
	defer { s.mu.unlock() }
	s.prune_creations_unlocked(time.now().unix())
}

fn (mut s FeishuState) prune_creations_unlocked(now i64) {
	for id, grant in s.creation_grants {
		if grant.expires_at <= now {
			s.creation_grants.delete(id)
		} else if owner := grant.bridge_owner {
			if !bridge_authority_live(owner) { s.creation_grants.delete(id) }
		}
	}
	for id, grant in s.creation_issues {
		if grant.expires_at <= now { s.creation_issues.delete(id) }
	}
	// These memos are replay evidence as well as cached responses. Retain live
	// failures/revocations until the ORIGINAL request can no longer be accepted.
	for id, memo in s.external_creation_memos {
		if memo.expires_at <= now { s.external_creation_memos.delete(id) }
	}
}

// Trusted producer capability, never called by bind/send admission. A fresh
// lifecycle gets a server generation; each operation gets a one-use token.
pub fn (mut s FeishuState) issue_wire_creation(stream_id string, app_name string) !CreationLease {
	return s.issue_wire_creation_for_target(stream_id, app_name, '')
}

pub fn (mut s FeishuState) issue_wire_creation_for_target(stream_id string, app_name string, message_id string) !CreationLease {
	s.mu.@lock()
	defer { s.mu.unlock() }
	return s.issue_wire_creation_unlocked(stream_id, app_name, message_id, time.now().unix())
}

fn (mut s FeishuState) issue_wire_creation_unlocked(stream_id string, app_name string, message_id string, now i64) !CreationLease {
	return s.issue_wire_creation_owned_unlocked(stream_id, app_name, message_id, none, now)
}

fn (mut s FeishuState) issue_wire_creation_owned_unlocked(stream_id string, app_name string, message_id string, bridge_owner ?&BridgeAuthority, now i64) !CreationLease {
	s.prune_creations_unlocked(now)
	if message_id != '' && message_id in s.buffers { return error('feishu_creation_target_owned') }
	if stream_id == '' {
		return error('feishu_creation_stream_owned')
	}
	if s.creation_grants.len + s.creation_issues.len >= creation_limit {
		return error('feishu_creation_capacity')
	}
	mut generation := ''
	if message_id == '' {
		if scope := s.initial_send_scopes[stream_id] {
			if !same_bridge_authority(scope.bridge_owner, bridge_owner) || creation_app(scope.app_name) != creation_app(app_name) {
				return error('feishu_creation_app_conflict')
			}
			generation = scope.generation
		}
		for _, buf in s.buffers {
			if buf.stream_id == stream_id {
				if !same_bridge_authority(buf.bridge_owner, bridge_owner) || creation_app(buf.app) != creation_app(app_name) || (generation != '' && generation != buf.generation) {
					return error('feishu_creation_owner_conflict')
				}
				generation = buf.generation
			}
		}
		for _, grant in s.creation_grants {
			if grant.message_id != '' { continue }
			if grant.stream_id == stream_id {
				if !same_bridge_authority(grant.bridge_owner, bridge_owner) || grant.app_name != creation_app(app_name) || (generation != '' && generation != grant.generation) {
					return error('feishu_creation_owner_conflict')
				}
				generation = grant.generation
			}
		}
	}
	if generation == '' { generation = rand.uuid_v4() }
	token := (crypto_rand.bytes(32)!).hex()
	s.creation_grants[token] = CreationGrant{
		bridge_owner: bridge_owner
		generation:   generation
		message_id:   message_id
		stream_id:    stream_id
		app_name:     creation_app(app_name)
		expires_at:   now + creation_lifetime_seconds
	}
	return CreationLease{ generation: generation, token: token }
}

fn (mut s FeishuState) consume_creation_unlocked(stream_id string, app_name string, generation string, token string) bool {
	grant := s.creation_grants[token] or { return false }
	if owner := grant.bridge_owner {
		if !bridge_authority_live(owner) { return false }
	}
	if grant.expires_at <= time.now().unix() {
		s.creation_grants.delete(token)
		return false
	}
	if grant.generation != generation || grant.stream_id != stream_id || grant.app_name != creation_app(app_name) {
		return false
	}
	s.creation_grants.delete(token)
	return true
}

fn (mut s FeishuState) revoke_creations_unlocked(stream_id string) {
	for id, grant in s.creation_grants {
		if grant.stream_id == stream_id { s.creation_grants.delete(id) }
	}
	for id, grant in s.creation_issues {
		if grant.stream_id == stream_id { s.creation_issues.delete(id) }
	}
}

// Every streamed initial send spends a grant before HTTP, even if a prior
// placeholder exists. A retry needs its own fresh ticket, not its old ID.
pub fn (mut s FeishuState) admit_wire_initial_creation(stream_id string, app_name string, generation string, token string) ?InitialSend {
	s.mu.@lock()
	defer { s.mu.unlock() }
	return s.admit_wire_initial_creation_unlocked(stream_id, app_name, generation, token)
}

fn (mut s FeishuState) admit_wire_initial_creation_unlocked(stream_id string, app_name string, generation string, token string) ?InitialSend {
	if stream_id.trim_space() == '' { return none }
	grant := s.creation_grants[token] or { return none }
	if grant.message_id != '' { return none }
	if owner := grant.bridge_owner {
		if !bridge_authority_live(owner) { return none }
	}
	if !s.consume_creation_unlocked(stream_id, app_name, generation, token) { return none }
	if scope := s.initial_send_scopes[stream_id] {
		if scope.generation != generation || creation_app(scope.app_name) != creation_app(app_name) {
			return none
		}
	}
	for _, buf in s.buffers {
		if buf.stream_id == stream_id && (buf.generation != generation || creation_app(buf.app) != creation_app(app_name)) {
			return none
		}
	}
	claim := s.begin_initial_send_unlocked(stream_id, app_name, generation)
	mut scope := claim.registration.scope
	scope.bridge_owner = grant.bridge_owner
	return claim
}

// Replacement uses CAS; first bind spends a separate creation generation.
pub fn (mut s FeishuState) admit_wire_bind_unlocked(message_id string, stream_id string, app_name string, expected string, creation string, token string) bool {
	if message_id in s.buffers { return s.wire_bind_is_current_unlocked(message_id, expected) }
	if expected != '' { return false }
	grant := s.creation_grants[token] or { return false }
	if grant.message_id != message_id || message_id == '' { return false }
	return s.consume_creation_unlocked(stream_id, app_name, creation, token)
}

// An in-flight remote issuance retains its original local owner. Withdrawals
// cancel these temporary records as well as already returned tickets.
pub struct CreationIssue {
	id string
}

pub fn (mut s FeishuState) begin_creation_issue(stream_id string, app_name string) !CreationIssue {
	return s.begin_creation_issue_for_target(stream_id, app_name, '')
}

pub fn (mut s FeishuState) begin_creation_issue_for_target(stream_id string, app_name string, message_id string) !CreationIssue {
	s.mu.@lock()
	defer { s.mu.unlock() }
	return s.begin_creation_issue_unlocked(stream_id, app_name, message_id, time.now().unix())
}

fn (mut s FeishuState) begin_creation_issue_unlocked(stream_id string, app_name string, message_id string, now i64) !CreationIssue {
	s.prune_creations_unlocked(now)
	if stream_id == '' || s.creation_grants.len + s.creation_issues.len >= creation_limit {
		return error('feishu_creation_unavailable')
	}
	mut generation := ''
	if scope := s.initial_send_scopes[stream_id] {
		if creation_app(scope.app_name) != creation_app(app_name) {
			return error('feishu_creation_app_conflict')
		}
		generation = scope.generation
	}
	for _, buf in s.buffers {
		if buf.stream_id == stream_id {
			if creation_app(buf.app) != creation_app(app_name) || (generation != '' && generation != buf.generation) {
				return error('feishu_creation_owner_conflict')
			}
			generation = buf.generation
		}
	}
	for _, grant in s.creation_grants {
		if grant.message_id != '' { continue }
		if grant.stream_id == stream_id {
			if grant.app_name != creation_app(app_name) || (generation != '' && generation != grant.generation) {
				return error('feishu_creation_owner_conflict')
			}
			generation = grant.generation
		}
	}
	id := (crypto_rand.bytes(32)!).hex()
	if message_id != '' && message_id in s.buffers { return error('feishu_creation_target_owned') }
	s.creation_issues[id] = CreationGrant{
		message_id: message_id
		stream_id:  stream_id
		app_name:   creation_app(app_name)
		generation: generation
		expires_at: now + creation_lifetime_seconds
	}
	return CreationIssue{ id: id }
}

pub fn (mut s FeishuState) finish_creation_issue(issue CreationIssue) {
	s.mu.@lock()
	s.creation_issues.delete(issue.id)
	s.mu.unlock()
}

pub fn (mut s FeishuState) complete_creation_issue(issue CreationIssue, lease CreationLease) ! {
	s.mu.@lock()
	defer { s.mu.unlock() }
	return s.complete_creation_issue_unlocked(issue, lease)
}

fn (mut s FeishuState) complete_creation_issue_unlocked(issue CreationIssue, lease CreationLease) ! {
	owner := s.creation_issues[issue.id] or { return error('feishu_creation_retired') }
	s.creation_issues.delete(issue.id)
	if owner.expires_at <= time.now().unix() || lease.generation == '' || lease.token == '' || lease.token in s.creation_grants || (owner.message_id == '' && owner.generation != '' && owner.generation != lease.generation) {
		return error('feishu_creation_retired')
	}
	// Completing one issuance exchanges its reserved slot for one live ticket.
	s.creation_grants[lease.token] = CreationGrant{
		message_id: owner.message_id
		stream_id:  owner.stream_id
		app_name:   owner.app_name
		generation: lease.generation
		expires_at: owner.expires_at
	}
}

// Terminal cleanup cannot leave an unspent ticket as the last owner of a
// withdrawn generation. Already admitted peer sends retain their own scope.
fn (mut s FeishuState) retire_unused_creation_generation_unlocked(stream_id string, app_name string, generation string) {
	for _, buf in s.buffers {
		if buf.stream_id == stream_id && buf.generation == generation && creation_app(buf.app) == creation_app(app_name) {
			return
		}
	}
	if scope := s.initial_send_scopes[stream_id] {
		if scope.generation == generation && creation_app(scope.app_name) == creation_app(app_name) {
			return
		}
	}
	for token, grant in s.creation_grants {
		if grant.stream_id == stream_id && grant.generation == generation && grant.app_name == creation_app(app_name) {
			s.creation_grants.delete(token)
		}
	}
	for id, issue in s.creation_issues {
		if issue.stream_id == stream_id && (issue.generation == '' || issue.generation == generation) && issue.app_name == creation_app(app_name) {
			s.creation_issues.delete(id)
		}
	}
}

pub fn (mut s FeishuState) issue_wire_bind_creation(stream_id string, app_name string, message_id string) !CreationLease {
	s.mu.@lock()
	defer { s.mu.unlock() }
	if message_id == '' { return error('feishu_creation_target_required') }
	return s.issue_wire_creation_unlocked(stream_id, app_name, message_id, time.now().unix())
}

fn (mut s FeishuState) revoke_bind_creations_unlocked(message_id string) {
	if message_id == '' { return }
	for token, grant in s.creation_grants {
		if grant.message_id == message_id { s.creation_grants.delete(token) }
	}
	for id, issue in s.creation_issues {
		if issue.message_id == message_id { s.creation_issues.delete(id) }
	}
}

// A target can be cancelled before the first bind packet reaches ingress. Only
// a grant already issued for that physical target authorizes this transition.
fn (mut s FeishuState) release_unbound_creation_unlocked(message_id string, stream_id string, app_name string, generation string) ?WireStreamRelease {
	mut owner := CreationGrant{}
	mut found := false
	for _, grant in s.creation_grants {
		if grant.message_id == message_id && grant.generation == generation && (stream_id == '' || grant.stream_id == stream_id) && (app_name == '' || grant.app_name == creation_app(app_name)) {
			owner = grant
			found = true
			break
		}
	}
	if !found { return none }
	s.revoke_bind_creations_unlocked(message_id)
	mut remaining := owner.stream_id in s.initial_send_scopes
	for _, buf in s.buffers {
		if buf.stream_id == owner.stream_id { remaining = true }
	}
	for _, grant in s.creation_grants { if grant.stream_id == owner.stream_id { remaining = true } }
	for _, issue in s.creation_issues { if issue.stream_id == owner.stream_id { remaining = true } }
	return WireStreamRelease{ bridge_owner: owner.bridge_owner, bridge_generation: owner.generation, bridge_stream: owner.stream_id, bridge_app: owner.app_name, stream_id: owner.stream_id, generation: generation, retire_route: !remaining }
}

// Remove only the exact unspent capability; never a peer ticket or live scope.
pub fn (mut s FeishuState) revoke_wire_creation(stream_id string, app_name string, lease CreationLease) {
	s.mu.@lock()
	defer { s.mu.unlock() }
	grant := s.creation_grants[lease.token] or { return }
	if grant.stream_id == stream_id && grant.app_name == creation_app(app_name) && grant.generation == lease.generation {
		s.creation_grants.delete(lease.token)
	}
}
