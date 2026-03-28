module main

import net
import net.http
import time
import veb

struct McpSession {
mut:
	id                       string
	protocol_version         string
	request_id               string
	trace_id                 string
	path                     string
	started_at_unix          i64
	last_activity_unix       i64
	client_capabilities_json string
	conn                     &net.TcpConn = unsafe { nil }
	pending                  []string
}

struct AdminMcpSessionSnapshot {
	id                       string
	protocol_version         string
	request_id               string
	trace_id                 string
	path                     string
	started_at_unix          i64
	last_activity_unix       i64
	pending_count            int
	connected                bool
	client_capabilities_json string
}

struct AdminMcpRuntimeSnapshot {
	active_sessions            int
	returned_sessions          int
	details                    bool
	limit                      int
	offset                     int
	session_id                 string
	protocol_version           string
	max_sessions               int
	max_pending_messages       int
	session_ttl_seconds        int
	allowed_origins            []string
	sampling_capability_policy string
	sessions                   []AdminMcpSessionSnapshot
}

struct McpQueueResult {
	queued      bool
	error       bool
	error_class string
}

fn generate_mcp_session_id() string {
	return 'mcp_${time.now().unix_micro()}'
}

fn default_mcp_protocol_version() string {
	return '2025-11-05'
}

fn normalize_mcp_sampling_capability_policy(raw string) string {
	policy := raw.trim_space().to_lower()
	return match policy {
		'drop', 'error' { policy }
		else { 'warn' }
	}
}

fn (mut app App) mcp_prune_sessions_locked(now i64) {
	if app.mcp_sessions.len == 0 {
		return
	}
	ttl := if app.mcp_session_ttl_seconds > 0 { i64(app.mcp_session_ttl_seconds) } else { i64(900) }
	mut expired := []string{}
	for id, session in app.mcp_sessions {
		last_seen := if session.last_activity_unix > 0 { session.last_activity_unix } else { session.started_at_unix }
		if now - last_seen > ttl {
			expired << id
		}
	}
	for id in expired {
		app.mcp_sessions.delete(id)
	}
	if expired.len > 0 {
		app.mu.@lock()
		app.stat_mcp_sessions_expired_total += expired.len
		app.mu.unlock()
	}
}

fn (mut app App) mcp_evict_one_locked() {
	if app.mcp_sessions.len == 0 {
		return
	}
	mut candidate_id := ''
	mut candidate_last := i64(0)
	for id, session in app.mcp_sessions {
		last_seen := if session.last_activity_unix > 0 { session.last_activity_unix } else { session.started_at_unix }
		if candidate_id == '' || last_seen < candidate_last {
			candidate_id = id
			candidate_last = last_seen
		}
	}
	if candidate_id != '' {
		app.mcp_sessions.delete(candidate_id)
		app.mu.@lock()
		app.stat_mcp_sessions_evicted_total++
		app.mu.unlock()
	}
}

fn (mut app App) mcp_ensure_session(session_id string, protocol_version string, req_id string, trace_id string, path string) McpSession {
	app.mcp_mu.@lock()
	defer {
		app.mcp_mu.unlock()
	}
	now := time.now().unix()
	app.mcp_prune_sessions_locked(now)
	if existing := app.mcp_sessions[session_id] {
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
		app.mcp_sessions[session_id] = updated
		return updated
	}
	max_sessions := if app.mcp_max_sessions > 0 { app.mcp_max_sessions } else { 1000 }
	for app.mcp_sessions.len >= max_sessions {
		app.mcp_evict_one_locked()
	}
	session := McpSession{
		id: session_id
		protocol_version: protocol_version
		request_id: req_id
		trace_id: trace_id
		path: path
		started_at_unix: now
		last_activity_unix: now
		client_capabilities_json: ''
		conn: unsafe { nil }
		pending: []string{}
	}
	app.mcp_sessions[session_id] = session
	return session
}

