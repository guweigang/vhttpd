module main

import json
import net
import net.http
import net.urllib
import net.unix
import net.websocket
import os
import sync
import time
import veb
import veb.request_id
import veb.sse

pub struct Context {
	veb.Context
	request_id.RequestIdContext
}

pub struct App {
	veb.Middleware[Context]
	veb.StaticHandler
pub:
	event_log string
pub mut:
	started_at_unix                             i64
	worker_backend                              WorkerBackendRuntime
	internal_admin_socket                       string
	stream_dispatch                             bool
	websocket_dispatch_mode                     bool
	admin_on_data_plane                         bool
	admin_token                                 string
	assets_enabled                              bool
	assets_prefix                               string
	assets_root                                 string
	assets_root_real                            string
	assets_cache_control                        string
	mcp_max_sessions                            int
	mcp_max_pending_messages                    int
	mcp_session_ttl_seconds                     int
	mcp_sampling_capability_policy              string
	mcp_allowed_origins                         []string
	feishu_enabled                              bool
	feishu_open_base_url                        string
	feishu_reconnect_delay_ms                   int
	feishu_token_refresh_skew_seconds           int
	feishu_recent_event_limit                   int
	websocket_upstream_recent_dispatch_limit    int
	feishu_apps                                 map[string]FeishuAppConfig
	stat_http_requests_total                    i64
	stat_http_errors_total                      i64
	stat_http_timeouts_total                    i64
	stat_http_streams_total                     i64
	stat_admin_actions_total                    i64
	stat_worker_queue_waits_total               i64
	stat_worker_queue_rejected_total            i64
	stat_worker_queue_timeouts_total            i64
	stat_upstream_plans_total                   i64
	stat_upstream_plan_errors_total             i64
	stat_mcp_sessions_expired_total             i64
	stat_mcp_sessions_evicted_total             i64
	stat_mcp_pending_dropped_total              i64
	stat_mcp_sampling_capability_warnings_total i64
	stat_mcp_sampling_capability_dropped_total  i64
	stat_mcp_sampling_capability_errors_total   i64
	pool_mu                                     sync.Mutex
	mu                                          sync.Mutex
	upstream_mu                                 sync.Mutex
	mcp_mu                                      sync.Mutex
	ws_hub_mu                                   sync.Mutex
	ws_hub_send_mu                              sync.Mutex
	feishu_mu                                   sync.Mutex
	feishu_http_test_mu                         sync.Mutex
	upstream_sessions                           map[string]UpstreamRuntimeSession
	mcp_sessions                                map[string]McpSession
	ws_hub_conns                                map[string]HubConn
	ws_hub_room_members                         map[string]map[string]bool
	ws_hub_conn_rooms                           map[string]map[string]bool
	ws_hub_conn_meta                            map[string]map[string]string
	ws_hub_pending                              map[string][]HubPendingMessage
	feishu_runtime                              map[string]FeishuProviderRuntime
	providers                                   ProviderHost
	fixture_websocket_runtime                   map[string]FixtureWebSocketUpstreamRuntime
	websocket_upstream_recent_activities        []WebSocketUpstreamActivitySnapshot
	// codex upstream
	codex_mu                 sync.Mutex
	codex_runtime            CodexProviderRuntime
	ollama_enabled          bool
	feishu_buffers           map[string]FeishuStreamBuffer
	feishu_http_lane         shared FeishuHttpLane
	feishu_http_test_stub    bool
	feishu_http_test_delay_ms int
	feishu_http_test_inflight int
	feishu_http_test_calls int
	feishu_http_test_message_seq int
}

struct CodexTarget {
	platform   string
	message_id string
}

struct WorkerResponse {
	id      string
	status  int
	body    string
	headers map[string]string
}

struct WorkerStreamFrame {
	mode         string
	strategy     string
	event        string
	id           string
	status       int
	stream_type  string @[json: 'stream_type']
	content_type string @[json: 'content_type']
	headers      map[string]string
	data         string
	sse_id       string @[json: 'sse_id']
	sse_event    string @[json: 'sse_event']
	sse_retry    int    @[json: 'sse_retry']
	error        string
	error_class  string @[json: 'error_class']
}

struct StreamDispatchRequest {
	mode        string
	strategy    string
	event       string
	id          string
	method      string
	path        string
	body        string
	remote_addr string @[json: 'remote_addr']
	request_id  string @[json: 'request_id']
	trace_id    string @[json: 'trace_id']
	query       map[string]string
	headers     map[string]string
	state       map[string]string
	reason      string
}

struct StreamDispatchChunk {
	event string
	id    string
	data  string
	retry int
}

struct StreamDispatchResponse {
	mode         string
	strategy     string
	event        string
	id           string
	handled      bool
	done         bool
	stream_type  string @[json: 'stream_type']
	content_type string @[json: 'content_type']
	headers      map[string]string
	state        map[string]string
	chunks       []StreamDispatchChunk
	error        string
	error_class  string @[json: 'error_class']
}

struct WorkerUpstreamPlanFrame {
	mode                string
	strategy            string
	event               string
	id                  string
	transport           string
	url                 string
	method              string
	request_headers     map[string]string @[json: 'request_headers']
	body                string
	codec               string
	mapper              string
	output_stream_type  string            @[json: 'output_stream_type']
	output_content_type string            @[json: 'output_content_type']
	response_headers    map[string]string @[json: 'response_headers']
	fixture_path        string            @[json: 'fixture_path']
	name                string
	meta                map[string]string
}

struct OllamaNdjsonMessage {
	content string
}

struct OllamaNdjsonRow {
	message  OllamaNdjsonMessage
	response string
	done     bool
}

