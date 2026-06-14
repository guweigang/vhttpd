module main

import executor
import ws
import worker
import admin
import config
import json
import log
import net
import net.http
import net.unix
import net.websocket
import os
import sync
import time
import veb
import veb.request_id
import veb.sse
import upstream.transport

pub struct Context {
	veb.Context
	request_id.RequestIdContext
}

@[heap]
pub struct App {
	veb.Middleware[Context]
	veb.StaticHandler
pub:
	event_log string
pub mut:
	started_at_unix     i64
	http_stats          HttpStats
	mu                  sync.Mutex

	transport TransportRuntimeHub
	protocols ProtocolRuntimeHub
	providers ProviderRuntimeHub
	executors ExecutorRuntimeHub
	admin     admin.AdminState
	assets    config.AssetsRuntime
}

fn runtime_trace(label string, fields map[string]string) {
	mut row := map[string]string{}
	row['ts'] = time.now().format_ss_milli()
	row['label'] = label
	row['pid'] = '${os.getpid()}'
	for k, v in fields {
		row[k] = v
	}
	mut f := os.open_append('/tmp/vhttpd_runtime_trace.log') or { return }
	defer {
		f.close()
	}
	f.writeln(json.encode(row)) or {}
}

fn dispatch_core(method string, path string) (int, string, string) {
	m := method.to_upper()
	p := transport.normalize_path(path)

	if p == '/panic' {
		return 500, 'Internal Server Error', 'text/plain; charset=utf-8'
	}

	if p == '/health' {
		if m == 'GET' {
			return 200, 'OK', 'text/plain; charset=utf-8'
		}
		return 405, 'Method Not Allowed', 'text/plain; charset=utf-8'
	}

	if p.starts_with('/users/') {
		if m != 'GET' {
			return 405, 'Method Not Allowed', 'text/plain; charset=utf-8'
		}
		user_id := p.all_after('/users/')
		return 200, '{"user":"${user_id}"}', 'application/json; charset=utf-8'
	}

	return 404, 'Not Found', 'text/plain; charset=utf-8'
}

fn resolve_trace_id(ctx Context, path string) string {
	_, query_str := transport.normalize_request_target(path)
	query := transport.parse_query_map(query_str)
	if query['trace_id'] != '' {
		return query['trace_id']
	}
	headers := transport.header_map_from_request(ctx.req)
	for key in ['x-trace-id', 'x-request-id'] {
		if headers[key] != '' {
			return headers[key]
		}
	}
	if ctx.request_id != '' {
		return ctx.request_id
	}
	return 'vhttpd-${time.now().unix_micro()}'
}