fn (mut app App) mcp_session_set_client_capabilities(session_id string, raw string) bool {
	if session_id == '' || raw == '' {
		return false
	}
	app.mcp_mu.@lock()
	defer {
		app.mcp_mu.unlock()
	}
	if mut session := app.mcp_sessions[session_id] {
		session.client_capabilities_json = raw
		session.last_activity_unix = time.now().unix()
		app.mcp_sessions[session_id] = session
		return true
	}
	return false
}

fn (mut app App) mcp_session_bind_conn(session_id string, conn &net.TcpConn) bool {
	if session_id == '' || isnil(conn) {
		return false
	}
	app.mcp_mu.@lock()
	defer {
		app.mcp_mu.unlock()
	}
	if mut session := app.mcp_sessions[session_id] {
		session.conn = unsafe { conn }
		session.last_activity_unix = time.now().unix()
		app.mcp_sessions[session_id] = session
		return true
	}
	return false
}

fn (mut app App) mcp_session_unbind_conn(session_id string, conn &net.TcpConn) {
	if session_id == '' {
		return
	}
	app.mcp_mu.@lock()
	defer {
		app.mcp_mu.unlock()
	}
	if mut session := app.mcp_sessions[session_id] {
		if isnil(conn) || session.conn == unsafe { conn } {
			session.conn = unsafe { nil }
			session.last_activity_unix = time.now().unix()
			app.mcp_sessions[session_id] = session
		}
	}
}

fn (mut app App) mcp_session_queue(session_id string, raw string) McpQueueResult {
	if session_id == '' || raw == '' {
		return McpQueueResult{
			queued: false
		}
	}
	mut warn_sampling_capability := false
	mut drop_sampling_capability := false
	mut error_sampling_capability := false
	mut session_trace_id := ''
	mut session_request_id := ''
	policy := normalize_mcp_sampling_capability_policy(app.mcp_sampling_capability_policy)
	app.mcp_mu.@lock()
	if mut session := app.mcp_sessions[session_id] {
		session.last_activity_unix = time.now().unix()
		session_trace_id = session.trace_id
		session_request_id = session.request_id
		if raw.contains('"method":"sampling/createMessage"')
			|| raw.contains('"method": "sampling/createMessage"')
			|| raw.contains('"method":"sampling\\/createMessage"')
			|| raw.contains('"method": "sampling\\/createMessage"') {
			if !session.client_capabilities_json.contains('"sampling"') {
				match policy {
					'drop' { drop_sampling_capability = true }
					'error' { error_sampling_capability = true }
					else { warn_sampling_capability = true }
				}
			}
		}
		if !drop_sampling_capability && !error_sampling_capability {
			session.pending << raw
			max_pending := if app.mcp_max_pending_messages > 0 { app.mcp_max_pending_messages } else { 128 }
			if session.pending.len > max_pending {
				drop_count := session.pending.len - max_pending
				session.pending = session.pending[drop_count..].clone()
				app.mu.@lock()
				app.stat_mcp_pending_dropped_total += drop_count
				app.mu.unlock()
			}
		}
		app.mcp_sessions[session_id] = session
	}
	app.mcp_mu.unlock()
	if warn_sampling_capability {
		app.mu.@lock()
		app.stat_mcp_sampling_capability_warnings_total++
		app.mu.unlock()
		app.emit('mcp.capability.warning', {
			'session_id': session_id
			'request_id': session_request_id
			'trace_id': session_trace_id
			'warning_class': 'sampling_without_client_capability'
		})
	}
	if drop_sampling_capability {
		app.mu.@lock()
		app.stat_mcp_sampling_capability_dropped_total++
		app.mu.unlock()
		app.emit('mcp.capability.drop', {
			'session_id': session_id
			'request_id': session_request_id
			'trace_id': session_trace_id
			'policy': policy
			'drop_class': 'sampling_without_client_capability'
		})
		return McpQueueResult{
			queued: false
		}
	}
	if error_sampling_capability {
		app.mu.@lock()
		app.stat_mcp_sampling_capability_errors_total++
		app.mu.unlock()
		app.emit('mcp.capability.error', {
			'session_id': session_id
			'request_id': session_request_id
			'trace_id': session_trace_id
			'policy': policy
			'error_class': 'sampling_without_client_capability'
		})
		return McpQueueResult{
			queued: false
			error: true
			error_class: 'sampling_capability_required'
		}
	}
	return McpQueueResult{
		queued: true
	}
}

