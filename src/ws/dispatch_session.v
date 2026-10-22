module ws

import encoding.base64
import log
import net
import upstream.transport
import net.websocket

// ── Dispatch Session Lifecycle ──

pub fn handle_dispatch_session(rt RuntimeContext, mut client_conn net.TcpConn, key string, method string, path string, query map[string]string, headers map[string]string, remote_addr string, req_id string, trace_id string, start_ms i64, open_commands []transport.WorkerWebSocketFrame) {
	mut ws_server, captured := managed_server()
	mut lifecycle := &DispatchConnState{}
	mut state := &DispatchBridgeState{
		lifecycle:     lifecycle
		rt:            rt
		open_commands: open_commands.clone()
		conn_id:       req_id
		method:        method
		path:          path
		query:         query.clone()
		headers:       headers.clone()
		remote_addr:   remote_addr
		request_id:    req_id
		trace_id:      trace_id
		start_ms:      start_ms
	}
	ws_server.on_message_ref(dispatch_session_message_cb, state)
	ws_server.on_close_ref(dispatch_session_close_cb, state)
	ws_server.on_attached_ref(dispatch_session_attached_cb, state)
	defer {
		dispatch_session_finalize(state)
	}
	managed_handshake(mut ws_server, mut client_conn, key, captured) or { return }
}

fn dispatch_session_attached_cb(mut sc websocket.ServerClient, ref voidptr) ! {
	if ref == unsafe { nil } {
		return
	}
	unsafe {
		mut state := &DispatchBridgeState(ref)
		state.rt.register_conn(state.conn_id, '', state.method, state.request_id, state.trace_id,
			state.path, state.query, state.headers, state.remote_addr, sc.client, state.lifecycle)
		dispatch_session_process_open(state)
		dispatch_session_activate(state)
	}
}

pub fn dispatch_session_begin_local_close(mut state DispatchBridgeState) {
	_ = state.lifecycle.begin_worker_close()
	state.rt.mark_closing(state.conn_id, state.lifecycle)
}

fn dispatch_session_close_current(state &DispatchBridgeState, code int, reason string) {
	if isnil(state) {
		return
	}
	unsafe {
		mut current := state
		dispatch_session_begin_local_close(mut current)
		current.rt.close_owned_target(current.conn_id, current.lifecycle, code, reason)
	}
}

fn dispatch_session_followup_close(state &DispatchBridgeState, failures []transport.WorkerWebSocketDispatchCommandFailure) ?transport.WorkerWebSocketFrame {
	if isnil(state) {
		return none
	}
	unsafe {
		current := state
		return current.rt.followup_failure(current.conn_id, current.method, current.path,
			current.query, current.headers, current.remote_addr, current.request_id,
			current.trace_id, failures)
	}
}

fn dispatch_session_activate(state &DispatchBridgeState) {
	if isnil(state) {
		return
	}
	unsafe {
		current := state
		if !current.lifecycle.mark_open() {
			return
		}
		current.rt.flush_pending(current.conn_id)
	}
}

fn dispatch_session_process_open(state &DispatchBridgeState) {
	if isnil(state) {
		return
	}
	unsafe {
		current := state
		result := current.rt.command_result(current.open_commands)
		if result.has_close {
			close_frame := result.close_frame
			code := if close_frame.code > 0 { close_frame.code } else { 1000 }
			dispatch_session_close_current(current, code, close_frame.reason)
			return
		}
		if result.failures.len > 0 {
			if close_frame := dispatch_session_followup_close(current, result.failures) {
				code := if close_frame.code > 0 { close_frame.code } else { 1000 }
				dispatch_session_close_current(current, code, close_frame.reason)
			}
		}
	}
}

pub fn dispatch_session_finalize(state &DispatchBridgeState) {
	dispatch_session_finalize_with_details(state, 1001, 'session_terminated')
}

