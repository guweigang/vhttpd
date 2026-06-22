module main

import admin
import json
import net.http
import veb

@['/admin/workers'; get]
pub fn (mut app App) admin_workers(mut ctx Context) veb.Result {
	if !app.control_plane.admin.on_data_plane {
		ctx.res.set_status(.not_found)
		return ctx.text('Not Found')
	}
	path := if ctx.req.url == '' { '/admin/workers' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	body := json.encode(app.worker_admin_snapshot())
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {} // safe to ignore: client may have disconnected
	ctx.set_content_type('application/json; charset=utf-8')
	app.emit('http.request', {
		'method':     'GET'
		'path':       '/admin/workers'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
	})
	return ctx.text(body)
}

@['/admin/stats'; get]
pub fn (mut app App) admin_stats(mut ctx Context) veb.Result {
	if !app.control_plane.admin.on_data_plane {
		ctx.res.set_status(.not_found)
		return ctx.text('Not Found')
	}
	path := if ctx.req.url == '' { '/admin/stats' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	body := json.encode(app.admin_stats_snapshot())
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {} // safe to ignore: client may have disconnected
	ctx.set_content_type('application/json; charset=utf-8')
	app.emit('http.request', {
		'method':     'GET'
		'path':       '/admin/stats'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
	})
	return ctx.text(body)
}

@['/admin/workers/restart'; post]
pub fn (mut app App) admin_restart_worker(mut ctx Context) veb.Result {
	if !app.control_plane.admin.on_data_plane {
		ctx.res.set_status(.not_found)
		return ctx.text('Not Found')
	}
	path := if ctx.req.url == '' { '/admin/workers/restart' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {} // safe to ignore: client may have disconnected
	ctx.set_content_type('application/json; charset=utf-8')
	id_raw := (ctx.query['id'] or { '' }).trim_space()
	if id_raw == '' {
		ctx.res.set_status(http.status_from_int(400))
		return ctx.text(json.encode(admin.WorkerAdminErrorResponse{
			error: 'missing worker id, use ?id=<worker_id>'
		}))
	}
	worker_id := id_raw.int()
	status := app.restart_worker_by_id(worker_id) or {
		ctx.res.set_status(http.status_from_int(404))
		return ctx.text(json.encode(admin.WorkerAdminErrorResponse{
			error: err.msg()
		}))
	}
	app.emit('admin.worker.restart', {
		'request_id': req_id
		'trace_id':   trace_id
		'mode':       'single'
		'worker_id':  '${worker_id}'
		'plane':      'data'
	})
	ctx.res.set_status(http.status_from_int(200))
	return ctx.text(json.encode(admin.WorkerAdminRestartSingleResponse{
		ok:     true
		mode:   'single'
		worker: status
	}))
}

@['/admin/workers/restart/all'; post]
pub fn (mut app App) admin_restart_all_workers(mut ctx Context) veb.Result {
	if !app.control_plane.admin.on_data_plane {
		ctx.res.set_status(.not_found)
		return ctx.text('Not Found')
	}
	path := if ctx.req.url == '' { '/admin/workers/restart/all' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {} // safe to ignore: client may have disconnected
	ctx.set_content_type('application/json; charset=utf-8')
	restarted := app.restart_all_workers()
	app.emit('admin.worker.restart', {
		'request_id': req_id
		'trace_id':   trace_id
		'mode':       'all'
		'restarted':  '${restarted}'
		'plane':      'data'
	})
	ctx.res.set_status(http.status_from_int(200))
	return ctx.text(json.encode(admin.WorkerAdminRestartAllResponse{
		ok:        true
		mode:      'all'
		restarted: restarted
	}))
}