fn (mut app App) mcp_session_flush(session_id string) bool {
	if session_id == '' {
		return false
	}
	mut client := &net.TcpConn(unsafe { nil })
	mut pending := []string{}
	app.mcp_mu.@lock()
	if session := app.mcp_sessions[session_id] {
		client = session.conn
		pending = session.pending.clone()
		if mut writable := app.mcp_sessions[session_id] {
			writable.pending = []string{}
			writable.last_activity_unix = time.now().unix()
			app.mcp_sessions[session_id] = writable
		}
	}
	app.mcp_mu.unlock()
	if isnil(client) {
		return false
	}
	for raw in pending {
		if !write_mcp_sse_json(mut client, raw) {
			return false
		}
	}
	return true
}

fn (mut app App) admin_mcp_snapshot(details bool, limit int, offset int, session_filter string, protocol_filter string) AdminMcpRuntimeSnapshot {
	app.mcp_mu.@lock()
	app.mcp_prune_sessions_locked(time.now().unix())
	mut sessions := []AdminMcpSessionSnapshot{}
	for _, session in app.mcp_sessions {
		if session_filter != '' && session.id != session_filter {
			continue
		}
		if protocol_filter != '' && session.protocol_version != protocol_filter {
			continue
		}
		sessions << AdminMcpSessionSnapshot{
			id: session.id
			protocol_version: session.protocol_version
			request_id: session.request_id
			trace_id: session.trace_id
			path: session.path
			started_at_unix: session.started_at_unix
			last_activity_unix: session.last_activity_unix
			pending_count: session.pending.len
			connected: !isnil(session.conn)
			client_capabilities_json: session.client_capabilities_json
		}
	}
	app.mcp_mu.unlock()
	sessions.sort(a.started_at_unix < b.started_at_unix)
	total := sessions.len
	if !details {
		return AdminMcpRuntimeSnapshot{
			active_sessions: total
			returned_sessions: 0
			details: false
			limit: limit
			offset: offset
			session_id: session_filter
			protocol_version: protocol_filter
			max_sessions: if app.mcp_max_sessions > 0 { app.mcp_max_sessions } else { 1000 }
			max_pending_messages: if app.mcp_max_pending_messages > 0 { app.mcp_max_pending_messages } else { 128 }
			session_ttl_seconds: if app.mcp_session_ttl_seconds > 0 { app.mcp_session_ttl_seconds } else { 900 }
			allowed_origins: app.mcp_allowed_origins.clone()
			sampling_capability_policy: normalize_mcp_sampling_capability_policy(app.mcp_sampling_capability_policy)
			sessions: []AdminMcpSessionSnapshot{}
		}
	}
	start := if offset < total { offset } else { total }
	end := if start + limit < total { start + limit } else { total }
	return AdminMcpRuntimeSnapshot{
		active_sessions: total
		returned_sessions: end - start
		details: true
		limit: limit
		offset: offset
		session_id: session_filter
		protocol_version: protocol_filter
		max_sessions: if app.mcp_max_sessions > 0 { app.mcp_max_sessions } else { 1000 }
		max_pending_messages: if app.mcp_max_pending_messages > 0 { app.mcp_max_pending_messages } else { 128 }
		session_ttl_seconds: if app.mcp_session_ttl_seconds > 0 { app.mcp_session_ttl_seconds } else { 900 }
		allowed_origins: app.mcp_allowed_origins.clone()
		sampling_capability_policy: normalize_mcp_sampling_capability_policy(app.mcp_sampling_capability_policy)
		sessions: sessions[start..end].clone()
	}
}

