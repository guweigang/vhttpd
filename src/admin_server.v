module main

import admin
import dispatch
import feishu
import json
import log
import net.http
import time
import upstream.transport
import veb

pub struct AdminApp {
	veb.Middleware[Context]
pub:
	admin_host  string
	admin_port  int
	admin_token string
pub mut:
	shared &App = unsafe { nil }
}

struct AdminPlaneRuntime {}

struct AdminPlaneRequest {
	path     string
	req_id   string
	trace_id string
	start_ms i64
}

fn admin_plane_request(ctx Context, default_path string) AdminPlaneRequest {
	path := if ctx.req.url == '' { default_path } else { ctx.req.url }
	return AdminPlaneRequest{
		path:     path
		req_id:   resolve_request_id(ctx, path)
		trace_id: resolve_trace_id(ctx, path)
		start_ms: time.now().unix_milli()
	}
}

fn admin_plane_json_response(mut admin_app AdminApp, mut ctx Context, method string, req AdminPlaneRequest, status int, body string, metadata map[string]string) veb.Result {
	mut event_metadata := {
		'plane': 'admin'
	}
	for key, value in metadata {
		if key != '' && value != '' {
			event_metadata[key] = value
		}
	}
	return HttpResponseRuntime.delivery_outcome(mut admin_app.shared, mut ctx, http_ingress_request(method,
		req.path, req.path, '', if isnil(ctx.conn) { '' } else { ctx.conn.peer_ip() or { '' } },
		req.req_id, req.trace_id, req.start_ms), dispatch.outcome_with_metadata(dispatch.response_outcome(status, {
		'content-type': 'application/json; charset=utf-8'
	}, body), event_metadata), none)
}

fn admin_plane_text_response(mut admin_app AdminApp, mut ctx Context, method string, req AdminPlaneRequest, status int, body string, metadata map[string]string) veb.Result {
	mut event_metadata := {
		'plane': 'admin'
	}
	for key, value in metadata {
		if key != '' && value != '' {
			event_metadata[key] = value
		}
	}
	return HttpResponseRuntime.delivery_outcome(mut admin_app.shared, mut ctx, http_ingress_request(method,
		req.path, req.path, '', if isnil(ctx.conn) { '' } else { ctx.conn.peer_ip() or { '' } },
		req.req_id, req.trace_id, req.start_ms), dispatch.outcome_with_metadata(dispatch.response_outcome(status, {
		'content-type': 'text/plain; charset=utf-8'
	}, body), event_metadata), none)
}

fn admin_plane_forbidden(mut admin_app AdminApp, mut ctx Context, method string, req AdminPlaneRequest) veb.Result {
	return admin_plane_json_response(mut admin_app, mut ctx, method, req, 403, json.encode(admin.AdminErrorResponse{
		error: 'forbidden'
	}), {
		'error': 'forbidden'
	})
}

fn (app AdminApp) admin_authorized(ctx Context) bool {
	headers := transport.header_map_from_request(ctx.req)
	return admin.AdminAuth.authorized(app.admin_token, headers, ctx.query)
}

fn (app &App) api_authorized(ctx Context) bool {
	headers := transport.header_map_from_request(ctx.req)
	return admin.AdminAuth.authorized(app.control_plane.admin.token, headers, ctx.query)
}

@[get]
pub fn (mut app AdminApp) health(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/health')
	return admin_plane_text_response(mut app, mut ctx, 'GET', req, 200, 'OK', map[string]string{})
}

@['/admin/workers'; get]
pub fn (mut app AdminApp) admin_workers(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/workers')
	if !app.admin_authorized(ctx) {
		return admin_plane_text_response(mut app, mut ctx, 'GET', req, 403, 'Forbidden', {
			'error': 'forbidden'
		})
	}
	body := json.encode(app.shared.worker_admin_snapshot())
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'workers'
	})
}

@['/admin/stats'; get]
pub fn (mut app AdminApp) admin_stats(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/stats')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	body := json.encode(app.shared.admin_stats_snapshot())
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'stats'
	})
}

@['/admin/runtime'; get]
pub fn (mut app AdminApp) admin_runtime(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/runtime')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	body := json.encode(app.shared.admin_runtime_snapshot())
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'runtime'
	})
}