fn resolve_request_id(ctx Context, path string) string {
	_, query_str := transport.normalize_request_target(path)
	query := transport.parse_query_map(query_str)
	if query['request_id'] != '' {
		return query['request_id']
	}
	if ctx.request_id != '' {
		return ctx.request_id
	}
	headers := transport.header_map_from_request(ctx.req)
	header_rid := headers['x-request-id']
	if header_rid != '' {
		return header_rid
	}
	return 'req-${time.now().unix_micro()}'
}

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
	if app.transport.websocket.dispatch_mode {
		return proxy_worker_websocket_dispatch(mut app, mut ctx, method, path)
	}
	start_ms := time.now().unix_milli()
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	key := websocket_upgrade_key(ctx.req)
	if method.to_upper() != 'GET' || key == '' || !is_websocket_upgrade(ctx.req) {
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.res.set_status(http.status_from_int(426))
		ctx.set_custom_header('upgrade', 'websocket') or {}
		return ctx.text('Upgrade Required')
	}
	remote_addr := if isnil(ctx.conn) { '' } else { ctx.conn.peer_ip() or { '' } }
	mut facade := app.as_facade()
	mut ws_open := app.executors.worker.logic_executor.open_websocket_session(mut facade, executor.WebSocketSessionOpenRequest{
		req:         ctx.req
		remote_addr: remote_addr
		path:        path
		request_id:  req_id
		trace_id:    trace_id
	}) or {
		err_msg := err.msg()
		status, error_class := transport.classify_worker_backend_error(err_msg)
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.set_custom_header('x-vhttpd-error-class', error_class) or {}
		ctx.res.set_status(http.status_from_int(status))
		return ctx.text('Bad Gateway')
	}
	if !ws_open.accepted {
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.res.set_status(http.status_from_int(ws_open.status))
		return ctx.text(ws_open.body)
	}

	ctx.takeover_conn()
	ctx.conn.set_write_timeout(time.infinite)
	ctx.conn.set_read_timeout(time.infinite)
	mut conn := ctx.conn
	mut worker_conn := ws_open.conn
	spawn handle_worker_websocket_session(mut app, mut conn, mut worker_conn, ws_open.socket_path,
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
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.set_custom_header('x-vhttpd-error-class', 'transport_error') or {}
		ctx.res.set_status(http.status_from_int(502))
		return ctx.text('Bad Gateway')
	}
	if resp.event == 'error' {
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.set_custom_header('x-vhttpd-error-class', if resp.error_class != '' {
			resp.error_class
		} else {
			'worker_runtime_error'
		}) or {}
		ctx.res.set_status(http.status_from_int(500))
		return ctx.text('WebSocket open failed')
	}
	if !resp.accepted {
		result := websocket_runtime.command_result(resp.commands)
		if result.has_close {
			close_frame := result.close_frame
			status := if close_frame.status > 0 { close_frame.status } else { 403 }
			body := if close_frame.reason != '' { close_frame.reason } else { 'Forbidden' }
			ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
			ctx.res.set_status(http.status_from_int(status))
			return ctx.text(body)
		}
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.res.set_status(http.status_from_int(403))
		return ctx.text('Forbidden')
	}
	ctx.takeover_conn()
	ctx.conn.set_write_timeout(time.infinite)
	ctx.conn.set_read_timeout(time.infinite)
	mut conn := ctx.conn
	spawn ws.handle_dispatch_session(app.build_websocket_runtime_context(), mut conn, key,
		method.to_upper(), normalized_path, query, headers, remote_addr, req_id, trace_id,
		start_ms, resp.commands.clone())
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