struct WorkerRequestPayload {
	id               string
	method           string
	path             string
	body             string
	scheme           string
	host             string
	port             string
	protocol_version string
	remote_addr      string
	query            map[string]string
	headers          map[string]string
	cookies          map[string]string
	attributes       map[string]string
	server           map[string]string
	uploaded_files   []string
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

struct WorkerWebSocketFrame {
	mode            string
	event           string
	id              string
	path            string
	query           map[string]string
	headers         map[string]string
	remote_addr     string @[json: 'remote_addr']
	request_id      string @[json: 'request_id']
	trace_id        string @[json: 'trace_id']
	target_id       string @[json: 'target_id']
	room            string
	key             string
	value           string
	except_id       string @[json: 'except_id']
	rooms           []string
	metadata        map[string]string
	room_members    map[string][]string          @[json: 'room_members']
	member_metadata map[string]map[string]string @[json: 'member_metadata']
	room_counts     map[string]int               @[json: 'room_counts']
	presence_users  map[string][]string          @[json: 'presence_users']
	status          int
	code            int
	reason          string
	opcode          string
	data            string
	error           string
	error_class     string @[json: 'error_class']
}

struct WorkerWebSocketDispatchResponse {
	mode        string
	event       string
	id          string
	accepted    bool
	closed      bool
	commands    []WorkerWebSocketFrame
	error       string
	error_class string @[json: 'error_class']
}

struct WorkerMcpDispatchRequest {
	mode                     string
	event                    string
	id                       string
	http_method              string @[json: 'http_method']
	path                     string
	headers                  map[string]string
	protocol_version         string @[json: 'protocol_version']
	accept                   string
	content_type             string @[json: 'content_type']
	body                     string
	jsonrpc_raw              string @[json: 'jsonrpc_raw']
	remote_addr              string @[json: 'remote_addr']
	request_id               string @[json: 'request_id']
	trace_id                 string @[json: 'trace_id']
	session_id               string @[json: 'session_id']
	client_capabilities_json string @[json: 'client_capabilities_json']
}

struct WorkerMcpDispatchResponse {
	mode             string
	event            string
	id               string
	handled          bool
	status           int
	headers          map[string]string
	body             string
	protocol_version string @[json: 'protocol_version']
	session_id       string @[json: 'session_id']
	messages         []string
	commands         []WorkerWebSocketUpstreamCommand
	error            string
	error_class      string @[json: 'error_class']
}

struct WorkerWebSocketUpstreamDispatchRequest {
	mode        string
	event       string
	id          string
	provider    string
	instance    string
	trace_id    string @[json: 'trace_id']
	event_type  string @[json: 'event_type']
	message_id  string @[json: 'message_id']
	target      string
	target_type string @[json: 'target_type']
	payload     string
	received_at i64 @[json: 'received_at']
	metadata    map[string]string
}

pub struct WorkerWebSocketUpstreamCommand {
pub mut:
	event          string
	provider       string
	instance       string
	target         string
	target_type    string @[json: 'target_type']
	message_type   string @[json: 'message_type']
	content        string
	content_fields map[string]string @[json: 'content_fields']
	text           string
	uuid           string
	metadata       map[string]string