@['/admin/runtime/plan'; get]
pub fn (mut app AdminApp) admin_runtime_plan(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/runtime/plan')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	body := app.shared.protocols.runtime_plan_json
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'runtime_plan'
	})
}

// New: return registered provider names as a stable admin endpoint so callers
// don't need to parse /admin/runtime wrapper. This keeps API surface small
// and explicit for tooling.
@['/admin/providers'; get]
pub fn (mut app AdminApp) admin_providers(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/providers')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	// provider_names returns []string
	body := json.encode(app.shared.provider_names())
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'providers'
	})
}

@['/admin/executors'; get]
pub fn (mut app AdminApp) admin_executors(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/executors')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	body := json.encode(app.shared.admin_logic_executor_specs_snapshot())
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'executors'
	})
}

@['/admin/providers/specs'; get]
pub fn (mut app AdminApp) admin_provider_specs(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/providers/specs')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	body := json.encode(app.shared.admin_provider_specs_snapshot())
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'provider_specs'
	})
}

@['/admin/providers/runtimes'; get]
pub fn (mut app AdminApp) admin_provider_runtimes(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/providers/runtimes')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	body := json.encode(app.shared.admin_provider_runtimes_snapshot())
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'provider_runtimes'
	})
}

@['/admin/runtime/upstreams'; get]
pub fn (mut app AdminApp) admin_runtime_upstreams(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' { '/admin/runtime/upstreams' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {} // safe to ignore: client may have disconnected
	ctx.set_content_type('application/json; charset=utf-8')
	if !app.admin_authorized(ctx) {
		ctx.res.set_status(http.status_from_int(403))
		return ctx.text(json.encode(admin.AdminErrorResponse{
			error: 'forbidden'
		}))
	}
	details := admin.AdminQuery.parse_boolish(ctx.query['details'] or { 'false' })
	limit := admin.AdminQuery.limit(ctx.query['limit'] or { '' }, 100, 1000)
	offset := admin.AdminQuery.offset(ctx.query['offset'] or { '' })
	role_filter := (ctx.query['role'] or { '' }).trim_space()
	provider_filter := (ctx.query['provider'] or { '' }).trim_space()
	body := json.encode(app.shared.admin_upstreams_snapshot(details, limit, offset, role_filter,
		provider_filter))
	app.shared.emit('http.request', {
		'method':     'GET'
		'path':       '/admin/runtime/upstreams'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
		'plane':      'admin'
	})
	return ctx.text(body)
}

@['/admin/runtime/websockets'; get]
pub fn (mut app AdminApp) admin_runtime_websockets(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' { '/admin/runtime/websockets' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {} // safe to ignore: client may have disconnected
	ctx.set_content_type('application/json; charset=utf-8')
	if !app.admin_authorized(ctx) {
		ctx.res.set_status(http.status_from_int(403))
		return ctx.text(json.encode(admin.AdminErrorResponse{
			error: 'forbidden'
		}))
	}
	details := admin.AdminQuery.parse_boolish(ctx.query['details'] or { 'false' })
	limit := admin.AdminQuery.limit(ctx.query['limit'] or { '' }, 100, 1000)
	offset := admin.AdminQuery.offset(ctx.query['offset'] or { '' })
	room_filter := (ctx.query['room'] or { '' }).trim_space()
	conn_filter := (ctx.query['conn_id'] or { '' }).trim_space()
	body := json.encode(app.shared.websocket.snapshot(details, limit, offset, room_filter,
		conn_filter))
	app.shared.emit('http.request', {
		'method':     'GET'
		'path':       '/admin/runtime/websockets'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
		'plane':      'admin'
	})
	return ctx.text(body)
}

@['/admin/runtime/mcp'; get]
pub fn (mut app AdminApp) admin_runtime_mcp(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' { '/admin/runtime/mcp' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {} // safe to ignore: client may have disconnected
	ctx.set_content_type('application/json; charset=utf-8')
	if !app.admin_authorized(ctx) {
		ctx.res.set_status(http.status_from_int(403))
		return ctx.text(json.encode(admin.AdminErrorResponse{
			error: 'forbidden'
		}))
	}
	details := admin.AdminQuery.parse_boolish(ctx.query['details'] or { 'false' })
	limit := admin.AdminQuery.limit(ctx.query['limit'] or { '' }, 100, 1000)
	offset := admin.AdminQuery.offset(ctx.query['offset'] or { '' })
	session_filter := (ctx.query['session_id'] or { '' }).trim_space()
	protocol_filter := (ctx.query['protocol_version'] or { '' }).trim_space()
	body := json.encode(app.shared.protocols.mcp.snapshot(details, limit, offset, session_filter,
		protocol_filter))
	app.shared.emit('http.request', {
		'method':     'GET'
		'path':       '/admin/runtime/mcp'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
		'plane':      'admin'
	})
	return ctx.text(body)
}