fn dispatch_session_finalize_with_details(state &DispatchBridgeState, reported_code int, reported_reason string) {
	if isnil(state) { return }
	mut current := unsafe { state }
	current.finalize_mu.@lock()
	defer { current.finalize_mu.unlock() }
	code, reason := current.lifecycle.close_details(reported_code, reported_reason)
	should_process, worker_initiated := current.lifecycle.begin_peer_close()
	current.rt.mark_closing(current.conn_id, current.lifecycle)
	if should_process && current.rt.can_cleanup_fn(current.conn_id, current.lifecycle) {
		presence := current.rt.presence(current.conn_id)
		if resp := current.rt.dispatch_event(current.rt.build_frame('close', current.method, current.path,
			current.query, current.headers, current.remote_addr, current.request_id, current.trace_id, '', '',
			code, reason, current.rt.rooms(current.conn_id), current.rt.metadata(current.conn_id), presence)) {
			if !worker_initiated && resp.event != 'error' {
				current.rt.command_result(resp.commands)
			}
		}
	}
	current.lifecycle.mark_closing()
	if current.lifecycle.begin_cleanup() {
		current.rt.cleanup_conn(current.conn_id, current.lifecycle)
	}
}

fn dispatch_session_message_cb(mut ws_client websocket.Client, msg &websocket.Message, ref voidptr) ! {
	mut state := unsafe { &DispatchBridgeState(ref) }
	if !state.lifecycle.can_process_messages() {
		log.debug('[vhttpd] websocket dispatch message ignored conn_id=${state.conn_id} request_id=${state.request_id} reason=closed')
		return
	}
	opcode, payload, supported := dispatch_payload_from_message(msg)
	if !supported {
		dispatch_session_begin_local_close(mut state)
		ws_client.close(1003, 'Only text and binary frames are supported')!
		return
	}
	presence := state.rt.presence(state.conn_id)
	resp := state.rt.dispatch_event(state.rt.build_frame('message', state.method, state.path,
		state.query, state.headers, state.remote_addr, state.request_id, state.trace_id, opcode,
		payload, 0, '', state.rt.rooms(state.conn_id), state.rt.metadata(state.conn_id), presence))!
	if resp.event == 'error' {
		dispatch_session_begin_local_close(mut state)
		ws_client.close(1011, 'worker error')!
		return
	}
	log.debug('[vhttpd] websocket message commands begin conn_id=${state.conn_id} request_id=${state.request_id} commands=${resp.commands.len}')
	result := state.rt.command_result(resp.commands)
	log.debug('[vhttpd] websocket message commands done conn_id=${state.conn_id} request_id=${state.request_id} has_close=${result.has_close} failures=${result.failures.len}')
	if result.has_close {
		close_frame := result.close_frame
		code := if close_frame.code > 0 { close_frame.code } else { 1000 }
		dispatch_session_begin_local_close(mut state)
		ws_client.close(code, close_frame.reason)!
		return
	}
	if result.failures.len > 0 {
		if close_frame := state.rt.followup_failure(state.conn_id, state.method, state.path,
			state.query, state.headers, state.remote_addr, state.request_id, state.trace_id,
			result.failures)
		{
			code := if close_frame.code > 0 { close_frame.code } else { 1000 }
			dispatch_session_begin_local_close(mut state)
			ws_client.close(code, close_frame.reason)!
			return
		}
	}
}

pub fn dispatch_payload_from_message(msg &websocket.Message) (string, string, bool) {
	return match msg.opcode {
		.text_frame {
			'text', msg.payload.bytestr(), true
		}
		.binary_frame {
			'binary', base64.encode(msg.payload), true
		}
		else {
			'', '', false
		}
	}
}

fn dispatch_session_close_cb(mut ws_client websocket.Client, reported_code int, reported_reason string, ref voidptr) ! {
	state := unsafe { &DispatchBridgeState(ref) }
	dispatch_session_finalize_with_details(state, reported_code, reported_reason)
}

pub fn run_dispatch_session(mut run IngressRun, rt RuntimeContext, mut client_conn net.TcpConn, key string, method string, path string, query map[string]string, headers map[string]string, remote_addr string, req_id string, trace_id string, start_ms i64, open_commands []transport.WorkerWebSocketFrame) {
	defer { run.finish() }
	if run.stopped() {
		client_conn.close() or {}
		dispatch_session_finalize(&DispatchBridgeState{
			lifecycle:   &DispatchConnState{}
			rt:          rt
			conn_id:     req_id
			request_id:  req_id
			trace_id:    trace_id
			method:      method
			path:        path
			query:       query.clone()
			headers:     headers.clone()
			remote_addr: remote_addr
		})
		return
	}
	handle_dispatch_session(rt.with_ingress(&run), mut client_conn, key, method, path, query, headers, remote_addr, req_id, trace_id, start_ms, open_commands)
}