	// unified command dispatch structure
	type_       string @[json: 'type']
	stream_id   string @[json: 'stream_id']
	session_key string @[json: 'session_key']
	task_type   string @[json: 'task_type']
	prompt      string
	method      string
	params      string
}

struct WorkerWebSocketUpstreamDispatchResponse {
	mode        string
	event       string
	id          string
	handled     bool
	commands    []WorkerWebSocketUpstreamCommand
	error       string
	error_class string @[json: 'error_class']
}

struct UpstreamRuntimeSession {
	id              string
	request_id      string
	trace_id        string
	role            string
	provider        string
	method          string
	path            string
	name            string
	transport       string
	codec           string
	mapper          string
	stream_type     string
	source          string
	started_at_unix i64
}

fn header_map_from_request(req http.Request) map[string]string {
	mut out := map[string]string{}
	for key in req.header.keys() {
		values := req.header.custom_values(key)
		if values.len == 0 {
			continue
		}
		out[key.to_lower()] = values.join(', ')
	}
	return out
}

fn cookie_map_from_request(req http.Request) map[string]string {
	mut out := map[string]string{}
	for cookie in http.read_cookies(req.header, '') {
		out[cookie.name] = cookie.value
	}
	return out
}

fn server_map_from_request(req http.Request, remote_addr string) map[string]string {
	mut host := req.host
	mut port := ''
	if host == '' {
		host = req.header.get(.host) or { '' }
	}
	if host != '' {
		host, port = urllib.split_host_port(host)
	}
	return {
		'host':        host
		'port':        port
		'remote_addr': remote_addr
		'method':      req.method.str()
		'url':         req.url
	}
}

fn normalize_path(path string) string {
	if path.len == 0 {
		return '/'
	}
	if path.starts_with('/') {
		return path
	}
	return '/${path}'
}

fn normalize_assets_prefix(raw string) string {
	mut prefix := raw.trim_space()
	if prefix == '' {
		return '/assets'
	}
	if !prefix.starts_with('/') {
		prefix = '/${prefix}'
	}
	for prefix.len > 1 && prefix.ends_with('/') {
		prefix = prefix[..prefix.len - 1]
	}
	return prefix
}

fn dispatch_core(method string, path string) (int, string, string) {
	m := method.to_upper()
	p := normalize_path(path)

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
	_, query_str := normalize_request_target(path)
	query := parse_query_map(query_str)
	if query['trace_id'] != '' {
		return query['trace_id']
	}
	headers := header_map_from_request(ctx.req)
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
	_, query_str := normalize_request_target(path)
	query := parse_query_map(query_str)
	if query['request_id'] != '' {
		return query['request_id']
	}
	if ctx.request_id != '' {
		return ctx.request_id
	}
	headers := header_map_from_request(ctx.req)
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
	headers := header_map_from_request(req)
	upgrade := headers['upgrade']
	connection := headers['connection']
	key := headers['sec-websocket-key']
	return upgrade.to_lower() == 'websocket' && connection.to_lower().contains('upgrade')
		&& key != ''
}

fn worker_websocket_open(mut app App, mut conn unix.StreamConn, req http.Request, remote_addr string, path string, req_id string, trace_id string) !(bool, int, string) {
	normalized_path, query_string := normalize_request_target(path)
	query := parse_query_map(query_string)
	room_members, member_metadata, room_counts, presence_users := app.ws_hub_presence_snapshot(req_id)
	frame := WorkerWebSocketFrame{
		mode:            'websocket'
		event:           'open'
		id:              req_id
		path:            normalized_path
		query:           query
		headers:         header_map_from_request(req)
		remote_addr:     remote_addr
		request_id:      req_id
		trace_id:        trace_id
		rooms:           app.ws_hub_rooms_snapshot(req_id)
		metadata:        app.ws_hub_meta_snapshot(req_id)
		room_members:    room_members
		member_metadata: member_metadata
		room_counts:     room_counts
		presence_users:  presence_users
	}
	write_worker_websocket_frame(mut conn, frame)!
	mut accepted := false
	for {
		reply := read_worker_websocket_frame(mut conn)!
		if reply.mode != 'websocket' {
			continue
		}
		if app.process_worker_websocket_hub_frame(reply) {
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

fn worker_websocket_message_cb(mut ws websocket.Client, msg &websocket.Message, ref voidptr) ! {
	mut state := unsafe { &WebSocketBridgeState(ref) }
	runtime_trace('ws.message.enter', {
		'conn_id': state.conn_id
		'request_id': state.request_id
		'opcode': '${msg.opcode}'
		'payload_len': '${msg.payload.len}'
	})
	state.cb_mu.@lock()
	already_closed := state.close_notified
	state.cb_mu.unlock()
	if already_closed {
		runtime_trace('ws.message.ignored.closed', {
			'conn_id': state.conn_id
			'request_id': state.request_id
		})
		return
	}
	if msg.opcode != .text_frame {
		ws.close(1003, 'Only text frames are supported') or {
			runtime_trace('ws.message.invalid.close.error', {
				'conn_id': state.conn_id
				'request_id': state.request_id
				'error': err.msg()
			})
		}
		return
	}
	room_members, member_metadata, room_counts, presence_users := state.app.ws_hub_presence_snapshot(state.conn_id)
	state.cb_mu.@lock()
	write_worker_websocket_frame(mut state.worker_conn, WorkerWebSocketFrame{
		mode:            'websocket'
		event:           'message'
		id:              state.request_id
		opcode:          'text'
		data:            msg.payload.bytestr()
		rooms:           state.app.ws_hub_rooms_snapshot(state.conn_id)
		metadata:        state.app.ws_hub_meta_snapshot(state.conn_id)
		room_members:    room_members
		member_metadata: member_metadata
		room_counts:     room_counts
		presence_users:  presence_users
	}) or {
		state.worker_initiated_close = true
		state.close_notified = true
		state.cb_mu.unlock()
		runtime_trace('ws.message.forward.error', {
			'conn_id': state.conn_id
			'request_id': state.request_id
			'error': err.msg()
		})
		ws.close(1011, 'Worker bridge write failed') or {}
		state.app.ws_hub_unregister_conn(state.conn_id)
		state.worker_conn.close() or {}
		return
	}
	state.cb_mu.unlock()
	runtime_trace('ws.message.forwarded', {
		'conn_id': state.conn_id
		'request_id': state.request_id
	})
	for {
		state.cb_mu.@lock()
		reply := read_worker_websocket_frame(mut state.worker_conn) or {
			state.worker_initiated_close = true
			state.close_notified = true
			state.cb_mu.unlock()
			runtime_trace('ws.message.reply.error', {
				'conn_id': state.conn_id
				'request_id': state.request_id
				'error': err.msg()
			})
			ws.close(1011, 'Worker bridge read failed') or {}
			state.app.ws_hub_unregister_conn(state.conn_id)
			state.worker_conn.close() or {}
			return
		}
		state.cb_mu.unlock()
		if reply.mode != 'websocket' {
			continue
		}
		if state.app.process_worker_websocket_hub_frame(reply) {
			continue
		}
		match reply.event {
			'close' {
				runtime_trace('ws.message.reply.close', {
					'conn_id': state.conn_id
					'request_id': state.request_id
					'code': '${reply.code}'
					'reason': reply.reason
				})
				state.cb_mu.@lock()
				state.worker_initiated_close = true
				state.close_notified = true
				state.cb_mu.unlock()
				code := if reply.code > 0 { reply.code } else { 1000 }
				ws.close(code, reply.reason) or {
					runtime_trace('ws.message.reply.close.error', {
						'conn_id': state.conn_id
						'request_id': state.request_id
						'error': err.msg()
					})
				}
				return
			}
			'error' {}
			'done' {
				runtime_trace('ws.message.reply.done', {
					'conn_id': state.conn_id
					'request_id': state.request_id
				})
				break
			}
			else {}
		}
	}
}

fn worker_websocket_close_cb(mut ws websocket.Client, code int, reason string, ref voidptr) ! {
	mut state := unsafe { &WebSocketBridgeState(ref) }
	state.cb_mu.@lock()
	runtime_trace('ws.close.enter', {
		'conn_id': state.conn_id
		'request_id': state.request_id
		'code': '${code}'
		'reason': reason
		'worker_initiated': if state.worker_initiated_close { 'true' } else { 'false' }
	})
	if state.close_notified {
		state.cb_mu.unlock()
		return
	}
	state.close_notified = true
	if !state.worker_initiated_close {
		room_members, member_metadata, room_counts, presence_users := state.app.ws_hub_presence_snapshot(state.conn_id)
		write_worker_websocket_frame(mut state.worker_conn, WorkerWebSocketFrame{
			mode:            'websocket'
			event:           'close'
			id:              state.request_id
			code:            code
			reason:          reason
			rooms:           state.app.ws_hub_rooms_snapshot(state.conn_id)
			metadata:        state.app.ws_hub_meta_snapshot(state.conn_id)
			room_members:    room_members
			member_metadata: member_metadata
			room_counts:     room_counts
			presence_users:  presence_users
		}) or {}
		for {
			reply := read_worker_websocket_frame(mut state.worker_conn) or { break }
			if reply.mode != 'websocket' {
				continue
			}
			if state.app.process_worker_websocket_hub_frame(reply) {
				continue
			}
			if reply.event == 'done' {
				break
			}
			if reply.event == 'error' {
			}
		}
	}
	state.app.ws_hub_unregister_conn(state.conn_id)
	state.worker_conn.close() or {}
	state.cb_mu.unlock()
	runtime_trace('ws.close.exit', {
		'conn_id': state.conn_id
		'request_id': state.request_id
	})
}

fn proxy_worker_websocket(mut app App, mut ctx Context, method string, path string) veb.Result {
	if app.websocket_dispatch_mode {
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
	selected_socket := app.worker_backend_select_socket_queued() or {
		err_msg := err.msg()
		status, error_class := classify_worker_error(err_msg)
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.set_custom_header('x-vhttpd-error-class', error_class) or {}
		ctx.res.set_status(http.status_from_int(status))
		return ctx.text('Bad Gateway')
	}
	mut worker_conn := unix.connect_stream(selected_socket) or {
		err_msg := err.msg()
		status, error_class := classify_worker_error(err_msg)
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.set_custom_header('x-vhttpd-error-class', error_class) or {}
		ctx.res.set_status(http.status_from_int(status))
		return ctx.text('Bad Gateway')
	}
	if app.worker_backend.read_timeout_ms > 0 {
		worker_conn.set_read_timeout(time.millisecond * app.worker_backend.read_timeout_ms)
	}
	accepted, status, body := worker_websocket_open(mut app, mut worker_conn, ctx.req,
		remote_addr, path, req_id, trace_id) or {
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.set_custom_header('x-vhttpd-error-class', 'transport_error') or {}
		ctx.res.set_status(http.status_from_int(502))
		worker_conn.close() or {}
		return ctx.text('Bad Gateway')
	}
	if !accepted {
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.res.set_status(http.status_from_int(status))
		worker_conn.close() or {}
		return ctx.text(body)
	}

	ctx.takeover_conn()
	ctx.conn.set_write_timeout(time.infinite)
	ctx.conn.set_read_timeout(time.infinite)
	mut conn := ctx.conn
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
	normalized_path, query_string := normalize_request_target(path)
	query := parse_query_map(query_string)
	headers := header_map_from_request(ctx.req)
	open_frame := app.kernel_websocket_dispatch_frame(
		'open',
		method,
		normalized_path,
		query,
		headers,
		remote_addr,
		req_id,
		trace_id,
		'',
		'',
		0,
		'',
		app.ws_hub_rooms_snapshot(req_id),
		app.ws_hub_meta_snapshot(req_id),
		map[string][]string{},
		map[string]map[string]string{},
		map[string]int{},
		map[string][]string{},
	)
	resp := app.kernel_dispatch_websocket_event(open_frame) or {
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
	if close_frame := app.execute_websocket_dispatch_commands(resp.commands) {
		status := if close_frame.status > 0 { close_frame.status } else { 403 }
		body := if close_frame.reason != '' { close_frame.reason } else { 'Forbidden' }
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.res.set_status(http.status_from_int(status))
		return ctx.text(body)
	}
	ctx.takeover_conn()
	ctx.conn.set_write_timeout(time.infinite)
	ctx.conn.set_read_timeout(time.infinite)
	mut conn := ctx.conn
	spawn handle_worker_websocket_dispatch_session(mut app, mut conn, key, method.to_upper(),
		normalized_path, query, headers, remote_addr, req_id, trace_id, start_ms)
	return veb.no_result()
}

fn handle_worker_websocket_session(mut app App, mut client_conn net.TcpConn, mut worker_conn unix.StreamConn, selected_socket string, key string, method string, path string, req_id string, trace_id string, start_ms i64) {
	runtime_trace('ws.session.start', {
		'request_id': req_id
		'trace_id': trace_id
		'path': path
		'worker_socket': selected_socket
	})
	app.on_worker_request_started(selected_socket)
	defer {
		runtime_trace('ws.session.defer', {
			'request_id': req_id
			'trace_id': trace_id
			'path': path
			'worker_socket': selected_socket
		})
		app.on_worker_request_finished(selected_socket)
	}
	mut ws_server := websocket.new_server(.ip, 0, '')
	mut state := &WebSocketBridgeState{
		app:           &app
		worker_conn:   worker_conn
		worker_socket: selected_socket
		conn_id:       req_id
		method:        method
		path:          path
		request_id:    req_id
		trace_id:      trace_id
		start_ms:      start_ms
	}
	ws_server.on_connect(fn [mut app, state] (mut sc websocket.ServerClient) !bool {
		runtime_trace('ws.session.connect', {
			'conn_id': state.conn_id
			'request_id': state.request_id
			'path': state.path
			'worker_socket': state.worker_socket
		})
		app.ws_hub_register_conn(state.conn_id, state.worker_socket, state.method, state.request_id,
			state.trace_id, state.path, map[string]string{}, map[string]string{}, '', sc.client)
		spawn delayed_ws_hub_flush(mut app, state.conn_id)
		return true
	}) or {}
	ws_server.on_message_ref(worker_websocket_message_cb, state)
	ws_server.on_close_ref(worker_websocket_close_cb, state)
	ws_server.handle_handshake(mut client_conn, key) or {
		runtime_trace('ws.session.handshake.error', {
			'conn_id': state.conn_id
			'request_id': state.request_id
			'path': state.path
			'error': err.msg()
		})
		app.ws_hub_unregister_conn(state.conn_id)
		state.worker_conn.close() or {}
		return
	}
	runtime_trace('ws.session.handshake.done', {
		'conn_id': state.conn_id
		'request_id': state.request_id
		'close_notified': if state.close_notified { 'true' } else { 'false' }
	})
	if !state.close_notified {
		app.ws_hub_unregister_conn(state.conn_id)
		state.worker_conn.close() or {}
		runtime_trace('ws.session.cleanup.no_close', {
			'conn_id': state.conn_id
			'request_id': state.request_id
		})
	}
}

fn handle_worker_websocket_dispatch_session(mut app App, mut client_conn net.TcpConn, key string, method string, path string, query map[string]string, headers map[string]string, remote_addr string, req_id string, trace_id string, start_ms i64) {
	mut ws_server := websocket.new_server(.ip, 0, '')
	mut state := &WebSocketDispatchBridgeState{
		app:         &app
		conn_id:     req_id
		method:      method
		path:        path
		query:       query.clone()
		headers:     headers.clone()
		remote_addr: remote_addr
		request_id:  req_id
		trace_id:    trace_id
		start_ms:    start_ms
	}
	ws_server.on_connect(fn [mut app, state] (mut sc websocket.ServerClient) !bool {
		app.ws_hub_register_conn(state.conn_id, '', state.method, state.request_id, state.trace_id,
			state.path, state.query, state.headers, state.remote_addr, sc.client)
		spawn delayed_ws_hub_flush(mut app, state.conn_id)
		return true
	}) or {}
	ws_server.on_message_ref(worker_websocket_dispatch_message_cb, state)
	ws_server.on_close_ref(worker_websocket_dispatch_close_cb, state)
	ws_server.handle_handshake(mut client_conn, key) or {
		app.ws_hub_unregister_conn(state.conn_id)
		return
	}
	app.ws_hub_unregister_conn(state.conn_id)
}

fn worker_websocket_dispatch_message_cb(mut ws websocket.Client, msg &websocket.Message, ref voidptr) ! {
	mut state := unsafe { &WebSocketDispatchBridgeState(ref) }
	if msg.opcode != .text_frame {
		ws.close(1003, 'Only text frames are supported')!
		return
	}
	room_members, member_metadata, room_counts, presence_users := state.app.ws_hub_presence_snapshot(state.conn_id)
	resp := state.app.kernel_dispatch_websocket_event(state.app.kernel_websocket_dispatch_frame(
		'message',
		state.method,
		state.path,
		state.query,
		state.headers,
		state.remote_addr,
		state.request_id,
		state.trace_id,
		'text',
		msg.payload.bytestr(),
		0,
		'',
		state.app.ws_hub_rooms_snapshot(state.conn_id),
		state.app.ws_hub_meta_snapshot(state.conn_id),
		room_members,
		member_metadata,
		room_counts,
		presence_users,
	))!
	if resp.event == 'error' {
		ws.close(1011, 'worker error')!
		return
	}
	if close_frame := state.app.execute_websocket_dispatch_commands(resp.commands) {
		code := if close_frame.code > 0 { close_frame.code } else { 1000 }
		ws.close(code, close_frame.reason)!
		return
	}
}

fn worker_websocket_dispatch_close_cb(mut ws websocket.Client, code int, reason string, ref voidptr) ! {
	mut state := unsafe { &WebSocketDispatchBridgeState(ref) }
	room_members, member_metadata, room_counts, presence_users := state.app.ws_hub_presence_snapshot(state.conn_id)
	resp := state.app.kernel_dispatch_websocket_event(state.app.kernel_websocket_dispatch_frame(
		'close',
		state.method,
		state.path,
		state.query,
		state.headers,
		state.remote_addr,
		state.request_id,
		state.trace_id,
		'',
		'',
		code,
		reason,
		state.app.ws_hub_rooms_snapshot(state.conn_id),
		state.app.ws_hub_meta_snapshot(state.conn_id),
		room_members,
		member_metadata,
		room_counts,
		presence_users,
	)) or {
		state.app.ws_hub_unregister_conn(state.conn_id)
		return
	}
	if resp.event != 'error' {
		state.app.execute_websocket_dispatch_commands(resp.commands)
	}
	state.app.ws_hub_unregister_conn(state.conn_id)
}

fn proxy_worker_response(mut app App, mut ctx Context, method string, path string, body_on_head string) veb.Result {
	start_ms := time.now().unix_milli()
	if is_websocket_upgrade(ctx.req) {
		return proxy_worker_websocket(mut app, mut ctx, method, path)
	}
	remote_addr := if isnil(ctx.conn) { '' } else { ctx.conn.peer_ip() or { '' } }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	if app.stream_dispatch {
		if result := stream_via_dispatch(mut app, mut ctx, method, path, req_id, trace_id,
			remote_addr)
		{
			return result
		}
	}
	selected_socket := app.worker_backend_select_socket_queued() or {
		err_msg := err.msg()
		status, error_class := classify_worker_error(err_msg)
		app.emit('http.request', {
			'method':      method.to_upper()
			'path':        normalize_path(path)
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
	mut conn := unix.connect_stream(selected_socket) or {
		err_msg := err.msg()
		status, error_class := classify_worker_error(err_msg)
		app.emit('http.request', {
			'method':      method.to_upper()
			'path':        normalize_path(path)
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
	app.on_worker_request_started(selected_socket)
	defer {
		app.on_worker_request_finished(selected_socket)
	}
	defer {
		conn.close() or {}
	}
	if app.worker_backend.read_timeout_ms > 0 {
		conn.set_read_timeout(time.millisecond * app.worker_backend.read_timeout_ms)
	}
	payload := encode_worker_request(method, path, ctx.req, remote_addr, trace_id, req_id)
	write_frame(mut conn, payload) or {
		err_msg := err.msg()
		status, error_class := classify_worker_error(err_msg)
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.set_custom_header('x-vhttpd-error-class', error_class) or {}
		ctx.res.set_status(http.status_from_int(status))
		return ctx.text(body_on_head)
	}
	first_raw := read_frame(mut conn) or {
		err_msg := err.msg()
		status, error_class := classify_worker_error(err_msg)
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.set_custom_header('x-vhttpd-error-class', error_class) or {}
		ctx.res.set_status(http.status_from_int(status))
		return ctx.text(body_on_head)
	}
	if start := try_decode_stream_start(first_raw) {
		if (start.stream_type == 'sse' || start.content_type.starts_with('text/event-stream'))
			&& method.to_upper() != 'HEAD' {
			return stream_via_sse(mut app, mut ctx, mut conn, start, method, path, req_id,
				trace_id, start_ms)
		}
		return stream_via_passthrough(mut app, mut ctx, mut conn, start, method, path,
			req_id, trace_id, start_ms)
	}
	if plan := try_decode_upstream_plan(first_raw) {
		conn.close() or {}
		return execute_upstream_plan(mut app, mut ctx, plan, method, path, req_id, trace_id,
			start_ms)
	}
	resp := json.decode(WorkerResponse, first_raw) or {
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.set_custom_header('x-vhttpd-error-class', 'transport_error') or {}
		ctx.res.set_status(http.status_from_int(502))
		return ctx.text(body_on_head)
	}
	app.emit('http.request', {
		'method':      method.to_upper()
		'path':        normalize_path(path)
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

fn normalize_request_target(raw_path string) (string, string) {
	path := normalize_path(raw_path)
	if !path.contains('?') {
		return path, ''
	}
	base := normalize_path(path.all_before('?'))
	query := path.all_after('?')
	return base, query
}

fn parse_query_map(query_str string) map[string]string {
	mut out := map[string]string{}
	if query_str == '' {
		return out
	}
	values := urllib.parse_query(query_str) or { return out }
	for key, entries in values.to_map() {
		if entries.len == 0 {
			out[key] = ''
			continue
		}
		out[key] = entries[0]
	}
	return out
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
	if kind in ['server.started', 'server.failed', 'server.stopped', 'admin.started', 'admin.failed', 'internal_admin.started', 'internal_admin.error', 'worker.select.failed'] {
		runtime_trace('emit.${kind}', fields)
	}
	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	if kind == 'http.request' {
		app.stat_http_requests_total++
		status := (fields['status'] or { '0' }).int()
		if status >= 400 {
			app.stat_http_errors_total++
		}
		error_class := fields['error_class'] or { '' }
		if error_class == 'timeout' {
			app.stat_http_timeouts_total++
		}
		if (fields['response_mode'] or { '' }) == 'stream' {
			app.stat_http_streams_total++
		}
	}
	if kind.starts_with('admin.') {
		app.stat_admin_actions_total++
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

// Provider registry helpers on App. Registry is protected by app.mu.
pub fn (mut app App) register_provider(name string, p Provider) {
	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	if app.providers.registry.len == 0 {
		app.providers.registry = map[string]Provider{}
	}
	if app.providers.specs.len == 0 {
		app.providers.specs = map[string]ProviderSpec{}
	}
	app.providers.registry[name] = p
	app.providers.specs[name] = ProviderSpec{
		name:             name
		enabled:          true
		has_handler:      false
		has_runtime:      true
		command_matchers: []CommandMatcher{}
		route_kind:       .generic
		provider:         p
		handler:          NoopProviderCommandHandler{}
		runtime: ProviderRuntimeAdapter{
			provider: p
		}
	}
}

pub fn (mut app App) register_provider_spec(spec ProviderSpec) {
	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	if app.providers.specs.len == 0 {
		app.providers.specs = map[string]ProviderSpec{}
	}
	app.providers.specs[spec.name] = spec
}

pub fn (mut app App) get_provider_spec(name string) ?ProviderSpec {
	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	return app.providers.specs[name] or { return none }
}

pub fn (mut app App) get_provider(name string) ?Provider {
	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	if spec := app.providers.specs[name] {
		return spec.provider
	}
	return app.providers.registry[name] or { return none }
}

pub fn (mut app App) provider_enabled(name string) bool {
	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	if spec := app.providers.specs[name] {
		return spec.enabled
	}
	return app.provider_bootstrap_enabled(name)
}

pub fn (mut app App) get_provider_runtime(name string) ?ProviderRuntime {
	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	if spec := app.providers.specs[name] {
		return spec.runtime
	}
	return none
}

pub fn (mut app App) provider_runtime_snapshot(name string) ?string {
	runtime := app.get_provider_runtime(name) or { return none }
	return runtime.snapshot(mut app)
}

pub fn (mut app App) provider_runtime_feishu_snapshot() FeishuRuntimeSnapshot {
	return app.feishu_runtime_snapshot()
}

pub fn (mut app App) provider_runtime_feishu_app_snapshot(instance string) ?FeishuRuntimeAppSnapshot {
	return app.feishu_runtime_app_snapshot(instance)
}

pub fn (mut app App) provider_runtime_upstream_snapshot(name string, instance string) ?WebSocketUpstreamSnapshot {
	return match name {
		'feishu' {
			snapshot := app.provider_runtime_feishu_app_snapshot(instance) or { return none }
			WebSocketUpstreamSnapshot{
				provider:                'feishu'
				instance:                snapshot.name
				enabled:                 snapshot.enabled
				configured:              snapshot.configured
				connected:               snapshot.connected
				url:                     snapshot.ws_url
				last_connect_at_unix:    snapshot.last_connect_at_unix
				last_disconnect_at_unix: snapshot.last_disconnect_at_unix
				last_error:              snapshot.last_error
				connect_attempts:        snapshot.connect_attempts
				connect_successes:       snapshot.connect_successes
				received_frames:         snapshot.received_frames
			}
		}
		'codex' {
			if instance != '' && instance != 'main' {
				return none
			}
			state := app.codex_runtime_state_view()
			return WebSocketUpstreamSnapshot{
				provider:                'codex'
				instance:                'main'
				enabled:                 app.provider_enabled('codex')
				configured:              app.provider_enabled('codex')
				connected:               state.connected
				url:                     state.ws_url
				last_connect_at_unix:    state.last_connect_at
				last_disconnect_at_unix: state.last_disconnect_at
				last_error:              state.last_error
				connect_attempts:        state.connect_attempts
				connect_successes:       state.connect_successes
				received_frames:         state.received_frames
			}
		}
		else { none }
	}
}

pub fn (mut app App) provider_runtime_upstream_snapshots(name string) []WebSocketUpstreamSnapshot {
	mut snapshots := []WebSocketUpstreamSnapshot{}
	for instance in app.provider_runtime_instances(name) {
		if snapshot := app.provider_runtime_upstream_snapshot(name, instance) {
			snapshots << snapshot
		}
	}
	return snapshots
}

pub fn (mut app App) provider_runtime_upstream_events(name string, instance_filter string) []WebSocketUpstreamEventSnapshot {
	return match name {
		'feishu' {
			mut events := []WebSocketUpstreamEventSnapshot{}
			for app_snapshot in app.provider_runtime_feishu_snapshot().apps {
				if instance_filter != '' && app_snapshot.name != instance_filter {
					continue
				}
				for event in app_snapshot.recent_events {
					events << WebSocketUpstreamEventSnapshot{
						provider:    'feishu'
						instance:    app_snapshot.name
						event_type:  event.event_type
						message_id:  event.message_id
						target:      event.chat_id
						target_type: 'chat_id'
						trace_id:    event.trace_id
						received_at: event.received_at
						payload:     event.payload
						metadata: {
							'action':            event.action
							'event_id':          event.event_id
							'event_kind':        event.event_kind
							'chat_type':         event.chat_type
							'message_type':      event.message_type
							'open_message_id':   event.open_message_id
							'root_id':           event.root_id
							'parent_id':         event.parent_id
							'create_time':       event.create_time
							'sender_id':         event.sender_id
							'sender_id_type':    event.sender_id_type
							'sender_tenant_key': event.sender_tenant_key
							'action_tag':        event.action_tag
							'action_value':      event.action_value
							'token':             event.token
						}
					}
				}
			}
			events
		}
		'codex' { []WebSocketUpstreamEventSnapshot{} }
		else { []WebSocketUpstreamEventSnapshot{} }
	}
}

pub struct ProviderRuntimeMetrics {
pub:
	connect_attempts  i64
	connect_successes i64
	received_frames   i64
	acked_events      i64
	messages_sent     i64
	send_errors       i64
}

pub struct ProviderRuntimeUpstreamLaunch {
pub:
	provider string
	instance string
	label    string
	url      string
}

pub fn (mut app App) provider_runtime_metrics(name string) ProviderRuntimeMetrics {
	return match name {
		'feishu' {
			connect_attempts, connect_successes, received_frames, acked_events, messages_sent, send_errors := app.feishu_runtime_totals()
			ProviderRuntimeMetrics{
				connect_attempts:  connect_attempts
				connect_successes: connect_successes
				received_frames:   received_frames
				acked_events:      acked_events
				messages_sent:     messages_sent
				send_errors:       send_errors
			}
		}
		'codex' {
			state := app.codex_runtime_state_view()
			ProviderRuntimeMetrics{
				connect_attempts:  state.connect_attempts
				connect_successes: state.connect_successes
				received_frames:   state.received_frames
			}
		}
		else { ProviderRuntimeMetrics{} }
	}
}

pub fn (mut app App) provider_runtime_capabilities() map[string]bool {
	feishu_ready := app.provider_runtime_ready('feishu')
	return {
		'feishu_runtime': feishu_ready
		'feishu_gateway': feishu_ready
	}
}

pub fn (mut app App) provider_runtime_gateway_count() int {
	mut total := 0
	for provider in ['feishu', 'codex'] {
		total += app.provider_runtime_upstream_snapshots(provider).len
	}
	return total
}

pub fn (mut app App) provider_runtime_upstream_launches() []ProviderRuntimeUpstreamLaunch {
	mut launches := []ProviderRuntimeUpstreamLaunch{}
	feishu_instances := app.provider_runtime_instances('feishu')
	if feishu_instances.len > 0 {
		launches << ProviderRuntimeUpstreamLaunch{
			provider: 'feishu'
			instance: ''
			label:    feishu_instances.join(', ')
		}
		for instance in feishu_instances {
			launches << ProviderRuntimeUpstreamLaunch{
				provider: 'feishu'
				instance: instance
				label:    instance
			}
		}
	}
	codex_instances := app.provider_runtime_instances('codex')
	for instance in codex_instances {
		launches << ProviderRuntimeUpstreamLaunch{
			provider: 'codex'
			instance: instance
			label:    instance
			url:      app.provider_runtime_pull_url('codex', instance) or { '' }
		}
	}
	return launches
}

pub fn (mut app App) provider_runtime_upstream_enabled(name string, instance string) bool {
	return match name {
		'feishu' { app.provider_runtime_ready('feishu') && instance in app.provider_runtime_instances('feishu') }
		'codex' { app.provider_runtime_ready('codex') && instance in app.provider_runtime_instances('codex') }
		'ollama' { app.provider_runtime_ready('ollama') && instance in app.provider_runtime_instances('ollama') }
		else { false }
	}
}

pub fn (mut app App) provider_runtime_upstream_provider_names() []string {
	mut names := []string{}
	for name in ['feishu', 'codex'] {
		if app.provider_runtime_instances(name).len > 0 {
			names << name
		}
	}
	return names
}

pub fn (app &App) provider_bootstrap_enabled(name string) bool {
	return match name {
		'feishu' { app.feishu_enabled }
		'codex' { app.codex_runtime.enabled }
		'ollama' { app.ollama_enabled }
		else { false }
	}
}

pub fn (mut app App) provider_runtime_ready(name string) bool {
	return match name {
		'feishu' { app.feishu_runtime_ready() }
		'codex' { app.provider_enabled('codex') }
		'ollama' { app.provider_enabled('ollama') }
		else { false }
	}
}

pub fn (mut app App) provider_runtime_default_instance(name string) string {
	return match name {
		'feishu' { app.feishu_runtime_default_app_name() }
		'codex' { 'main' }
		'ollama' { 'main' }
		else { '' }
	}
}

pub fn (mut app App) provider_runtime_instances(name string) []string {
	return match name {
		'feishu' { app.feishu_runtime_app_names() }
		'codex' {
			if app.provider_runtime_ready('codex') {
				['main']
			} else {
				[]string{}
			}
		}
		'ollama' {
			if app.provider_runtime_ready('ollama') {
				['main']
			} else {
				[]string{}
			}
		}
		else { []string{} }
	}
}

pub fn (mut app App) provider_runtime_pull_url(name string, instance string) !string {
	return match name {
		'feishu' { app.feishu_provider_pull_ws_endpoint(instance) }
		'codex' { app.codex_provider_pull_url() }
		else { error('unknown provider ${name}') }
	}
}

pub fn (mut app App) provider_runtime_reconnect_delay_ms(name string, instance string) int {
	_ = instance
	return match name {
		'feishu' {
			if app.feishu_reconnect_delay_ms > 0 {
				app.feishu_reconnect_delay_ms
			} else {
				3000
			}
		}
		'codex' { app.codex_provider_reconnect_delay_ms() }
		else { 3000 }
	}
}

pub fn (mut app App) provider_runtime_on_connecting(name string, instance string) {
	match name {
		'feishu' {
			app.feishu_runtime_note_connecting(instance)
		}
		'codex' {
			app.codex_provider_on_connecting()
		}
		else {}
	}
}

pub fn (mut app App) provider_runtime_on_connected(name string, instance string, ws_url string) {
	match name {
		'feishu' {
			app.feishu_runtime_note_connected(instance, ws_url)
		}
		'codex' {
			app.codex_provider_on_connected(ws_url)
		}
		else {}
	}
}

pub fn (mut app App) provider_runtime_on_disconnected(name string, instance string, reason string) {
	match name {
		'feishu' {
			app.feishu_runtime_note_disconnected(instance, reason)
		}
		'codex' {
			app.codex_provider_on_disconnected(reason)
		}
		else {}
	}
}

pub fn (mut app App) provider_names() []string {
	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	mut keys := app.providers.specs.keys()
	keys.sort()
	return keys
}

// Helpers to run provider lifecycle across registered providers.
pub fn (mut app App) stop_all_providers() {
	mut runtimes := []ProviderRuntime{}
	app.mu.@lock()
	for _, spec in app.providers.specs {
		runtimes << spec.runtime
	}
	app.mu.unlock()
	for runtime in runtimes {
		runtime.stop(mut app) or {
			app.emit('provider.stop_failed', {
				'error': err.msg()
			})
		}
	}
}

@[get]
pub fn (mut app App) health(mut ctx Context) veb.Result {
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
	if app.worker_backend.sockets.len > 0 {
		return proxy_worker_response(mut app, mut ctx, method, path, 'Bad Gateway')
	}
	mut status := 200
	mut body := ''
	mut ctype := 'text/plain; charset=utf-8'
	status, body, ctype = dispatch_core(method, path)
	app.emit('http.request', {
		'method':      method.to_upper()
		'path':        normalize_path(path)
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
	if app.worker_backend.sockets.len > 0 {
		return proxy_worker_response(mut app, mut ctx, method, path, '')
	}
	mut status := 200
	mut body := ''
	mut ctype := 'text/plain; charset=utf-8'
	status, body, ctype = dispatch_core(method, path)
	app.emit('http.request', {
		'method':      method.to_upper()
		'path':        normalize_path(path)
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
	target := if ctx.req.url == '' { path } else { ctx.req.url }
	if normalize_path(target) == '/mcp' {
		return app.mcp_get(mut ctx)
	}
	if app.worker_backend.sockets.len == 0 {
		ctx.res.set_status(.not_found)
		return ctx.text('Not Found')
	}
	return proxy_worker_response(mut app, mut ctx, 'GET', target, '')
}

@['/:path...'; post]
pub fn (mut app App) proxy_post(mut ctx Context, path string) veb.Result {
	target := if ctx.req.url == '' { path } else { ctx.req.url }
	if normalize_path(target) == '/mcp' {
		return app.mcp_post(mut ctx)
	}
	if app.worker_backend.sockets.len == 0 {
		ctx.res.set_status(.not_found)
		return ctx.text('Not Found')
	}
	return proxy_worker_response(mut app, mut ctx, 'POST', target, '')
}

@['/:path...'; put]
pub fn (mut app App) proxy_put(mut ctx Context, path string) veb.Result {
	if app.worker_backend.sockets.len == 0 {
		ctx.res.set_status(.not_found)
		return ctx.text('Not Found')
	}
	target := if ctx.req.url == '' { path } else { ctx.req.url }
	return proxy_worker_response(mut app, mut ctx, 'PUT', target, '')
}

@['/:path...'; patch]
pub fn (mut app App) proxy_patch(mut ctx Context, path string) veb.Result {
	if app.worker_backend.sockets.len == 0 {
		ctx.res.set_status(.not_found)
		return ctx.text('Not Found')
	}
	target := if ctx.req.url == '' { path } else { ctx.req.url }
	return proxy_worker_response(mut app, mut ctx, 'PATCH', target, '')
}

@['/:path...'; delete]
pub fn (mut app App) proxy_delete(mut ctx Context, path string) veb.Result {
	target := if ctx.req.url == '' { path } else { ctx.req.url }
	if normalize_path(target) == '/mcp' {
		return app.mcp_delete(mut ctx)
	}
	if app.worker_backend.sockets.len == 0 {
		ctx.res.set_status(.not_found)
		return ctx.text('Not Found')
	}
	return proxy_worker_response(mut app, mut ctx, 'DELETE', target, '')
}

@['/:path...'; head]
pub fn (mut app App) proxy_head(mut ctx Context, path string) veb.Result {
	if app.worker_backend.sockets.len == 0 {
		ctx.res.set_status(.not_found)
		return ctx.text('')
	}
	target := if ctx.req.url == '' { path } else { ctx.req.url }
	return proxy_worker_response(mut app, mut ctx, 'HEAD', target, '')
}