@['/admin/runtime/provider-instances'; get]
pub fn (mut app AdminApp) admin_runtime_provider_instances(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' { '/admin/runtime/provider-instances' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {} // safe to ignore: client may have disconnected
	ctx.set_content_type('application/json; charset=utf-8')
	if !app.admin_authorized(ctx) {
		ctx.res.set_status(http.status_from_int(403))
		return ctx.text(json.encode(admin.AdminErrorResponse{
			error: 'forbidden'
		}))
	}
	provider_filter := (ctx.query['provider'] or { '' }).trim_space()
	body := json.encode(app.shared.admin_provider_instance_snapshots(provider_filter))
	app.shared.emit('http.request', {
		'method':     'GET'
		'path':       '/admin/runtime/provider-instances'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
		'plane':      'admin'
	})
	return ctx.text(body)
}

@['/admin/runtime/feishu'; get]
pub fn (mut app AdminApp) admin_runtime_feishu(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' { '/admin/runtime/feishu' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {} // safe to ignore: client may have disconnected
	ctx.set_content_type('application/json; charset=utf-8')
	if !app.admin_authorized(ctx) {
		ctx.res.set_status(http.status_from_int(403))
		return ctx.text(json.encode(admin.AdminErrorResponse{
			error: 'forbidden'
		}))
	}
	body := app.shared.provider_runtime_snapshot('feishu') or { '{}' }
	app.shared.emit('http.request', {
		'method':     'GET'
		'path':       '/admin/runtime/feishu'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
		'plane':      'admin'
	})
	return ctx.text(body)
}

@['/admin/runtime/db'; get]
pub fn (mut app AdminApp) admin_runtime_db(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' { '/admin/runtime/db' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {} // safe to ignore: client may have disconnected
	ctx.set_content_type('application/json; charset=utf-8')
	if !app.admin_authorized(ctx) {
		ctx.res.set_status(http.status_from_int(403))
		return ctx.text(json.encode(admin.AdminErrorResponse{
			error: 'forbidden'
		}))
	}
	body := app.shared.provider_runtime_snapshot('db') or { '{}' }
	app.shared.emit('http.request', {
		'method':     'GET'
		'path':       '/admin/runtime/db'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
		'plane':      'admin'
	})
	return ctx.text(body)
}

@['/admin/runtime/feishu/chats'; get]
pub fn (mut app AdminApp) admin_runtime_feishu_chats(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' { '/admin/runtime/feishu/chats' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {} // safe to ignore: client may have disconnected
	ctx.set_content_type('application/json; charset=utf-8')
	if !app.admin_authorized(ctx) {
		ctx.res.set_status(http.status_from_int(403))
		return ctx.text(json.encode(admin.AdminErrorResponse{
			error: 'forbidden'
		}))
	}
	limit := admin.AdminQuery.limit(ctx.query['limit'] or { '' }, 100, 1000)
	offset := admin.AdminQuery.offset(ctx.query['offset'] or { '' })
	instance_filter := (ctx.query['instance'] or { '' }).trim_space()
	chat_type_filter := (ctx.query['chat_type'] or { '' }).trim_space()
	chat_id_filter := (ctx.query['chat_id'] or { '' }).trim_space()
	body := json.encode(app.shared.providers.feishu.chats_snapshot(limit, offset, instance_filter,
		chat_type_filter, chat_id_filter))
	app.shared.emit('http.request', {
		'method':     'GET'
		'path':       '/admin/runtime/feishu/chats'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
		'plane':      'admin'
	})
	return ctx.text(body)
}

