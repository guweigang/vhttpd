module main

import dispatch
import executor
import log
import net
import net.http
import net.unix
import net.websocket
import time
import upstream.transport
import veb
import worker
import ws

fn websocket_upgrade_key(req http.Request) string {
	return req.header.get(.sec_websocket_key) or { '' }
}

fn is_websocket_upgrade(req http.Request) bool {
	if req.method != .get {
		return false
	}
	headers := transport.header_map_from_request(req)
	upgrade := headers['upgrade']
	connection := headers['connection']
	key := headers['sec-websocket-key']
	return upgrade.to_lower() == 'websocket' && connection.to_lower().contains('upgrade')
		&& key != ''
}

fn websocket_http_response(mut app App, mut ctx Context, method string, path string, remote_addr string, req_id string, trace_id string, start_ms i64, status int, headers map[string]string, body string, error_class string) veb.Result {
	mut event_metadata := {
		'response_mode': 'websocket'
	}
	mut outcome_headers := headers.clone()
	if error_class != '' {
		event_metadata['error_class'] = error_class
		outcome_headers['x-vhttpd-error-class'] = error_class
	}
	return HttpResponseRuntime.delivery_outcome(mut app, mut ctx, http_ingress_request(method,
		path, path, '', remote_addr, req_id, trace_id, start_ms), dispatch.outcome_with_metadata(dispatch.response_outcome(status,
		outcome_headers, body), event_metadata), none)
}

pub fn (mut app App) worker_websocket_open(mut conn unix.StreamConn, req http.Request, remote_addr string, path string, req_id string, trace_id string) !(bool, int, string) {
	normalized_path, query_string := transport.normalize_request_target(path)
	query := transport.parse_query_map(query_string)
	rt := app.build_websocket_runtime_context()
	presence := rt.presence(req_id)
	frame := transport.WorkerWebSocketFrame{
		mode:            'websocket'
		event:           'open'
		id:              req_id
		path:            normalized_path
		query:           query
		headers:         transport.header_map_from_request(req)
		remote_addr:     remote_addr
		request_id:      req_id
		trace_id:        trace_id
		rooms:           rt.rooms(req_id)
		metadata:        rt.metadata(req_id)
		room_members:    presence.room_members
		member_metadata: presence.member_metadata
		room_counts:     presence.room_counts
		presence_users:  presence.presence_users
	}
	worker.WorkerBackendFrameCodec.write_websocket_frame(mut conn, frame)!
	mut accepted := false
	for {
		reply := worker.WorkerBackendFrameCodec.read_websocket_frame(mut conn)!
		if reply.mode != 'websocket' {
			continue
		}
		if _ := rt.process_worker_frame(reply) {
			continue
		}
		match reply.event {
			'accept' {
				accepted = true
			}
			'close' {
				status := if reply.status > 0 { reply.status } else { 403 }
				body := if reply.reason != '' { reply.reason } else { 'Forbidden' }
				return false, status, body
			}
			'error' {
				body := if reply.error != '' { reply.error } else { 'WebSocket open failed' }
				return false, 500, body
			}
			'done' {
				break
			}
			else {}
		}
	}
	if !accepted {
		return false, 502, 'WebSocket handler did not accept connection'
	}
	return true, 101, ''
}

