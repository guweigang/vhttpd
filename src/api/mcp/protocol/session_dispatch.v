module protocol

import upstream.transport
import time

// The route is also an identity token: deletion drops the last session reference.
@[heap]
pub struct SessionDispatch {
pub:
	provider string
	// Must only read generation liveness; never re-enter the session owner.
	retired_fn fn () bool @[required]
	call_fn    fn (transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse @[required]
}

pub struct SessionDispatchLookup {
pub:
	route ?&SessionDispatch
}

// Resolve existing ownership before constructing a route from the current engine.
// None means a new request or an existing session without an explicit route.
pub fn (mut s McpState) lookup_dispatch(id string) !SessionDispatchLookup {
	s.mu.@lock()
	defer { s.mu.unlock() }
	return s.lookup_dispatch_locked(id)!
}

fn (mut s McpState) lookup_dispatch_locked(id string) !SessionDispatchLookup {
	if s.stopping { return error('mcp_stopping') }
	s.prune_sessions_locked(time.now().unix())
	if id == '' { return SessionDispatchLookup{} }
	session := s.sessions[id] or { return error('mcp_session_unavailable') }
	if route := session.dispatch {
		if route.retired_fn() { return error('mcp_session_unavailable') }
		return SessionDispatchLookup{ route: route }
	}
	return SessionDispatchLookup{}
}

pub fn (mut s McpState) session_dispatch(id string, candidate &SessionDispatch) !&SessionDispatch {
	s.mu.@lock()
	defer { s.mu.unlock() }
	lookup := s.lookup_dispatch_locked(id)!
	if retained := lookup.route { return retained }
	if candidate.retired_fn() { return error('mcp_session_unavailable') }
	if id == '' { return candidate }
	mut session := s.sessions[id] or { return error('mcp_session_unavailable') }
	session.dispatch = candidate
	s.sessions[id] = session
	return candidate
}

// An in-flight response may update only its own still-registered session.
pub fn (mut s McpState) complete_dispatch_session(id string, version string, req string, trace string, path string, route &SessionDispatch, existing bool) !Session {
	s.mu.@lock()
	defer { s.mu.unlock() }
	if s.stopping { return error('mcp_stopping') }
	if route.retired_fn() { return error('mcp_session_unavailable') }
	s.prune_sessions_locked(time.now().unix())
	if current := s.sessions[id] {
		bound := current.dispatch or { return error('mcp_session_conflict') }
		if voidptr(bound) != voidptr(route) { return error('mcp_session_conflict') }
	} else if existing {
		return error('mcp_session_unavailable')
	}
	mut session := s.ensure_session_locked(id, version, req, trace, path)
	session.dispatch = route
	s.sessions[id] = session
	return session.snapshot_copy()
}

pub fn (mut s McpState) set_dispatch_capabilities(id string, route &SessionDispatch, raw string) bool {
	s.mu.@lock()
	defer { s.mu.unlock() }
	mut session := s.sessions[id] or { return false }
	bound := session.dispatch or { return false }
	if voidptr(bound) != voidptr(route) { return false }
	session.client_capabilities_json = raw
	s.sessions[id] = session
	return true
}

pub fn (mut s McpState) dispatch_current(id string, route &SessionDispatch) bool {
	s.mu.@lock()
	defer { s.mu.unlock() }
	if s.stopping || route.retired_fn() { return false }
	if id == '' { return true }
	session := s.sessions[id] or { return false }
	actual := session.dispatch or { return false }
	return voidptr(actual) == voidptr(route)
}

// Query generation liveness outside the session mutex; detach by route identity.
// The stream owner remains responsible for native close and registry removal.
pub fn (mut s McpState) retire_dispatches() []&SessionStream {
	s.mu.@lock()
	mut candidates := map[string]&SessionDispatch{}
	for id, session in s.sessions {
		if route := session.dispatch { candidates[id] = route }
	}
	s.mu.unlock()
	mut streams := []&SessionStream{}
	for id, route in candidates {
		if !route.retired_fn() { continue }
		s.mu.@lock()
		if session := s.sessions[id] {
			if current := session.dispatch {
				if voidptr(current) == voidptr(route) {
					if mut stream := session.stream {
						stream.request_stop()
						streams << stream
					}
					s.sessions.delete(id)
				}
			}
		}
		s.mu.unlock()
	}
	return streams
}

// Registry removal follows native close. Wait for these streams only, so new
// generation streams cannot keep a displaced generation's retirement blocked.
pub fn (mut s McpState) wait_dispatch_streams(streams []&SessionStream) {
	for {
		s.mu.@lock()
		mut pending := false
		for stream in streams {
			if stream.token in s.streams {
				pending = true
				break
			}
		}
		s.mu.unlock()
		if !pending { return }
		time.sleep(time.millisecond)
	}
}