@['/admin/runtime/feishu/messages'; post]
pub fn (mut app AdminApp) admin_runtime_feishu_send(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' { '/admin/runtime/feishu/messages' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {} // safe to ignore: client may have disconnected
	ctx.set_content_type('application/json; charset=utf-8')
	if !app.admin_authorized(ctx) {
		ctx.res.set_status(http.status_from_int(403))
		return ctx.text(json.encode(admin.AdminErrorResponse{
			error: 'forbidden'
		}))
	}
	req := json.decode(feishu.SendMessageRequest, ctx.req.data) or {
		ctx.res.set_status(http.status_from_int(400))
		return ctx.text(json.encode(admin.AdminErrorResponse{
			error: 'invalid_json'
		}))
	}
	result := app.shared.feishu_runtime_send_message(req) or {
		ctx.res.set_status(http.status_from_int(502))
		return ctx.text(json.encode(admin.AdminFeishuSendResponse{
			ok:    false
			error: err.msg()
		}))
	}
	app.shared.emit('http.request', {
		'method':     'POST'
		'path':       '/admin/runtime/feishu/messages'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
		'plane':      'admin'
	})
	return ctx.text(json.encode(admin.AdminFeishuSendResponse{
		ok:         true
		message_id: result.message_id
	}))
}

@['/admin/workers/restart'; post]
pub fn (mut app AdminApp) admin_restart_worker(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' { '/admin/workers/restart' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {} // safe to ignore: client may have disconnected
	ctx.set_content_type('application/json; charset=utf-8')
	if !app.admin_authorized(ctx) {
		ctx.res.set_status(http.status_from_int(403))
		return ctx.text(json.encode(admin.AdminErrorResponse{
			error: 'forbidden'
		}))
	}
	id_raw := (ctx.query['id'] or { '' }).trim_space()
	if id_raw == '' {
		ctx.res.set_status(http.status_from_int(400))
		return ctx.text(json.encode(admin.AdminErrorResponse{
			error: 'missing worker id, use ?id=<worker_id>'
		}))
	}
	worker_id := id_raw.int()
	status := app.shared.restart_worker_by_id(worker_id) or {
		ctx.res.set_status(http.status_from_int(404))
		return ctx.text(json.encode(admin.AdminErrorResponse{
			error: err.msg()
		}))
	}
	body := json.encode(admin.AdminRestartSingleResponse{
		ok:     true
		mode:   'single'
		worker: status
	})
	app.shared.emit('admin.worker.restart', {
		'request_id': req_id
		'trace_id':   trace_id
		'mode':       'single'
		'worker_id':  '${worker_id}'
	})
	ctx.res.set_status(http.status_from_int(200))
	return ctx.text(body)
}

@['/admin/workers/restart/all'; post]
pub fn (mut app AdminApp) admin_restart_all_workers(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' { '/admin/workers/restart/all' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {} // safe to ignore: client may have disconnected
	ctx.set_content_type('application/json; charset=utf-8')
	if !app.admin_authorized(ctx) {
		ctx.res.set_status(http.status_from_int(403))
		return ctx.text(json.encode(admin.AdminErrorResponse{
			error: 'forbidden'
		}))
	}
	force := admin.AdminQuery.parse_boolish(ctx.query['force'] or { 'false' })
	restarted := app.shared.restart_all_workers()
	body := json.encode(admin.AdminRestartAllResponse{
		ok:        true
		mode:      'all'
		restarted: restarted
		force:     force
	})
	app.shared.emit('admin.worker.restart', {
		'request_id': req_id
		'trace_id':   trace_id
		'mode':       'all'
		'restarted':  '${restarted}'
	})
	ctx.res.set_status(http.status_from_int(200))
	return ctx.text(body)
}

fn run_admin_server(mut shared_app App, host string, port int, token string) {
	mut admin_app := &AdminApp{
		admin_host:  host
		admin_port:  port
		admin_token: token
		shared:      unsafe { shared_app }
	}
	veb.run_at[AdminApp, Context](mut admin_app,
		host:                 host
		port:                 port
		family:               .ip
		show_startup_message: false
	) or {
		err_msg := err.msg()
		shared_app.emit('admin.failed', {
			'host':  host
			'port':  '${port}'
			'error': err_msg
		})
		log.error('admin server failed: ${err_msg}')
	}
}

fn AdminPlaneRuntime.serve(mut shared_app App, host string, port int, token string) {
	run_admin_server(mut shared_app, host, port, token)
}