fn worker_websocket_message_cb(mut ws_client websocket.Client, msg &websocket.Message, ref voidptr) ! {
	mut state := unsafe { &ws.BridgeState(ref) }
	runtime_trace('ws.message.enter', {
		'conn_id':     state.conn_id
		'request_id':  state.request_id
		'opcode':      '${msg.opcode}'
		'payload_len': '${msg.payload.len}'
	})
	state.cb_mu.@lock()
	already_closed := state.close_notified
	state.cb_mu.unlock()
	if already_closed {
		runtime_trace('ws.message.ignored.closed', {
			'conn_id':    state.conn_id
			'request_id': state.request_id
		})
		return
	}
	opcode, payload, supported := ws.dispatch_payload_from_message(msg)
	if !supported {
		ws_client.close(1003, 'Only text and binary frames are supported') or {
			runtime_trace('ws.message.invalid.close.error', {
				'conn_id':    state.conn_id
				'request_id': state.request_id
				'error':      err.msg()
			})
		}
		return
	}
	presence := state.rt.presence(state.conn_id)
	state.cb_mu.@lock()
	worker.WorkerBackendFrameCodec.write_websocket_frame(mut state.worker_conn, transport.WorkerWebSocketFrame{
		mode:            'websocket'
		event:           'message'
		id:              state.request_id
		opcode:          opcode
		data:            payload
		rooms:           state.rt.rooms(state.conn_id)
		metadata:        state.rt.metadata(state.conn_id)
		room_members:    presence.room_members
		member_metadata: presence.member_metadata
		room_counts:     presence.room_counts
		presence_users:  presence.presence_users
	}) or {
		state.worker_initiated_close = true
		state.close_notified = true
		state.cb_mu.unlock()
		runtime_trace('ws.message.forward.error', {
			'conn_id':    state.conn_id
			'request_id': state.request_id
			'error':      err.msg()
		})
		ws_client.close(1011, 'Worker bridge write failed') or {}
		state.rt.unregister_conn(state.conn_id)
		state.worker_conn.close() or {}
		return
	}
	state.cb_mu.unlock()
	runtime_trace('ws.message.forwarded', {
		'conn_id':    state.conn_id
		'request_id': state.request_id
	})
	for {
		state.cb_mu.@lock()
		reply := worker.WorkerBackendFrameCodec.read_websocket_frame(mut state.worker_conn) or {
			state.worker_initiated_close = true
			state.close_notified = true
			state.cb_mu.unlock()
			runtime_trace('ws.message.reply.error', {
				'conn_id':    state.conn_id
				'request_id': state.request_id
				'error':      err.msg()
			})
			ws_client.close(1011, 'Worker bridge read failed') or {}
			state.rt.unregister_conn(state.conn_id)
			state.worker_conn.close() or {}
			return
		}
		state.cb_mu.unlock()
		if reply.mode != 'websocket' {
			continue
		}
		if _ := state.rt.process_worker_frame(reply) {
			continue
		}
		match reply.event {
			'close' {
				runtime_trace('ws.message.reply.close', {
					'conn_id':    state.conn_id
					'request_id': state.request_id
					'code':       '${reply.code}'
					'reason':     reply.reason
				})
				state.cb_mu.@lock()
				state.worker_initiated_close = true
				state.close_notified = true
				state.cb_mu.unlock()
				code := if reply.code > 0 { reply.code } else { 1000 }
				ws_client.close(code, reply.reason) or {
					runtime_trace('ws.message.reply.close.error', {
						'conn_id':    state.conn_id
						'request_id': state.request_id
						'error':      err.msg()
					})
				}
				return
			}
			'error' {}
			'done' {
				runtime_trace('ws.message.reply.done', {
					'conn_id':    state.conn_id
					'request_id': state.request_id
				})
				break
			}
			else {}
		}
	}
}

fn worker_websocket_close_cb(mut _ws websocket.Client, code int, reason string, ref voidptr) ! {
	mut state := unsafe { &ws.BridgeState(ref) }
	state.cb_mu.@lock()
	runtime_trace('ws.close.enter', {
		'conn_id':          state.conn_id
		'request_id':       state.request_id
		'code':             '${code}'
		'reason':           reason
		'worker_initiated': if state.worker_initiated_close { 'true' } else { 'false' }
	})
	if state.close_notified {
		state.cb_mu.unlock()
		return
	}
	state.close_notified = true
	if !state.worker_initiated_close {
		presence := state.rt.presence(state.conn_id)
		worker.WorkerBackendFrameCodec.write_websocket_frame(mut state.worker_conn, transport.WorkerWebSocketFrame{
			mode:            'websocket'
			event:           'close'
			id:              state.request_id
			code:            code
			reason:          reason
			rooms:           state.rt.rooms(state.conn_id)
			metadata:        state.rt.metadata(state.conn_id)
			room_members:    presence.room_members
			member_metadata: presence.member_metadata
			room_counts:     presence.room_counts
			presence_users:  presence.presence_users
		}) or {}
		for {
			reply := worker.WorkerBackendFrameCodec.read_websocket_frame(mut state.worker_conn) or {
				break
			}
			if reply.mode != 'websocket' {
				continue
			}
			if _ := state.rt.process_worker_frame(reply) {
				continue
			}
			if reply.event == 'done' {
				break
			}
			if reply.event == 'error' {
			}
		}
	}
	state.rt.unregister_conn(state.conn_id)
	state.worker_conn.close() or {}
	state.cb_mu.unlock()
	runtime_trace('ws.close.exit', {
		'conn_id':    state.conn_id
		'request_id': state.request_id
	})
}

