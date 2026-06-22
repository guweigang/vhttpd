module main

import admin
import feishu
import json
import log
import net.http
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
	ctx.res.set_status(.ok)
	return ctx.text('OK')
}

@['/admin/workers'; get]
pub fn (mut app AdminApp) admin_workers(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' { '/admin/workers' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	if !app.admin_authorized(ctx) {
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {} // safe to ignore: client may have disconnected
		ctx.res.set_status(http.status_from_int(403))
		return ctx.text('Forbidden')
	}
	body := json.encode(app.shared.worker_admin_snapshot())
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {} // safe to ignore: client may have disconnected
	ctx.set_content_type('application/json; charset=utf-8')
	app.shared.emit('http.request', {
		'method':     'GET'
		'path':       '/admin/workers'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
		'plane':      'admin'
	})
	return ctx.text(body)
}

@['/admin/stats'; get]
pub fn (mut app AdminApp) admin_stats(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' { '/admin/stats' } else { ctx.req.url }
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
	body := json.encode(app.shared.admin_stats_snapshot())
	app.shared.emit('http.request', {
		'method':     'GET'
		'path':       '/admin/stats'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
		'plane':      'admin'
	})
	return ctx.text(body)
}

@['/admin/runtime'; get]
pub fn (mut app AdminApp) admin_runtime(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' { '/admin/runtime' } else { ctx.req.url }
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
	body := json.encode(app.shared.admin_runtime_snapshot())
	app.shared.emit('http.request', {
		'method':     'GET'
		'path':       '/admin/runtime'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
		'plane':      'admin'
	})
	return ctx.text(body)
}

// New: return registered provider names as a stable admin endpoint so callers
// don't need to parse /admin/runtime wrapper. This keeps API surface small
// and explicit for tooling.
@['/admin/providers'; get]
pub fn (mut app AdminApp) admin_providers(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' { '/admin/providers' } else { ctx.req.url }
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
	// provider_names returns []string
	body := json.encode(app.shared.provider_names())
	app.shared.emit('http.request', {
		'method':     'GET'
		'path':       '/admin/providers'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
		'plane':      'admin'
	})
	return ctx.text(body)
}

@['/admin/executors'; get]
pub fn (mut app AdminApp) admin_executors(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' { '/admin/executors' } else { ctx.req.url }
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
	body := json.encode(app.shared.admin_logic_executor_specs_snapshot())
	app.shared.emit('http.request', {
		'method':     'GET'
		'path':       '/admin/executors'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
		'plane':      'admin'
	})
	return ctx.text(body)
}

@['/admin/providers/specs'; get]
pub fn (mut app AdminApp) admin_provider_specs(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' { '/admin/providers/specs' } else { ctx.req.url }
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
	body := json.encode(app.shared.admin_provider_specs_snapshot())
	app.shared.emit('http.request', {
		'method':     'GET'
		'path':       '/admin/providers/specs'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
		'plane':      'admin'
	})
	return ctx.text(body)
}

@['/admin/providers/runtimes'; get]
pub fn (mut app AdminApp) admin_provider_runtimes(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' { '/admin/providers/runtimes' } else { ctx.req.url }
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
	body := json.encode(app.shared.admin_provider_runtimes_snapshot())
	app.shared.emit('http.request', {
		'method':     'GET'
		'path':       '/admin/providers/runtimes'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
		'plane':      'admin'
	})
	return ctx.text(body)
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