fn proxy_worker_response(mut app App, mut ctx Context, method string, path string, body_on_head string) veb.Result {
	start_ms := time.now().unix_milli()
	if is_websocket_upgrade(ctx.req) {
		return proxy_worker_websocket(mut app, mut ctx, method, path)
	}
	remote_addr := if isnil(ctx.conn) { '' } else { ctx.conn.peer_ip() or { '' } }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	log.info('[http] ⇢ dispatch method=${method.to_upper()} path=${path} trace_id=${trace_id} request_id=${req_id} body_len=${ctx.req.data.len} executor=${app.logic_executor_kind()}')
	if app.executors.worker.stream_dispatch {
		if result := HttpStreamRuntime.via_dispatch(mut app, mut ctx, method, path, req_id,
			trace_id, remote_addr)
		{
			return result
		}
	}
	mut facade := app.as_facade()
	mut outcome := app.executors.worker.logic_executor.dispatch_http(mut facade, executor.HttpLogicDispatchRequest{
		method:      method
		path:        path
		req:         ctx.req
		remote_addr: remote_addr
		trace_id:    trace_id
		request_id:  req_id
	}) or {
		err_msg := err.msg()
		status, error_class := transport.classify_worker_backend_error(err_msg)
		log.error('[http] ⇠ dispatch error method=${method.to_upper()} path=${path} trace_id=${trace_id} request_id=${req_id} status=${status} duration_ms=${time.now().unix_milli() - start_ms} error=${err_msg}')
		app.emit('http.request', {
			'method':      method.to_upper()
			'path':        transport.normalize_path(path)
			'status':      '${status}'
			'request_id':  req_id
			'trace_id':    trace_id
			'duration_ms': '${time.now().unix_milli() - start_ms}'
			'error_class': error_class
			'error':       err_msg
		})
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.set_custom_header('x-vhttpd-error-class', error_class) or {}
		ctx.res.set_status(http.status_from_int(status))
		return ctx.text(body_on_head)
	}
	if outcome.kind == .stream {
		log.info('[http] ⇠ dispatch stream method=${method.to_upper()} path=${path} trace_id=${trace_id} request_id=${req_id} socket=${outcome.socket_path} duration_ms=${time.now().unix_milli() - start_ms}')
		mut conn := outcome.conn
		selected_socket := outcome.socket_path
		start := outcome.stream_start
		defer {
			conn.close() or {}
			app.on_worker_request_finished(selected_socket)
		}
		if (start.stream_type == 'sse' || start.content_type.starts_with('text/event-stream'))
			&& method.to_upper() != 'HEAD' {
			return HttpStreamRuntime.via_sse(mut app, mut ctx, mut conn, start, method, path,
				req_id, trace_id, start_ms)
		}
		return HttpStreamRuntime.via_passthrough(mut app, mut ctx, mut conn, start, method,
			path, req_id, trace_id, start_ms)
	}
	if outcome.kind == .upstream_plan {
		log.info('[http] ⇠ dispatch upstream_plan method=${method.to_upper()} path=${path} trace_id=${trace_id} request_id=${req_id} duration_ms=${time.now().unix_milli() - start_ms}')
		upstream_runtime := app.build_upstream_runtime_context()
		return UpstreamRuntimeContext.execute_plan(upstream_runtime, mut ctx,
			outcome.upstream_plan, method, path, req_id, trace_id, start_ms)
	}
	resp := outcome.response
	log.info('[http] ⇠ dispatch response method=${method.to_upper()} path=${path} trace_id=${trace_id} request_id=${req_id} status=${resp.status} body_len=${resp.body.len} duration_ms=${time.now().unix_milli() - start_ms}')
	app.emit('http.request', {
		'method':      method.to_upper()
		'path':        transport.normalize_path(path)
		'status':      '${resp.status}'
		'request_id':  req_id
		'trace_id':    trace_id
		'duration_ms': '${time.now().unix_milli() - start_ms}'
	})
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	ctx.res.set_status(http.status_from_int(resp.status))
	apply_worker_headers(mut ctx, resp.headers)
	ctype := resp.headers['content-type'] or { 'text/plain; charset=utf-8' }
	ctx.set_content_type(ctype)
	return ctx.text(if body_on_head == '' && method.to_upper() == 'HEAD' { '' } else { resp.body })
}

fn apply_worker_headers(mut ctx Context, headers map[string]string) {
	for name, value in headers {
		lower := name.to_lower()
		if lower == 'content-type' || lower == 'content-length' || lower == 'server'
			|| lower == 'x-request-id' {
			continue
		}
		ctx.set_custom_header(name, value) or {}
	}
}

fn (mut app App) emit(kind string, fields map[string]string) {
	if kind in ['server.started', 'server.failed', 'server.stopped', 'admin.started', 'admin.failed',
		'internal_admin.started', 'internal_admin.error', 'worker.select.failed'] {
		runtime_trace('emit.${kind}', fields)
	}
	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	if kind == 'http.request' {
		app.http_stats.inc_requests()
		status := (fields['status'] or { '0' }).int()
		if status >= 400 {
			app.http_stats.inc_errors()
		}
		error_class := fields['error_class'] or { '' }
		if error_class == 'timeout' {
			app.http_stats.inc_timeouts()
		}
		if (fields['response_mode'] or { '' }) == 'stream' {
			app.http_stats.inc_streams()
		}
	}
	if kind.starts_with('admin.') {
		app.http_stats.inc_admin_actions()
	}
	mut row := map[string]string{}
	row['type'] = kind
	row['ts'] = '${time.now().unix()}'
	for k, v in fields {
		row[k] = v
	}
	mut f := os.open_append(app.event_log) or { return }
	defer {
		f.close()
	}
	f.writeln(json.encode(row)) or {}
}

@[get]
pub fn (mut app App) health(mut ctx Context) veb.Result {
	log.info('[http] route health url=${ctx.req.url} method=GET')
	req_id := resolve_request_id(ctx, '/health')
	status, body, _ := dispatch_core('GET', '/health')
	app.emit('http.request', {
		'method':     'GET'
		'path':       '/health'
		'status':     '${status}'
		'request_id': req_id
	})
	ctx.res.set_status(http.status_from_int(status))
	return ctx.text(body)
}