fn proxy_worker_websocket(mut app App, mut ctx Context, method string, path string) veb.Result {
	if app.websocket.dispatch_enabled() {
		return proxy_worker_websocket_dispatch(mut app, mut ctx, method, path)
	}
	start_ms := time.now().unix_milli()
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	key := websocket_upgrade_key(ctx.req)
	remote_addr := if isnil(ctx.conn) { '' } else { ctx.conn.peer_ip() or { '' } }
	if method.to_upper() != 'GET' || key == '' || !is_websocket_upgrade(ctx.req) {
		return websocket_http_response(mut app, mut ctx, method, path, remote_addr, req_id,
			trace_id, start_ms, 426, {
			'content-type': 'text/plain; charset=utf-8'
			'upgrade':      'websocket'
		}, 'Upgrade Required', 'upgrade_required')
	}
	mut facade := app.as_facade()
	mut ws_open := app.engines.open_websocket_session(mut facade, executor.WebSocketSessionOpenRequest{
		req:         ctx.req
		remote_addr: remote_addr
		path:        path
		request_id:  req_id
		trace_id:    trace_id
	}) or {
		err_msg := err.msg()
		status, error_class := transport.classify_worker_backend_error(err_msg)
		return websocket_http_response(mut app, mut ctx, method, path, remote_addr, req_id,
			trace_id, start_ms, status, {
			'content-type': 'text/plain; charset=utf-8'
		}, 'Bad Gateway', error_class)
	}
	if !ws_open.accepted {
		return websocket_http_response(mut app, mut ctx, method, path, remote_addr, req_id,
			trace_id, start_ms, ws_open.status, {
			'content-type': 'text/plain; charset=utf-8'
		}, ws_open.body, '')
	}

	delivery := worker_websocket_session_delivery_outcome(ws_open, req_id, path)
	selected_socket := delivery.metadata['worker_socket'] or { ws_open.socket_path }
	ctx.takeover_conn()
	ctx.conn.set_write_timeout(time.infinite)
	ctx.conn.set_read_timeout(time.infinite)
	mut conn := ctx.conn
	mut worker_conn := ws_open.conn
	spawn handle_worker_websocket_session(mut app, mut conn, mut worker_conn, selected_socket,
		key, method.to_upper(), path, req_id, trace_id, start_ms)
	return veb.no_result()
}

