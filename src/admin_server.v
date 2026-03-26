module main

import json
import log
import net.http
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

struct AdminErrorResponse {
	error string
}

struct AdminRestartSingleResponse {
	ok     bool
	mode   string
	worker WorkerAdminStatus
}

struct AdminRestartAllResponse {
	ok        bool
	mode      string
	restarted int
	force     bool
}

struct AdminFeishuSendResponse {
	ok         bool
	message_id string @[json: 'message_id']
	error      string
}

fn (app AdminApp) admin_authorized(ctx Context) bool {
	if app.admin_token == '' {
		return true
	}
	headers := header_map_from_request(ctx.req)
	mut token := headers['x-vhttpd-admin-token']
	if token == '' {
		token = ctx.query['admin_token'] or { '' }
	}
	return token == app.admin_token
}

fn (app &App) api_authorized(ctx Context) bool {
	if app.admin_token == '' {
		return true
	}
	headers := header_map_from_request(ctx.req)
	mut token := headers['x-vhttpd-admin-token']
	if token == '' {
		token = ctx.query['admin_token'] or { '' }
	}
	return token == app.admin_token
}

fn admin_parse_boolish(raw string) bool {
	return raw.trim_space().to_lower() in ['1', 'true', 'yes', 'on']
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
		ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
		ctx.res.set_status(http.status_from_int(403))
		return ctx.text('Forbidden')
	}
	body := json.encode(app.shared.worker_admin_snapshot())
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
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
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	ctx.set_content_type('application/json; charset=utf-8')
	if !app.admin_authorized(ctx) {
		ctx.res.set_status(http.status_from_int(403))
		return ctx.text(json.encode(AdminErrorResponse{
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
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	ctx.set_content_type('application/json; charset=utf-8')
	if !app.admin_authorized(ctx) {
		ctx.res.set_status(http.status_from_int(403))
		return ctx.text(json.encode(AdminErrorResponse{
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
    ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
    ctx.set_content_type('application/json; charset=utf-8')
    if !app.admin_authorized(ctx) {
        ctx.res.set_status(http.status_from_int(403))
        return ctx.text(json.encode(AdminErrorResponse{
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

@['/admin/providers/specs'; get]
pub fn (mut app AdminApp) admin_provider_specs(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' { '/admin/providers/specs' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	ctx.set_content_type('application/json; charset=utf-8')
	if !app.admin_authorized(ctx) {
		ctx.res.set_status(http.status_from_int(403))
		return ctx.text(json.encode(AdminErrorResponse{
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
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	ctx.set_content_type('application/json; charset=utf-8')
	if !app.admin_authorized(ctx) {
		ctx.res.set_status(http.status_from_int(403))
		return ctx.text(json.encode(AdminErrorResponse{
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
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	ctx.set_content_type('application/json; charset=utf-8')
	if !app.admin_authorized(ctx) {
		ctx.res.set_status(http.status_from_int(403))
		return ctx.text(json.encode(AdminErrorResponse{
			error: 'forbidden'
		}))
	}
	details := admin_query_boolish(ctx.query['details'] or { 'false' })
	limit := admin_query_limit(ctx.query['limit'] or { '' }, 100, 1000)
	offset := admin_query_offset(ctx.query['offset'] or { '' })
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
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	ctx.set_content_type('application/json; charset=utf-8')
	if !app.admin_authorized(ctx) {
		ctx.res.set_status(http.status_from_int(403))
		return ctx.text(json.encode(AdminErrorResponse{
			error: 'forbidden'
		}))
	}
	details := admin_query_boolish(ctx.query['details'] or { 'false' })
	limit := admin_query_limit(ctx.query['limit'] or { '' }, 100, 1000)
	offset := admin_query_offset(ctx.query['offset'] or { '' })
	room_filter := (ctx.query['room'] or { '' }).trim_space()
	conn_filter := (ctx.query['conn_id'] or { '' }).trim_space()
	body := json.encode(app.shared.admin_websockets_snapshot(details, limit, offset, room_filter,
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
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	ctx.set_content_type('application/json; charset=utf-8')
	if !app.admin_authorized(ctx) {
		ctx.res.set_status(http.status_from_int(403))
		return ctx.text(json.encode(AdminErrorResponse{
			error: 'forbidden'
		}))
	}
	details := admin_query_boolish(ctx.query['details'] or { 'false' })
	limit := admin_query_limit(ctx.query['limit'] or { '' }, 100, 1000)
	offset := admin_query_offset(ctx.query['offset'] or { '' })
	session_filter := (ctx.query['session_id'] or { '' }).trim_space()
	protocol_filter := (ctx.query['protocol_version'] or { '' }).trim_space()
	body := json.encode(app.shared.admin_mcp_snapshot(details, limit, offset, session_filter,
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

@['/admin/runtime/feishu'; get]
pub fn (mut app AdminApp) admin_runtime_feishu(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' { '/admin/runtime/feishu' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	ctx.set_content_type('application/json; charset=utf-8')
	if !app.admin_authorized(ctx) {
		ctx.res.set_status(http.status_from_int(403))
		return ctx.text(json.encode(AdminErrorResponse{
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

@['/admin/runtime/feishu/chats'; get]
pub fn (mut app AdminApp) admin_runtime_feishu_chats(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' { '/admin/runtime/feishu/chats' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	ctx.set_content_type('application/json; charset=utf-8')
	if !app.admin_authorized(ctx) {
		ctx.res.set_status(http.status_from_int(403))
		return ctx.text(json.encode(AdminErrorResponse{
			error: 'forbidden'
		}))
	}
	limit := admin_query_limit(ctx.query['limit'] or { '' }, 100, 1000)
	offset := admin_query_offset(ctx.query['offset'] or { '' })
	instance_filter := (ctx.query['instance'] or { '' }).trim_space()
	chat_type_filter := (ctx.query['chat_type'] or { '' }).trim_space()
	chat_id_filter := (ctx.query['chat_id'] or { '' }).trim_space()
	body := json.encode(app.shared.feishu_runtime_chats_snapshot(limit, offset, instance_filter,
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
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	ctx.set_content_type('application/json; charset=utf-8')
	if !app.admin_authorized(ctx) {
		ctx.res.set_status(http.status_from_int(403))
		return ctx.text(json.encode(AdminErrorResponse{
			error: 'forbidden'
		}))
	}
	req := json.decode(FeishuRuntimeSendMessageRequest, ctx.req.data) or {
		ctx.res.set_status(http.status_from_int(400))
		return ctx.text(json.encode(AdminErrorResponse{
			error: 'invalid_json'
		}))
	}
	result := app.shared.feishu_runtime_send_message(req) or {
		ctx.res.set_status(http.status_from_int(502))
		return ctx.text(json.encode(AdminFeishuSendResponse{
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
	return ctx.text(json.encode(AdminFeishuSendResponse{
		ok:         true
		message_id: result.message_id
	}))
}

@['/admin/workers/restart'; post]
pub fn (mut app AdminApp) admin_restart_worker(mut ctx Context) veb.Result {
	path := if ctx.req.url == '' { '/admin/workers/restart' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	ctx.set_content_type('application/json; charset=utf-8')
	if !app.admin_authorized(ctx) {
		ctx.res.set_status(http.status_from_int(403))
		return ctx.text(json.encode(AdminErrorResponse{
			error: 'forbidden'
		}))
	}
	id_raw := (ctx.query['id'] or { '' }).trim_space()
	if id_raw == '' {
		ctx.res.set_status(http.status_from_int(400))
		return ctx.text(json.encode(AdminErrorResponse{
			error: 'missing worker id, use ?id=<worker_id>'
		}))
	}
	worker_id := id_raw.int()
	status := app.shared.restart_worker_by_id(worker_id) or {
		ctx.res.set_status(http.status_from_int(404))
		return ctx.text(json.encode(AdminErrorResponse{
			error: err.msg()
		}))
	}
	body := json.encode(AdminRestartSingleResponse{
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
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
	ctx.set_content_type('application/json; charset=utf-8')
	if !app.admin_authorized(ctx) {
		ctx.res.set_status(http.status_from_int(403))
		return ctx.text(json.encode(AdminErrorResponse{
			error: 'forbidden'
		}))
	}
	force := admin_parse_boolish(ctx.query['force'] or { 'false' })
	restarted := app.shared.restart_all_workers()
	body := json.encode(AdminRestartAllResponse{
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
	mut admin := &AdminApp{
		admin_host:  host
		admin_port:  port
		admin_token: token
		shared:      unsafe { shared_app }
	}
	veb.run_at[AdminApp, Context](mut admin,
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