@['/dispatch'; get]
pub fn (mut app App) dispatch(mut ctx Context) veb.Result {
	start_ms := time.now().unix_milli()
	method := ctx.query['method'] or { 'GET' }
	path := ctx.query['path'] or { '/health' }
	req_id := resolve_request_id(ctx, path)
	if app.has_http_logic_executor() {
		return proxy_worker_response(mut app, mut ctx, method, path, 'Bad Gateway')
	}
	mut status := 200
	mut body := ''
	mut ctype := 'text/plain; charset=utf-8'
	status, body, ctype = dispatch_core(method, path)
	app.emit('http.request', {
		'method':      method.to_upper()
		'path':        transport.normalize_path(path)
		'status':      '${status}'
		'request_id':  req_id
		'duration_ms': '${time.now().unix_milli() - start_ms}'
	})
	ctx.res.set_status(http.status_from_int(status))
	ctx.set_content_type(ctype)
	return ctx.text(body)
}

@['/dispatch'; head]
pub fn (mut app App) dispatch_head(mut ctx Context) veb.Result {
	start_ms := time.now().unix_milli()
	method := ctx.query['method'] or { 'GET' }
	path := ctx.query['path'] or { '/health' }
	req_id := resolve_request_id(ctx, path)
	if app.has_http_logic_executor() {
		return proxy_worker_response(mut app, mut ctx, method, path, '')
	}
	mut status := 200
	mut body := ''
	mut ctype := 'text/plain; charset=utf-8'
	status, body, ctype = dispatch_core(method, path)
	app.emit('http.request', {
		'method':      method.to_upper()
		'path':        transport.normalize_path(path)
		'status':      '${status}'
		'request_id':  req_id
		'duration_ms': '${time.now().unix_milli() - start_ms}'
	})
	ctx.res.set_status(http.status_from_int(status))
	ctx.set_content_type(ctype)
	return ctx.text(body)
}

