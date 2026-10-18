module protocol

import time
import net
import upstream.transport

fn route_candidate(label string) &SessionDispatch {
	return &SessionDispatch{
		provider:   label
		retired_fn: fn () bool { return false }
		call_fn:    fn [label] (req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
			return transport.WorkerMcpDispatchResponse{ handled: true, body: label }
		}
	}
}

fn test_session_route_is_stable_until_delete_and_does_not_resurrect() {
	mut state := McpState{}
	first := route_candidate('old')
	state.complete_dispatch_session('s', '', '', '', '', first, false) or { panic(err) }
	chosen := state.session_dispatch('s', route_candidate('new')) or { panic(err) }
	assert voidptr(chosen) == voidptr(first)
	assert state.delete_session('s')
	assert !state.delete_session('s')
	if _ := state.complete_dispatch_session('s', '', '', '', '', first, true) {
		assert false
	}
	assert 's' !in state.sessions
	if _ := state.session_dispatch('s', route_candidate('new')) {
		assert false
	}
}

fn test_late_response_cannot_modify_reused_session_identity() {
	mut state := McpState{}
	first := route_candidate('old')
	next := route_candidate('new')
	state.complete_dispatch_session('s', 'old-version', '', '', '', first, false) or { panic(err) }
	state.delete_session('s')
	state.complete_dispatch_session('s', 'new-version', '', '', '', next, false) or { panic(err) }
	if _ := state.complete_dispatch_session('s', 'wrong', '', '', '', first, true) {
		assert false
	}
	if _ := state.complete_dispatch_session('s', 'wrong', '', '', '', first, false) {
		assert false
	}
	assert !state.set_dispatch_capabilities('s', first, 'wrong')
	assert state.sessions['s'].protocol_version == 'new-version'
	assert state.set_dispatch_capabilities('s', next, 'new-caps')
	assert state.sessions['s'].client_capabilities_json == 'new-caps'
}

fn test_session_expiry_eviction_and_shutdown_drop_dispatch_admission() {
	for mode in ['expiry', 'eviction', 'stop'] {
		mut state := McpState{ max_sessions: 1, session_ttl_seconds: 1 }
		route := route_candidate('old')
		state.complete_dispatch_session('s', '', '', '', '', route, false) or { panic(err) }
		if mode == 'expiry' {
			mut session := state.sessions['s']
			session.last_activity_unix = time.now().unix() - 5
			state.sessions['s'] = session
		} else if mode == 'eviction' {
			state.ensure_session('new', '', '', '', '')
		} else {
			state.request_stop()
		}
		if _ := state.session_dispatch('s', route_candidate('new')) {
			assert false
		}
		if _ := state.complete_dispatch_session('s', '', '', '', '', route, true) {
			assert false
		}
	}
}

fn test_existing_unbound_session_keeps_first_explicit_route() {
	mut state := McpState{}
	state.ensure_session('legacy', '', '', '', '')
	first := route_candidate('first')
	assert voidptr(state.session_dispatch('legacy', first) or { panic(err) }) == voidptr(first)
	assert voidptr(state.session_dispatch('legacy', route_candidate('other')) or { panic(err) }) == voidptr(first)
	assert state.sessions.len == 1
}

@[heap]
struct RouteRetirementProbe {
mut:
	retired bool
}

fn route_tcp_pair() (&net.TcpConn, &net.TcpConn) {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	addr := listener.addr() or { panic(err) }
	peer := net.dial_tcp(addr.str()) or { panic(err) }
	return listener.accept() or { panic(err) }, peer
}

fn test_retirement_waits_for_registry_removal_and_ignores_new_generation_streams() {
	mut state := &McpState{}
	mut probe := &RouteRetirementProbe{}
	old := &SessionDispatch{
		provider:   'old'
		retired_fn: fn [mut probe] () bool {
			return probe.retired
		}
		call_fn:    fn (req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
			return transport.WorkerMcpDispatchResponse{}
		}
	}
	state.complete_dispatch_session('old', '', '', '', '', old, false) or { panic(err) }
	state.complete_dispatch_session('new', '', '', '', '', route_candidate('new'), false) or { panic(err) }
	old_conn, mut old_peer := route_tcp_pair()
	next_conn, mut next_peer := route_tcp_pair()
	defer {
		old_peer.close() or {}
		next_peer.close() or {}
	}
	mut old_stream := state.attach_stream('old', old_conn) or { panic(err) }
	mut next_stream := state.attach_stream('new', next_conn) or { panic(err) }
	probe.retired = true
	streams := state.retire_dispatches()
	assert streams.len == 1
	assert old_stream.stopped()
	assert !next_stream.stopped()
	done := chan bool{cap: 1}
	spawn fn [mut state, streams, done] () {
		state.wait_dispatch_streams(streams)
		done <- true
	}()
	select {
		_ := <-done {
			panic('retirement skipped registered stream')
		}
		20 * time.millisecond {
		}
	}
	state.finish_stream('old', mut old_stream)
	select {
		_ := <-done {
		}
		time.second {
			panic('new generation held old retirement open')
		}
	}
	assert state.active_streams() == 1
	assert 'new' in state.sessions
	state.finish_stream('new', mut next_stream)
	assert state.active_streams() == 0
}

fn test_lookup_dispatch_distinguishes_unbound_missing_and_retained_routes() {
	mut state := McpState{}
	assert (state.lookup_dispatch('') or { panic(err) }).route == none
	state.ensure_session('legacy', '', '', '', '')
	assert (state.lookup_dispatch('legacy') or { panic(err) }).route == none
	first := route_candidate('first')
	state.session_dispatch('legacy', first) or { panic(err) }
	retained := (state.lookup_dispatch('legacy') or { panic(err) }).route or { panic('missing retained route') }
	assert voidptr(retained) == voidptr(first)
	if _ := state.lookup_dispatch('missing') {
		assert false
	} else {
		assert err.msg() == 'mcp_session_unavailable'
	}
	state.request_stop()
	if _ := state.lookup_dispatch('') {
		assert false
	} else {
		assert err.msg() == 'mcp_stopping'
	}
}

fn test_retired_candidate_cannot_enter_new_or_unbound_mcp_session() {
	for id in ['', 'legacy'] {
		mut state := McpState{}
		if id != '' { state.ensure_session(id, '', '', '', '') }
		route := &SessionDispatch{
			provider:   'retired'
			retired_fn: fn () bool { return true }
			call_fn:    fn (_ transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
				return transport.WorkerMcpDispatchResponse{}
			}
		}
		if _ := state.session_dispatch(id, route) {
			assert false
		} else {
			assert err.msg() == 'mcp_session_unavailable'
		}
		if id != '' {
			assert state.sessions[id].dispatch == none
		}
	}
}

fn test_lookup_dispatch_rejects_retired_route_and_prunes_expired_session() {
	mut probe := &RouteRetirementProbe{}
	mut state := McpState{ session_ttl_seconds: 1 }
	route := &SessionDispatch{
		provider:   'old'
		retired_fn: fn [mut probe] () bool {
			return probe.retired
		}
		call_fn:    fn (_ transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
			return transport.WorkerMcpDispatchResponse{}
		}
	}
	state.complete_dispatch_session('s', '', '', '', '', route, false) or { panic(err) }
	probe.retired = true
	if _ := state.lookup_dispatch('s') {
		assert false
	} else {
		assert err.msg() == 'mcp_session_unavailable'
	}
	mut session := state.sessions['s']
	session.last_activity_unix = time.now().unix() - 5
	state.sessions['s'] = session
	if _ := state.lookup_dispatch('s') {
		assert false
	}
	assert 's' !in state.sessions
}