fn write_mcp_sse_json(mut conn net.TcpConn, raw string) bool {
	conn.write_string('event: message\ndata: ${raw}\n\n') or { return false }
	return true
}

fn (app &App) mcp_origin_allowed(headers map[string]string) bool {
	if app.mcp_allowed_origins.len == 0 {
		return true
	}
	origin := (headers['origin'] or { '' }).trim_space()
	if origin == '' {
		return false
	}
	for allowed in app.mcp_allowed_origins {
		if origin == allowed {
			return true
		}
	}
	return false
}

fn (mut app App) mcp_delete_session(session_id string) bool {
	if session_id == '' {
		return false
	}
	mut client := &net.TcpConn(unsafe { nil })
	app.mcp_mu.@lock()
	if session := app.mcp_sessions[session_id] {
		client = session.conn
		app.mcp_sessions.delete(session_id)
	}
	app.mcp_mu.unlock()
	if !isnil(client) {
		client.close() or {}
	}
	return true
}

fn extract_mcp_client_capabilities_json(raw string) string {
	field_marker := '"capabilities"'
	mut idx := raw.index(field_marker) or { return '' }
	idx += field_marker.len
	for idx < raw.len && (raw[idx] == `:` || raw[idx] == ` ` || raw[idx] == `\n` || raw[idx] == `\r`
		|| raw[idx] == `\t`) {
		idx++
	}
	if idx >= raw.len || raw[idx] != `{` {
		return ''
	}
	start := idx
	mut depth := 0
	mut in_string := false
	mut escaped := false
	for i := idx; i < raw.len; i++ {
		ch := raw[i]
		if escaped {
			escaped = false
			continue
		}
		if ch == `\\` {
			if in_string {
				escaped = true
			}
			continue
		}
		if ch == `"` {
			in_string = !in_string
			continue
		}
		if in_string {
			continue
		}
		if ch == `{` {
			depth++
			continue
		}
		if ch == `}` {
			depth--
			if depth == 0 {
				return raw[start..i + 1]
			}
		}
	}
	return ''
}

fn (app &App) mcp_client_capabilities_for_request(session_id string, raw string) string {
	body_caps := extract_mcp_client_capabilities_json(raw)
	if body_caps != '' {
		return body_caps
	}
	if session_id != '' {
		if session := app.mcp_sessions[session_id] {
			return session.client_capabilities_json
		}
	}
	return ''
}

