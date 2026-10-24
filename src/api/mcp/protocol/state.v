module protocol

import time

// ── Session Lifecycle (must be called while s.mu is held) ──

// Caller holds mu. Check the selected session before refreshing its activity.
// Expiration cancels a stream, but physical close stays with finish_stream.
pub fn (mut s McpState) expire_session_locked(id string, now i64) bool {
	if s.stopping { return false }
	session := s.sessions[id] or { return false }
	ttl := if s.session_ttl_seconds > 0 { i64(s.session_ttl_seconds) } else { i64(900) }
	last_seen := if session.last_activity_unix > 0 {
		session.last_activity_unix
	} else {
		session.started_at_unix
	}
	if now - last_seen <= ttl { return false }
	if mut stream := session.stream { stream.request_stop() }
	s.sessions.delete(id)
	s.stat_sessions_expired_total++
	return true
}

pub fn (mut s McpState) prune_sessions_locked(now i64) {
	for id in s.sessions.keys() { s.expire_session_locked(id, now) }
}

pub fn (mut s McpState) evict_one_locked() {
	if s.sessions.len == 0 {
		return
	}
	mut candidate_id := ''
	mut candidate_last := i64(0)
	for id, session in s.sessions {
		last_seen := if session.last_activity_unix > 0 {
			session.last_activity_unix
		} else {
			session.started_at_unix
		}
		if candidate_id == '' || last_seen < candidate_last {
			candidate_id = id
			candidate_last = last_seen
		}
	}
	if candidate_id != '' {
		if session := s.sessions[candidate_id] {
			if mut stream := session.stream { stream.request_stop() }
		}
		s.sessions.delete(candidate_id)
		s.stat_sessions_evicted_total++
	}
}

// ── Session Management ──

pub fn (mut s McpState) ensure_session(session_id string, protocol_version string, req_id string, trace_id string, path string) Session {
	s.mu.@lock()
	defer {
		s.mu.unlock()
	}
	session := s.ensure_session_locked(session_id, protocol_version, req_id, trace_id, path)
	return session.snapshot_copy()
}

fn (mut s McpState) ensure_session_locked(session_id string, protocol_version string, req_id string, trace_id string, path string) Session {
	now := time.now().unix()
	s.prune_sessions_locked(now)
	if existing := s.sessions[session_id] {
		mut updated := existing
		if protocol_version != '' {
			updated.protocol_version = protocol_version
		}
		if req_id != '' {
			updated.request_id = req_id
		}
		if trace_id != '' {
			updated.trace_id = trace_id
		}
		if path != '' {
			updated.path = path
		}
		updated.last_activity_unix = now
		s.sessions[session_id] = updated
		return updated
	}
	max_sessions := if s.max_sessions > 0 { s.max_sessions } else { 1000 }
	for s.sessions.len >= max_sessions {
		s.evict_one_locked()
	}
	session := Session{
		id:                       session_id
		protocol_version:         protocol_version
		request_id:               req_id
		trace_id:                 trace_id
		path:                     path
		started_at_unix:          now
		last_activity_unix:       now
		client_capabilities_json: ''
		pending:                  []string{}
	}
	s.sessions[session_id] = session
	return session
}

pub fn (mut s McpState) set_client_capabilities(session_id string, raw string) bool {
	if session_id == '' || raw == '' {
		return false
	}
	s.mu.@lock()
	defer {
		s.mu.unlock()
	}
	now := time.now().unix()
	if s.stopping || s.expire_session_locked(session_id, now) { return false }
	if mut session := s.sessions[session_id] {
		session.client_capabilities_json = raw
		session.last_activity_unix = now
		s.sessions[session_id] = session
		return true
	}
	return false
}

// ── Message Queue & Flush ──

pub fn (mut s McpState) queue_message_drop_due_to_sampling(session_id string) bool {
	s.mu.@lock()
	defer {
		s.mu.unlock()
	}
	now := time.now().unix()
	if s.stopping || s.expire_session_locked(session_id, now) { return false }
	if mut session := s.sessions[session_id] {
		session.last_activity_unix = now
		if !session.client_capabilities_json.contains('"sampling"') {
			s.sessions[session_id] = session
			return true
		}
	}
	return false
}

// Caller holds mu. Queue publication shares the session owner's shutdown,
// route-identity and generation-liveness boundary, including route-less callers.
// As with dispatch admission, retired_fn must not re-enter this owner.
pub fn (s McpState) queue_admitted_locked(session Session, expected ?&SessionDispatch) bool {
	if s.stopping { return false }
	if route := session.dispatch {
		if candidate := expected {
			if candidate != route { return false }
		}
		return !route.retired_fn()
	}
	return expected == none
}

