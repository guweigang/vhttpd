module mcp_protocol

import net
import time

// ── Session Lifecycle (must be called while s.mu is held) ──

pub fn (mut s McpState) prune_sessions_locked(now i64) {
	if s.sessions.len == 0 {
		return
	}
	ttl := if s.session_ttl_seconds > 0 { i64(s.session_ttl_seconds) } else { i64(900) }
	mut expired := []string{}
	for id, session in s.sessions {
		last_seen := if session.last_activity_unix > 0 {
			session.last_activity_unix
		} else {
			session.started_at_unix
		}
		if now - last_seen > ttl {
			expired << id
		}
	}
	for id in expired {
		s.sessions.delete(id)
	}
	if expired.len > 0 {
		s.stat_sessions_expired_total += expired.len
	}
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
		conn:                     unsafe { nil }
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
	if mut session := s.sessions[session_id] {
		session.client_capabilities_json = raw
		session.last_activity_unix = time.now().unix()
		s.sessions[session_id] = session
		return true
	}
	return false
}

pub fn (mut s McpState) bind_conn(session_id string, conn &net.TcpConn) bool {
	if session_id == '' || isnil(conn) {
		return false
	}
	s.mu.@lock()
	defer {
		s.mu.unlock()
	}
	if mut session := s.sessions[session_id] {
		session.conn = unsafe { conn }
		session.last_activity_unix = time.now().unix()
		s.sessions[session_id] = session
		return true
	}
	return false
}

pub fn (mut s McpState) unbind_conn(session_id string, conn &net.TcpConn) {
	if session_id == '' {
		return
	}
	s.mu.@lock()
	defer {
		s.mu.unlock()
	}
	if mut session := s.sessions[session_id] {
		if isnil(conn) || session.conn == unsafe { conn } {
			session.conn = unsafe { nil }
			session.last_activity_unix = time.now().unix()
			s.sessions[session_id] = session
		}
	}
}

// ── Message Queue & Flush ──

pub fn (mut s McpState) queue_message_drop_due_to_sampling(session_id string) bool {
	s.mu.@lock()
	defer {
		s.mu.unlock()
	}
	if mut session := s.sessions[session_id] {
		session.last_activity_unix = time.now().unix()
		if !session.client_capabilities_json.contains('"sampling"') {
			s.sessions[session_id] = session
			return true
		}
	}
	return false
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
		session.last_activity_unix = time.now().unix()
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

pub fn (mut s McpState) flush_session(session_id string) bool {
	if session_id == '' {
		return false
	}
	mut client := &net.TcpConn(unsafe { nil })
	mut pending := []string{}
	s.mu.@lock()
	if session := s.sessions[session_id] {
		client = session.conn
		pending = session.pending.clone()
		if mut writable := s.sessions[session_id] {
			writable.pending = []string{}
			writable.last_activity_unix = time.now().unix()
			s.sessions[session_id] = writable
		}
	}
	s.mu.unlock()
	if isnil(client) {
		return false
	}
	for raw in pending {
		if !Session.write_sse_json(mut client, raw) {
			return false
		}
	}
	return true
}

// ── Snapshot ──

pub fn (mut s McpState) snapshot(details bool, limit int, offset int, session_filter string, protocol_filter string) RuntimeSnapshot {
	s.mu.@lock()
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
			connected:                !isnil(session.conn)
			client_capabilities_json: session.client_capabilities_json
		}
	}
	s.mu.unlock()
	sessions.sort(a.started_at_unix < b.started_at_unix)
	total := sessions.len
	if !details {
		return RuntimeSnapshot{
			active_sessions:            total
			returned_sessions:          0
			details:                    false
			limit:                      limit
			offset:                     offset
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
			sessions:                   []SessionSnapshot{}
		}
	}
	start := if offset < total { offset } else { total }
	end := if start + limit < total { start + limit } else { total }
	return RuntimeSnapshot{
		active_sessions:            total
		returned_sessions:          end - start
		details:                    true
		limit:                      limit
		offset:                     offset
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
		sessions:                   sessions[start..end].clone()
	}
}

// ── Query ──

pub fn (s &McpState) origin_allowed(headers map[string]string) bool {
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
	if session_id == '' {
		return false
	}
	mut client := &net.TcpConn(unsafe { nil })
	s.mu.@lock()
	if session := s.sessions[session_id] {
		client = session.conn
		s.sessions.delete(session_id)
	}
	s.mu.unlock()
	if !isnil(client) {
		client.close() or {}
	}
	return true
}

pub fn (s &McpState) client_capabilities_for_request(session_id string, raw string) string {
	body_caps := Session.extract_client_capabilities_json(raw)
	if body_caps != '' {
		return body_caps
	}
	if session_id != '' {
		if session := s.sessions[session_id] {
			return session.client_capabilities_json
		}
	}
	return ''
}