fn proxy_worker_websocket_dispatch(mut app App, mut ctx Context, method string, path string) veb.Result {
	start_ms := time.now().unix_milli()
	remote_addr := if isnil(ctx.conn) { '' } else { ctx.conn.peer_ip() or { '' } }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	key := websocket_upgrade_key(ctx.req)
	normalized_path, query_string := transport.normalize_request_target(path)
	query := transport.parse_query_map(query_string)
	headers := transport.header_map_from_request(ctx.req)
	websocket_runtime := app.build_websocket_runtime_context()
	presence := websocket_runtime.presence(req_id)
	open_frame := websocket_runtime.build_frame('open', method, normalized_path, query, headers,
		remote_addr, req_id, trace_id, '', '', 0, '', websocket_runtime.rooms(req_id),
		websocket_runtime.metadata(req_id), presence)
	resp := websocket_runtime.dispatch_event(open_frame) or {
		err_msg := executor.InProcVjsxError.normalize_message(err.msg(),
			'inproc_vjsx_executor_websocket_open_failed')
		log.error('[vhttpd] kernel_dispatch_websocket_event failed trace_id=${trace_id} path=${normalized_path} error=${err_msg}')
		return websocket_http_response(mut app, mut ctx, method, path, remote_addr, req_id,
			trace_id, start_ms, 502, {
			'content-type': 'text/plain; charset=utf-8'
		}, 'Bad Gateway', 'transport_error')
	}
	if resp.event == 'error' {
		return websocket_http_response(mut app, mut ctx, method, path, remote_addr, req_id,
			trace_id, start_ms, 500, {
			'content-type': 'text/plain; charset=utf-8'
		}, 'WebSocket open failed', if resp.error_class != '' {
			resp.error_class
		} else {
			'worker_runtime_error'
		})
	}
	if !resp.accepted {
		result := websocket_runtime.command_result(resp.commands)
		if result.has_close {
			close_frame := result.close_frame
			status := if close_frame.status > 0 { close_frame.status } else { 403 }
			body := if close_frame.reason != '' { close_frame.reason } else { 'Forbidden' }
			return websocket_http_response(mut app, mut ctx, method, path, remote_addr, req_id,
				trace_id, start_ms, status, {
				'content-type': 'text/plain; charset=utf-8'
			}, body, '')
		}
		return websocket_http_response(mut app, mut ctx, method, path, remote_addr, req_id,
			trace_id, start_ms, 403, {
			'content-type': 'text/plain; charset=utf-8'
		}, 'Forbidden', '')
	}
	delivery := dispatch_websocket_session_delivery_outcome(resp, req_id, normalized_path)
	open_command_count := (delivery.metadata['command_count'] or { '${resp.commands.len}' }).int()
	mut open_commands := []transport.WorkerWebSocketFrame{cap: open_command_count}
	open_commands << resp.commands
	ctx.takeover_conn()
	ctx.conn.set_write_timeout(time.infinite)
	ctx.conn.set_read_timeout(time.infinite)
	mut conn := ctx.conn
	spawn ws.handle_dispatch_session(app.build_websocket_runtime_context(), mut conn, key,
		method.to_upper(), normalized_path, query, headers, remote_addr, req_id, trace_id,
		start_ms, open_commands)
	return veb.no_result()
}

fn handle_worker_websocket_session(mut app App, mut client_conn net.TcpConn, mut worker_conn unix.StreamConn, selected_socket string, key string, method string, path string, req_id string, trace_id string, start_ms i64) {
	runtime_trace('ws.session.start', {
		'request_id':    req_id
		'trace_id':      trace_id
		'path':          path
		'worker_socket': selected_socket
	})
	app.on_worker_request_started(selected_socket)
	defer {
		runtime_trace('ws.session.defer', {
			'request_id':    req_id
			'trace_id':      trace_id
			'path':          path
			'worker_socket': selected_socket
		})
		app.on_worker_request_finished(selected_socket)
	}
	mut ws_server := websocket.new_server(.ip, 0, '')
	websocket_runtime := app.build_websocket_runtime_context()
	mut state := &ws.BridgeState{
		worker_conn:   worker_conn
		rt:            websocket_runtime
		worker_socket: selected_socket
		conn_id:       req_id
		method:        method
		path:          path
		request_id:    req_id
		trace_id:      trace_id
		start_ms:      start_ms
	}
	ws_server.on_connect(fn [mut state] (mut sc websocket.ServerClient) !bool {
		runtime_trace('ws.session.connect', {
			'conn_id':       state.conn_id
			'request_id':    state.request_id
			'path':          state.path
			'worker_socket': state.worker_socket
		})
		state.rt.register_conn(state.conn_id, state.worker_socket, state.method, state.request_id,
			state.trace_id, state.path, map[string]string{}, map[string]string{}, '', sc.client,
			unsafe { nil })
		return true
	}) or {}
	ws_server.on_message_ref(worker_websocket_message_cb, state)
	ws_server.on_close_ref(worker_websocket_close_cb, state)
	ws_server.handle_handshake(mut client_conn, key) or {
		runtime_trace('ws.session.handshake.error', {
			'conn_id':    state.conn_id
			'request_id': state.request_id
			'path':       state.path
			'error':      err.msg()
		})
		state.rt.unregister_conn(state.conn_id)
		state.worker_conn.close() or {}
		return
	}
	state.rt.flush_pending(state.conn_id)
	runtime_trace('ws.session.handshake.done', {
		'conn_id':        state.conn_id
		'request_id':     state.request_id
		'close_notified': if state.close_notified { 'true' } else { 'false' }
	})
	if !state.close_notified {
		state.rt.unregister_conn(state.conn_id)
		state.worker_conn.close() or {}
		runtime_trace('ws.session.cleanup.no_close', {
			'conn_id':    state.conn_id
			'request_id': state.request_id
		})
	}
}
