module feishu

import crypto.rand
import time

pub struct ExternalCreationRequest {
pub:
	epoch      string
	request_id string
	issued_at  i64
	stream_id  string
	instance   string
	kind       string
	message_id string
}

pub struct ExternalCreationDiscovery {
pub:
	epoch     string
	issued_at i64
}

@[heap]
struct ExternalCreationMemo {
	request    ExternalCreationRequest
	issue      CreationIssue
	expires_at i64
mut:
	pending      bool = true
	bridge_owner ?&BridgeAuthority
	lease        CreationLease
	failure      string
}

pub struct ExternalCreationAttempt {
	memo &ExternalCreationMemo @[required]
pub:
	cached bool
	lease  CreationLease
}

pub fn (mut s FeishuState) external_creation_discovery() !ExternalCreationDiscovery {
	s.mu.@lock()
	defer { s.mu.unlock() }
	s.prune_creations_unlocked(time.now().unix())
	if s.external_creation_epoch == '' { s.external_creation_epoch = (rand.bytes(32)!).hex() }
	return ExternalCreationDiscovery{ epoch: s.external_creation_epoch, issued_at: time.now().unix() }
}

pub fn (mut s FeishuState) begin_external_creation(req ExternalCreationRequest) !ExternalCreationAttempt {
	s.mu.@lock()
	defer { s.mu.unlock() }
	now := time.now().unix()
	s.validate_external_request_unlocked(req, now)!
	if memo := s.external_creation_memos[req.request_id] {
		if memo.request != req { return error('feishu_creation_request_conflict') }
		if memo.pending { return error('feishu_creation_pending') }
		if memo.failure != '' { return error(memo.failure) }
		return ExternalCreationAttempt{ memo: memo, cached: true, lease: memo.lease }
	}
	if s.external_creation_memos.len >= creation_limit { return error('feishu_creation_capacity') }
	issue := s.begin_creation_issue_unlocked(req.stream_id, req.instance, req.message_id, now) or {
		s.external_creation_memos[req.request_id] = &ExternalCreationMemo{
			request:    req
			expires_at: req.issued_at + creation_lifetime_seconds
			pending:    false
			failure:    err.msg()
		}
		return err
	}
	mut owner := s.creation_issues[issue.id] or { return error('feishu_creation_retired') }
	owner = CreationGrant{ ...owner, expires_at: req.issued_at + creation_lifetime_seconds }
	s.creation_issues[issue.id] = owner
	memo := &ExternalCreationMemo{ request: req, issue: issue, expires_at: owner.expires_at }
	s.external_creation_memos[req.request_id] = memo
	return ExternalCreationAttempt{ memo: memo }
}

fn (mut s FeishuState) validate_external_request_unlocked(req ExternalCreationRequest, now i64) ! {
	s.prune_creations_unlocked(now)
	if req.epoch == '' || req.epoch != s.external_creation_epoch {
		return error('feishu_creation_epoch')
	}
	if req.issued_at > now || req.issued_at + creation_lifetime_seconds <= now {
		return error('feishu_creation_expired')
	}
	if req.request_id.len != 64 || req.request_id.bytes().any(it !in '0123456789abcdef'.bytes()) || req.stream_id.trim_space() == '' || req.stream_id.len > 1024 || req.instance.len > 128 || req.message_id.len > 1024 || req.kind !in [
		'send',
		'bind',
	] || (req.kind == 'bind' && req.message_id.trim_space() == '') || (req.kind == 'send' && req.message_id != '') {
		return error('feishu_creation_request')
	}
}

fn (s &FeishuState) external_attempt_current_unlocked(attempt ExternalCreationAttempt) bool {
	memo := s.external_creation_memos[attempt.memo.request.request_id] or { return false }
	return voidptr(memo) == voidptr(attempt.memo) && memo.pending && memo.expires_at > time.now().unix()
}

// Failure is terminal for this issuance intent. A retry cannot mint a different
// token after timeout, withdrawal, consumption or a process restart.
pub fn (mut s FeishuState) finish_external_creation(attempt ExternalCreationAttempt) {
	s.mu.@lock()
	defer { s.mu.unlock() }
	s.prune_creations_unlocked(time.now().unix())
	if !s.external_attempt_current_unlocked(attempt) { return }
	mut memo := attempt.memo
	if memo.pending {
		memo.pending = false
		memo.failure = 'feishu_creation_retired'
		s.creation_issues.delete(memo.issue.id)
	}
}

pub fn (mut s FeishuState) complete_external_local(attempt ExternalCreationAttempt) !CreationLease {
	s.mu.@lock()
	defer { s.mu.unlock() }
	if !s.external_attempt_current_unlocked(attempt) { return error('feishu_creation_retired') }
	mut memo := attempt.memo
	owner := s.creation_issues[memo.issue.id] or { return error('feishu_creation_retired') }
	if owner.expires_at <= time.now().unix() { return error('feishu_creation_expired') }
	s.creation_issues.delete(memo.issue.id)
	lease := s.issue_wire_creation_unlocked(owner.stream_id, owner.app_name, owner.message_id, time.now().unix())!
	grant := s.creation_grants[lease.token] or { return error('feishu_creation_retired') }
	s.creation_grants[lease.token] = CreationGrant{ ...grant, expires_at: memo.expires_at }
	memo.lease = lease
	memo.pending = false
	return lease
}

pub fn (mut s FeishuState) complete_external_remote(attempt ExternalCreationAttempt, lease CreationLease) !CreationLease {
	return s.complete_external_remote_owned(attempt, lease, none)
}

pub fn (mut s FeishuState) complete_external_remote_owned(attempt ExternalCreationAttempt, lease CreationLease, owner ?&BridgeAuthority) !CreationLease {
	s.mu.@lock()
	defer { s.mu.unlock() }
	if !s.external_attempt_current_unlocked(attempt) { return error('feishu_creation_retired') }
	mut memo := attempt.memo
	if current := owner {
		if !bridge_authority_live(current) { return error('bridge_authority_retired') }
	}
	s.complete_creation_issue_unlocked(memo.issue, lease)!
	grant := s.creation_grants[lease.token] or { return error('feishu_creation_retired') }
	s.creation_grants[lease.token] = CreationGrant{ ...grant, bridge_owner: owner }
	memo.bridge_owner = owner
	memo.lease = lease
	memo.pending = false
	return lease
}

pub fn (mut s FeishuState) revoke_external_creation(req ExternalCreationRequest) !CreationLease {
	s.mu.@lock()
	defer { s.mu.unlock() }
	s.validate_external_request_unlocked(req, time.now().unix())!
	mut memo := s.external_creation_memos[req.request_id] or {
		if s.external_creation_memos.len >= creation_limit {
			return error('feishu_creation_capacity')
		}
		s.external_creation_memos[req.request_id] = &ExternalCreationMemo{
			request:    req
			expires_at: req.issued_at + creation_lifetime_seconds
			pending:    false
			failure:    'feishu_creation_retired'
		}
		return CreationLease{}
	}
	if memo.request != req { return error('feishu_creation_request_conflict') }
	s.creation_issues.delete(memo.issue.id)
	s.creation_grants.delete(memo.lease.token)
	memo.pending = false
	memo.failure = 'feishu_creation_retired'
	return memo.lease
}

pub fn (mut s FeishuState) external_creation_authority(req ExternalCreationRequest) ?&BridgeAuthority {
	s.mu.@lock()
	defer { s.mu.unlock() }
	memo := s.external_creation_memos[req.request_id] or { return none }
	if memo.request != req { return none }
	return memo.bridge_owner
}