pub fn (mut s McpState) do_queue(session_id string, raw string) QueueResult {
	if session_id == '' || raw == '' {
		return QueueResult{
			queued: false
		}
	}
	s.mu.@lock()
	defer {
		s.mu.unlock()
	}
	if mut session := s.sessions[session_id] {
		if !s.queue_admitted_locked(session, none) { return QueueResult{} }
		now := time.now().unix()
		if s.expire_session_locked(session_id, now) { return QueueResult{} }
		session.last_activity_unix = now
		session.pending << raw
		max_pending := if s.max_pending_messages > 0 { s.max_pending_messages } else { 128 }
		if session.pending.len > max_pending {
			drop_count := session.pending.len - max_pending
			session.pending = session.pending[drop_count..].clone()
			s.stat_pending_dropped_total += drop_count
		}
		s.sessions[session_id] = session
		return QueueResult{
			queued: true
		}
	}
	return QueueResult{
		queued: false
	}
}

// ── Snapshot ──

pub fn (mut s McpState) snapshot(details bool, limit int, offset int, session_filter string, protocol_filter string) RuntimeSnapshot {
	view := s.snapshot_view(session_filter, protocol_filter)
	return view.page(details, limit, offset)
}

// Capture rows, prune decisions and configuration at one publication boundary.
// No session, stream, dispatch token or mutable settings array escapes the lock.
fn (mut s McpState) snapshot_view(session_filter string, protocol_filter string) RuntimeSnapshot {
	s.mu.@lock()
	defer { s.mu.unlock() }
	s.prune_sessions_locked(time.now().unix())
	mut sessions := []SessionSnapshot{}
	for _, session in s.sessions {
		if session_filter != '' && session.id != session_filter {
			continue
		}
		if protocol_filter != '' && session.protocol_version != protocol_filter {
			continue
		}
		sessions << SessionSnapshot{
			id:                       session.id
			protocol_version:         session.protocol_version
			request_id:               session.request_id
			trace_id:                 session.trace_id
			path:                     session.path
			started_at_unix:          session.started_at_unix
			last_activity_unix:       session.last_activity_unix
			pending_count:            session.pending.len
			connected:                session.stream != none
			client_capabilities_json: session.client_capabilities_json
		}
	}
	return RuntimeSnapshot{
		active_sessions:            sessions.len
		session_id:                 session_filter
		protocol_version:           protocol_filter
		max_sessions:               if s.max_sessions > 0 { s.max_sessions } else { 1000 }
		max_pending_messages:       if s.max_pending_messages > 0 {
			s.max_pending_messages
		} else {
			128
		}
		session_ttl_seconds:        if s.session_ttl_seconds > 0 {
			s.session_ttl_seconds
		} else {
			900
		}
		allowed_origins:            s.allowed_origins.clone()
		sampling_capability_policy: McpState.normalize_sampling_capability_policy(s.sampling_capability_policy)
		sessions:                   sessions
	}
}

// Formatting owns only detached rows/settings. It never reads the live owner or
// holds its mutex while sorting and paginating a potentially large session list.
fn (view RuntimeSnapshot) page(details bool, limit int, offset int) RuntimeSnapshot {
	clean_limit := if limit > 0 { limit } else { 0 }
	clean_offset := if offset > 0 { offset } else { 0 }
	if !details {
		return RuntimeSnapshot{
			...view
			details:           false
			limit:             clean_limit
			offset:            clean_offset
			returned_sessions: 0
			sessions:          []SessionSnapshot{}
		}
	}
	mut sessions := view.sessions.clone()
	sessions.sort(a.started_at_unix < b.started_at_unix)
	start := if clean_offset < sessions.len { clean_offset } else { sessions.len }
	remaining := sessions.len - start
	count := if clean_limit < remaining { clean_limit } else { remaining }
	return RuntimeSnapshot{
		...view
		details:           true
		limit:             clean_limit
		offset:            clean_offset
		returned_sessions: count
		sessions:          sessions[start..start + count].clone()
	}
}

// ── Query ──

pub fn (mut s McpState) origin_allowed(headers map[string]string) bool {
	s.mu.@lock()
	defer { s.mu.unlock() }
	if s.allowed_origins.len == 0 {
		return true
	}
	origin := (headers['origin'] or { '' }).trim_space()
	if origin == '' {
		return false
	}
	for allowed in s.allowed_origins {
		if origin == allowed {
			return true
		}
	}
	return false
}

pub fn (mut s McpState) delete_session(session_id string) bool {
	if session_id == '' { return false }
	s.mu.@lock()
	defer { s.mu.unlock() }
	if session := s.sessions[session_id] {
		if mut stream := session.stream { stream.request_stop() }
		s.sessions.delete(session_id)
		return true
	}
	return false
}

pub fn (mut s McpState) client_capabilities_for_request(session_id string, raw string) string {
	body_caps := Session.extract_client_capabilities_json(raw)
	if body_caps != '' {
		return body_caps
	}
	s.mu.@lock()
	defer { s.mu.unlock() }
	if session_id != '' {
		if session := s.sessions[session_id] {
			return session.client_capabilities_json
		}
	}
	return ''
}