fn proxy_worker_mcp(mut app App, mut ctx Context) veb.Result {
	start_ms := time.now().unix_milli()
	path := if ctx.req.url == '' { '/mcp' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	headers := header_map_from_request(ctx.req)
	method := ctx.req.method.str().to_upper()
	if method != 'POST' {
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.res.set_status(http.status_from_int(405))
		ctx.set_content_type('application/json; charset=utf-8')
		app.emit('http.request', {
			'method': method
			'path': '/mcp'
			'status': '405'
			'request_id': req_id
			'trace_id': trace_id
			'response_mode': 'mcp'
		})
		return ctx.text('{"error":"Method Not Allowed"}')
	}
	if app.worker_backend.sockets.len == 0 {
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.res.set_status(http.status_from_int(501))
		ctx.set_content_type('application/json; charset=utf-8')
		app.emit('http.request', {
			'method': method
			'path': '/mcp'
			'status': '501'
			'request_id': req_id
			'trace_id': trace_id
			'response_mode': 'mcp'
			'error_class': 'worker_unavailable'
		})
		return ctx.text('{"error":"MCP requires a configured logic executor"}')
	}
	if !app.mcp_origin_allowed(headers) {
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.res.set_status(http.status_from_int(403))
		ctx.set_content_type('application/json; charset=utf-8')
		app.emit('http.request', {
			'method': method
			'path': '/mcp'
			'status': '403'
			'request_id': req_id
			'trace_id': trace_id
			'response_mode': 'mcp'
			'error_class': 'origin_forbidden'
		})
		return ctx.text('{"error":"Forbidden Origin"}')
	}
	mut protocol_version := headers['mcp-protocol-version'] or { '' }
	if protocol_version == '' {
		protocol_version = default_mcp_protocol_version()
	}
	body := ctx.req.data
	if body.trim_space() == '' {
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.res.set_status(http.status_from_int(400))
		ctx.set_content_type('application/json; charset=utf-8')
		app.emit('http.request', {
			'method': method
			'path': '/mcp'
			'status': '400'
			'request_id': req_id
			'trace_id': trace_id
			'response_mode': 'mcp'
			'error_class': 'empty_body'
		})
		return ctx.text('{"error":"Empty JSON-RPC body"}')
	}
	request := app.kernel_mcp_dispatch_request(
		method,
		normalize_path(path),
		headers,
		protocol_version,
		body,
		ctx.ip(),
		req_id,
		trace_id,
		headers['mcp-session-id'] or { '' },
		app.mcp_client_capabilities_for_request(headers['mcp-session-id'] or { '' }, body),
	)
	outcome := app.kernel_dispatch_mcp_handled(request) or {
		err_msg := err.msg()
		failure := kernel_dispatch_transport_failure(err_msg)
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.set_custom_header('x-vhttpd-error-class', failure.error_class) or {}
		ctx.res.set_status(http.status_from_int(failure.status))
		ctx.set_content_type('application/json; charset=utf-8')
		app.emit('http.request', {
			'method': method
			'path': '/mcp'
			'status': '${failure.status}'
			'request_id': req_id
			'trace_id': trace_id
			'response_mode': 'mcp'
			'error_class': failure.error_class
			'error_detail': err_msg
		})
		app.emit('mcp.dispatch.failed', {
			'request_id': req_id
			'trace_id': trace_id
			'error_class': failure.error_class
			'error_detail': err_msg
		})
		return ctx.text('{"error":"Bad Gateway"}')
	}
	mut response := outcome.response
	mut session_id := response.session_id
	if session_id == '' {
		raw_session_id := headers['mcp-session-id'] or { '' }
		if raw_session_id != '' {
			session_id = raw_session_id
		}
	}
	if session_id == '' {
		if body.contains('"method":"initialize"') || body.contains('"method": "initialize"') {
			session_id = generate_mcp_session_id()
		}
	}
	if session_id != '' {
		session := app.mcp_ensure_session(session_id, if response.protocol_version != '' { response.protocol_version } else { protocol_version }, req_id, trace_id, '/mcp')
		session_id = session.id
		if body.contains('"method":"initialize"') || body.contains('"method": "initialize"') {
			client_capabilities_json := extract_mcp_client_capabilities_json(body)
			if client_capabilities_json != '' {
				app.mcp_session_set_client_capabilities(session_id, client_capabilities_json)
			}
		}
	}
	for raw_message in response.messages {
		if session_id != '' {
			queue_result := app.mcp_session_queue(session_id, raw_message)
			if queue_result.error {
				ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
				ctx.set_custom_header('x-vhttpd-error-class', queue_result.error_class) or {}
				ctx.res.set_status(http.status_from_int(409))
				ctx.set_content_type('application/json; charset=utf-8')
				app.emit('http.request', {
					'method': method
					'path': '/mcp'
					'status': '409'
					'request_id': req_id
					'trace_id': trace_id
					'duration_ms': '${time.now().unix_milli() - start_ms}'
					'response_mode': 'mcp'
					'error_class': queue_result.error_class
				})
				return ctx.text('{"error":"Sampling capability required"}')
			}
		}
	}
	command_snapshots := outcome.command_snapshots
	command_error := outcome.command_error
	if response.commands.len > 0 {
		app.emit('mcp.commands', {
			'request_id':    req_id
			'trace_id':      trace_id
			'session_id':    session_id
			'command_count': '${response.commands.len}'
			'result_count':  '${command_snapshots.len}'
			'status':        if command_error == '' { 'ok' } else { 'error' }
		})
	}
	if response.event == 'error' {
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.set_custom_header('x-vhttpd-error-class', response.error_class) or {}
		ctx.res.set_status(http.status_from_int(500))
		ctx.set_content_type('application/json; charset=utf-8')
		app.emit('http.request', {
			'method': method
			'path': '/mcp'
			'status': '500'
			'request_id': req_id
			'trace_id': trace_id
			'duration_ms': '${time.now().unix_milli() - start_ms}'
			'response_mode': 'mcp'
			'error_class': response.error_class
		})
		return ctx.text('{"error":"Internal Server Error"}')
	}
	if !response.handled {
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.res.set_status(http.status_from_int(501))
		ctx.set_content_type('application/json; charset=utf-8')
		app.emit('http.request', {
			'method': method
			'path': '/mcp'
			'status': '501'
			'request_id': req_id
			'trace_id': trace_id
			'duration_ms': '${time.now().unix_milli() - start_ms}'
			'response_mode': 'mcp'
		})
		return ctx.text('{"error":"Not Implemented"}')
	}
	mut resp_headers := response.headers.clone()
	resp_headers['x-vhttpd-trace-id'] = trace_id
	if command_error != '' {
		resp_headers['x-vhttpd-command-error'] = command_error
	}
	if response.protocol_version != '' {
		resp_headers['mcp-protocol-version'] = response.protocol_version
	}
	if session_id != '' {
		resp_headers['mcp-session-id'] = session_id
	}
	apply_worker_headers(mut ctx, resp_headers)
	ctx.res.set_status(http.status_from_int(if response.status > 0 { response.status } else { 200 }))
	ctx.set_content_type(resp_headers['content-type'] or { 'application/json; charset=utf-8' })
	app.emit('http.request', {
		'method': method
		'path': '/mcp'
		'status': '${if response.status > 0 { response.status } else { 200 }}'
		'request_id': req_id
		'trace_id': trace_id
		'duration_ms': '${time.now().unix_milli() - start_ms}'
		'response_mode': 'mcp'
	})
	return ctx.text(response.body)
}

@['/mcp'; post]
pub fn (mut app App) mcp_post(mut ctx Context) veb.Result {
	return proxy_worker_mcp(mut app, mut ctx)
}

@['/mcp'; get]
pub fn (mut app App) mcp_get(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' { '/mcp' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	headers := header_map_from_request(ctx.req)
	if !app.mcp_origin_allowed(headers) {
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.res.set_status(http.status_from_int(403))
		ctx.set_content_type('application/json; charset=utf-8')
		app.emit('http.request', {
			'method': 'GET'
			'path': '/mcp'
			'status': '403'
			'request_id': req_id
			'trace_id': trace_id
			'response_mode': 'mcp'
			'error_class': 'origin_forbidden'
		})
		return ctx.text('{"error":"Forbidden Origin"}')
	}
	mut session_id := headers['mcp-session-id'] or { '' }
	if session_id == '' {
		session_id = (ctx.query['session_id'] or { '' }).trim_space()
	}
	if session_id == '' {
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.res.set_status(http.status_from_int(400))
		ctx.set_content_type('application/json; charset=utf-8')
		app.emit('http.request', {
			'method': 'GET'
			'path': '/mcp'
			'status': '400'
			'request_id': req_id
			'trace_id': trace_id
			'response_mode': 'mcp'
			'error_class': 'missing_session_id'
		})
		return ctx.text('{"error":"Missing Mcp-Session-Id"}')
	}
	app.mcp_mu.@lock()
	session := app.mcp_sessions[session_id] or { McpSession{} }
	app.mcp_mu.unlock()
	if session.id == '' {
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.res.set_status(http.status_from_int(404))
		ctx.set_content_type('application/json; charset=utf-8')
		app.emit('http.request', {
			'method': 'GET'
			'path': '/mcp'
			'status': '404'
			'request_id': req_id
			'trace_id': trace_id
			'response_mode': 'mcp'
			'error_class': 'unknown_session_id'
		})
		return ctx.text('{"error":"Unknown Mcp-Session-Id"}')
	}
	ctx.takeover_conn()
	ctx.conn.set_write_timeout(time.infinite)
	ctx.conn.set_read_timeout(time.infinite)
	response_headers := {
		'x-request-id': req_id
		'x-vhttpd-trace-id': trace_id
		'x-accel-buffering': 'no'
		'mcp-session-id': session_id
		'mcp-protocol-version': if session.protocol_version != '' { session.protocol_version } else { default_mcp_protocol_version() }
	}
	write_http_stream_headers(mut ctx, 200, 'text/event-stream', response_headers, false) or {
		return veb.no_result()
	}
	mut conn := ctx.conn
	spawn handle_mcp_session_stream(mut app, mut conn, session_id, req_id, trace_id)
	return veb.no_result()
}

fn handle_mcp_session_stream(mut app App, mut conn net.TcpConn, session_id string, req_id string, trace_id string) {
	app.mcp_session_bind_conn(session_id, conn)
	app.mcp_session_flush(session_id)
	conn.write_string(': connected\n\n') or {
		app.mcp_session_unbind_conn(session_id, conn)
		conn.close() or {}
		return
	}
	mut last_keepalive_ms := time.now().unix_milli()
	for {
		time.sleep(200 * time.millisecond)
		if !app.mcp_session_flush(session_id) {
			break
		}
		now_ms := time.now().unix_milli()
		if now_ms - last_keepalive_ms >= 15_000 {
			conn.write_string(': keepalive\n\n') or { break }
			last_keepalive_ms = now_ms
		}
	}
	app.mcp_session_unbind_conn(session_id, conn)
	conn.close() or {}
	app.emit('http.request', {
		'method': 'GET'
		'path': '/mcp'
		'status': '200'
		'request_id': req_id
		'trace_id': trace_id
		'response_mode': 'mcp'
	})
}

@['/mcp'; delete]
pub fn (mut app App) mcp_delete(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' { '/mcp' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	headers := header_map_from_request(ctx.req)
	if !app.mcp_origin_allowed(headers) {
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.res.set_status(http.status_from_int(403))
		ctx.set_content_type('application/json; charset=utf-8')
		app.emit('http.request', {
			'method': 'DELETE'
			'path': '/mcp'
			'status': '403'
			'request_id': req_id
			'trace_id': trace_id
			'response_mode': 'mcp'
			'error_class': 'origin_forbidden'
		})
		return ctx.text('{"error":"Forbidden Origin"}')
	}
	mut session_id := headers['mcp-session-id'] or { '' }
	if session_id == '' {
		session_id = (ctx.query['session_id'] or { '' }).trim_space()
	}
	if session_id == '' {
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.res.set_status(http.status_from_int(400))
		ctx.set_content_type('application/json; charset=utf-8')
		return ctx.text('{"error":"Missing Mcp-Session-Id"}')
	}
	deleted := app.mcp_delete_session(session_id)
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	ctx.set_content_type('application/json; charset=utf-8')
	ctx.res.set_status(http.status_from_int(if deleted { 200 } else { 404 }))
	app.emit('http.request', {
		'method': 'DELETE'
		'path': '/mcp'
		'status': if deleted { '200' } else { '404' }
		'request_id': req_id
		'trace_id': trace_id
		'response_mode': 'mcp'
	})
	if deleted {
		return ctx.text('{"deleted":true}')
	}
	return ctx.text('{"error":"Unknown Mcp-Session-Id"}')
}
