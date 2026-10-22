module main

import api.mcp.protocol as mcp_protocol
import net
import time

fn mcp_ttl_age(mut state mcp_protocol.McpState) {
	state.mu.@lock()
	defer { state.mu.unlock() }
	mut session := state.sessions['ttl']
	session.last_activity_unix = time.now().unix() - 10
	state.sessions['ttl'] = session
}

fn mcp_ttl_pair() (&net.TcpConn, &net.TcpConn) {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	address := listener.addr() or { panic(err) }
	peer := net.dial_tcp(address.str()) or { panic(err) }
	server := listener.accept() or { panic(err) }
	return server, peer
}

fn test_mcp_direct_queue_cannot_revive_expired_session() {
	mut state := mcp_protocol.McpState{ session_ttl_seconds: 1 }
	state.ensure_session('ttl', '', '', '', '')
	mcp_ttl_age(mut state)
	assert !state.do_queue('ttl', 'late').queued
	assert 'ttl' !in state.sessions
	assert state.stat_sessions_expired_total == 1
	assert !state.do_queue('ttl', 'again').queued
	assert state.stat_sessions_expired_total == 1
}

fn test_mcp_app_queue_expires_before_sampling_and_capacity_accounting() {
	for policy in ['warn', 'drop', 'error'] {
		mut app := &App{}
		app.protocols.mcp.session_ttl_seconds = 1
		app.protocols.mcp.sampling_capability_policy = policy
		app.protocols.mcp.max_pending_messages = 1
		app.protocols.mcp.ensure_session('ttl', '', '', '', '')
		assert app.protocols.mcp.do_queue('ttl', 'retained').queued
		mcp_ttl_age(mut app.protocols.mcp)
		result := McpRuntime.queue_message(mut app, 'ttl', '{"method":"sampling/createMessage"}')
		assert !result.queued && !result.error
		assert 'ttl' !in app.protocols.mcp.sessions
		assert app.protocols.mcp.stat_sessions_expired_total == 1
		assert app.protocols.mcp.stat_pending_dropped_total == 0
		assert app.protocols.mcp.stat_sampling_capability_warnings_total == 0
		assert app.protocols.mcp.stat_sampling_capability_dropped_total == 0
		assert app.protocols.mcp.stat_sampling_capability_errors_total == 0
	}
}

fn test_mcp_expired_sse_attach_keeps_native_socket_with_caller() {
	mut state := mcp_protocol.McpState{ session_ttl_seconds: 1 }
	state.ensure_session('ttl', '', '', '', '')
	mcp_ttl_age(mut state)
	mut server, mut peer := mcp_ttl_pair()
	defer {
		server.close() or {}
		peer.close() or {}
	}
	mut rejected := false
	if mut stream := state.attach_stream('ttl', server) {
		state.finish_stream('ttl', mut stream)
	} else {
		rejected = true
	}
	assert rejected
	assert state.active_streams() == 0
	assert state.stat_sessions_expired_total == 1
	server.write_string('caller-owned') or { panic(err) }
	peer.set_read_timeout(time.second)
	mut bytes := []u8{len: 32}
	n := peer.read(mut bytes) or { panic(err) }
	assert bytes[..n].bytestr() == 'caller-owned'
}

fn test_mcp_expired_stream_flush_cancels_but_retains_physical_close_owner() {
	mut state := mcp_protocol.McpState{ session_ttl_seconds: 1 }
	state.ensure_session('ttl', '', '', '', '')
	mut server, mut peer := mcp_ttl_pair()
	defer { peer.close() or {} }
	mut stream := state.attach_stream('ttl', server) or { panic(err) }
	defer { state.finish_stream('ttl', mut stream) }
	stream.start(fn (mut _ net.TcpConn) ! {}) or { panic(err) }
	assert state.do_queue('ttl', '{"late":true}').queued
	mcp_ttl_age(mut state)
	assert !state.flush_stream('ttl', mut stream)
	assert stream.stopped()
	assert !stream.finished()
	assert 'ttl' !in state.sessions
	assert state.stat_sessions_expired_total == 1
	assert state.active_streams() == 1
	state.finish_stream('ttl', mut stream)
	assert stream.finished()
	assert state.active_streams() == 0
	peer.set_read_timeout(time.second)
	mut output := ''
	mut bytes := []u8{len: 1024}
	for {
		n := peer.read(mut bytes) or { break }
		if n == 0 { break }
		output += bytes[..n].bytestr()
	}
	assert output == ': connected\n\n', output
}

fn test_mcp_get_expired_session_returns_404_before_connection_takeover() {
	mut app := &App{}
	app.protocols.mcp.session_ttl_seconds = 1
	app.protocols.mcp.ensure_session('ttl', '', '', '', '')
	mcp_ttl_age(mut app.protocols.mcp)
	mut server, mut peer := mcp_ttl_pair()
	mut transferred := false
	defer {
		if !transferred { server.close() or {} }
		peer.close() or {}
	}
	mut ctx := Context{}
	ctx.conn = server
	ctx.req.header.add_custom('mcp-session-id', 'ttl') or { panic(err) }
	_ := mcp_handle_get_http(mut app, mut ctx)
	transferred = app.protocols.mcp.active_streams() > 0
	if transferred {
		app.protocols.mcp.request_stop()
		app.protocols.mcp.wait_stopped()
	}
	assert ctx.res.status_code == 404
	assert app.protocols.mcp.active_streams() == 0
	assert 'ttl' !in app.protocols.mcp.sessions
}

fn test_mcp_active_queue_refreshes_sliding_ttl_without_expiration() {
	mut state := mcp_protocol.McpState{ session_ttl_seconds: 10 }
	state.ensure_session('ttl', '', '', '', '')
	mut session := state.sessions['ttl']
	session.last_activity_unix = time.now().unix() - 2
	state.sessions['ttl'] = session
	assert state.do_queue('ttl', 'live').queued
	assert state.sessions['ttl'].pending == ['live']
	assert state.sessions['ttl'].last_activity_unix > session.last_activity_unix
	assert state.stat_sessions_expired_total == 0
}

fn test_mcp_capability_update_cannot_revive_expired_session() {
	mut state := mcp_protocol.McpState{ session_ttl_seconds: 1 }
	state.ensure_session('ttl', '', '', '', '')
	mcp_ttl_age(mut state)
	assert !state.set_client_capabilities('ttl', '{"sampling":{}}')
	assert 'ttl' !in state.sessions
	assert state.stat_sessions_expired_total == 1
}

fn test_mcp_sampling_query_cannot_revive_expired_session() {
	mut state := mcp_protocol.McpState{ session_ttl_seconds: 1 }
	state.ensure_session('ttl', '', '', '', '')
	mcp_ttl_age(mut state)
	assert !state.queue_message_drop_due_to_sampling('ttl')
	assert 'ttl' !in state.sessions
	assert state.stat_sessions_expired_total == 1
}

fn test_mcp_delayed_stream_finish_cannot_revive_expired_session() {
	mut state := mcp_protocol.McpState{ session_ttl_seconds: 1 }
	state.ensure_session('ttl', '', '', '', '')
	mut server, mut peer := mcp_ttl_pair()
	defer { peer.close() or {} }
	mut stream := state.attach_stream('ttl', server) or { panic(err) }
	defer { state.finish_stream('ttl', mut stream) }
	mcp_ttl_age(mut state)
	state.finish_stream('ttl', mut stream)
	assert stream.finished()
	assert state.active_streams() == 0
	assert 'ttl' !in state.sessions
	assert state.stat_sessions_expired_total == 1
}