@['/events/stream'; get]
pub fn (mut app App) events_stream(mut ctx Context) veb.Result {
	start_ms := time.now().unix_milli()
	path := if ctx.req.url == '' { '/events/stream' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	mut count := (ctx.query['count'] or { '3' }).int()
	if count < 1 {
		count = 1
	}
	if count > 20 {
		count = 20
	}
	mut interval_ms := (ctx.query['interval_ms'] or { '150' }).int()
	if interval_ms < 0 {
		interval_ms = 0
	}
	if interval_ms > 1000 {
		interval_ms = 1000
	}

	ctx.takeover_conn()
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	ctx.set_custom_header('x-accel-buffering', 'no') or {}
	mut stream := sse.start_connection(mut ctx.Context)
	stream.send_message(retry: 1000) or { return ctx.server_error_with_status(.not_implemented) }
	for i in 0 .. count {
		payload := json.encode({
			'request_id': req_id
			'trace_id':   trace_id
			'seq':        '${i + 1}'
			'ts':         '${time.now().unix()}'
		})
		stream.send_message(id: '${req_id}-${i + 1}', event: 'ping', data: payload) or {
			return veb.no_result()
		}
		if i + 1 < count && interval_ms > 0 {
			time.sleep(time.millisecond * interval_ms)
		}
	}
	stream.close()

	app.emit('http.request', {
		'method':      'GET'
		'path':        '/events/stream'
		'status':      '200'
		'request_id':  req_id
		'trace_id':    trace_id
		'duration_ms': '${time.now().unix_milli() - start_ms}'
	})
	return veb.no_result()
}

@['/:path...'; get]
pub fn (mut app App) proxy_get(mut ctx Context, path string) veb.Result {
	start_ms := time.now().unix_milli()
	log.info('[http] route proxy_get path=${path} url=${ctx.req.url}')
	target := if ctx.req.url == '' { path } else { ctx.req.url }
	req_id := resolve_request_id(ctx, target)
	trace_id := resolve_trace_id(ctx, target)
	if result := app.openai_try_handle(mut ctx, 'GET', target, req_id, trace_id, start_ms) {
		return result
	}
	request_path, _ := transport.normalize_request_target(target)
	normalized_target := transport.normalize_path(request_path)
	if normalized_target == '/mcp' {
		return app.mcp_get(mut ctx)
	}
	if !app.has_http_logic_executor() {
		ctx.res.set_status(.not_found)
		return ctx.text('Not Found')
	}
	return proxy_worker_response(mut app, mut ctx, 'GET', target, '')
}

@['/:path...'; post]
pub fn (mut app App) proxy_post(mut ctx Context, path string) veb.Result {
	start_ms := time.now().unix_milli()
	log.info('[http] route proxy_post path=${path} url=${ctx.req.url} body_len=${ctx.req.data.len}')
	target := if ctx.req.url == '' { path } else { ctx.req.url }
	req_id := resolve_request_id(ctx, target)
	trace_id := resolve_trace_id(ctx, target)
	if result := app.openai_try_handle(mut ctx, 'POST', target, req_id, trace_id, start_ms) {
		return result
	}
	request_path, _ := transport.normalize_request_target(target)
	normalized_target := transport.normalize_path(request_path)
	if normalized_target == '/mcp' {
		return app.mcp_post(mut ctx)
	}
	if !app.has_http_logic_executor() {
		ctx.res.set_status(.not_found)
		return ctx.text('Not Found')
	}
	return proxy_worker_response(mut app, mut ctx, 'POST', target, '')
}

@['/:path...'; put]
pub fn (mut app App) proxy_put(mut ctx Context, path string) veb.Result {
	start_ms := time.now().unix_milli()
	target := if ctx.req.url == '' { path } else { ctx.req.url }
	req_id := resolve_request_id(ctx, target)
	trace_id := resolve_trace_id(ctx, target)
	if result := app.openai_try_handle(mut ctx, 'PUT', target, req_id, trace_id, start_ms) {
		return result
	}
	if !app.has_http_logic_executor() {
		ctx.res.set_status(.not_found)
		return ctx.text('Not Found')
	}
	return proxy_worker_response(mut app, mut ctx, 'PUT', target, '')
}

@['/:path...'; patch]
pub fn (mut app App) proxy_patch(mut ctx Context, path string) veb.Result {
	start_ms := time.now().unix_milli()
	target := if ctx.req.url == '' { path } else { ctx.req.url }
	req_id := resolve_request_id(ctx, target)
	trace_id := resolve_trace_id(ctx, target)
	if result := app.openai_try_handle(mut ctx, 'PATCH', target, req_id, trace_id, start_ms) {
		return result
	}
	if !app.has_http_logic_executor() {
		ctx.res.set_status(.not_found)
		return ctx.text('Not Found')
	}
	return proxy_worker_response(mut app, mut ctx, 'PATCH', target, '')
}

@['/:path...'; delete]
pub fn (mut app App) proxy_delete(mut ctx Context, path string) veb.Result {
	start_ms := time.now().unix_milli()
	target := if ctx.req.url == '' { path } else { ctx.req.url }
	req_id := resolve_request_id(ctx, target)
	trace_id := resolve_trace_id(ctx, target)
	if result := app.openai_try_handle(mut ctx, 'DELETE', target, req_id, trace_id, start_ms) {
		return result
	}
	if transport.normalize_path(target) == '/mcp' {
		return app.mcp_delete(mut ctx)
	}
	if !app.has_http_logic_executor() {
		ctx.res.set_status(.not_found)
		return ctx.text('Not Found')
	}
	return proxy_worker_response(mut app, mut ctx, 'DELETE', target, '')
}

@['/:path...'; head]
pub fn (mut app App) proxy_head(mut ctx Context, path string) veb.Result {
	start_ms := time.now().unix_milli()
	target := if ctx.req.url == '' { path } else { ctx.req.url }
	req_id := resolve_request_id(ctx, target)
	trace_id := resolve_trace_id(ctx, target)
	if result := app.openai_try_handle(mut ctx, 'HEAD', target, req_id, trace_id, start_ms) {
		return result
	}
	if !app.has_http_logic_executor() {
		ctx.res.set_status(.not_found)
		return ctx.text('')
	}
	return proxy_worker_response(mut app, mut ctx, 'HEAD', target, '')
}
