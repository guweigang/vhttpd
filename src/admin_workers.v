module main

import admin
import json
import time
import veb

@['/admin/workers'; get]
pub fn (mut app App) admin_workers(mut ctx Context) veb.Result {
	start_ms := time.now().unix_milli()
	path := if ctx.req.url == '' { '/admin/workers' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	if !app.control_plane.admin.on_data_plane {
		return admin_data_plane_text_response(mut app, mut ctx, 'GET', path, req_id, trace_id,
			start_ms, 404, 'Not Found', {
			'admin_endpoint': 'workers'
		})
	}
	body := json.encode(app.worker_admin_snapshot())
	return admin_data_plane_json_response(mut app, mut ctx, 'GET', path, req_id, trace_id,
		start_ms, 200, body, {
		'admin_endpoint': 'workers'
	})
}

@['/admin/stats'; get]
pub fn (mut app App) admin_stats(mut ctx Context) veb.Result {
	start_ms := time.now().unix_milli()
	path := if ctx.req.url == '' { '/admin/stats' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	if !app.control_plane.admin.on_data_plane {
		return admin_data_plane_text_response(mut app, mut ctx, 'GET', path, req_id, trace_id,
			start_ms, 404, 'Not Found', {
			'admin_endpoint': 'stats'
		})
	}
	body := json.encode(app.admin_stats_snapshot())
	return admin_data_plane_json_response(mut app, mut ctx, 'GET', path, req_id, trace_id,
		start_ms, 200, body, {
		'admin_endpoint': 'stats'
	})
}

@['/admin/workers/restart'; post]
pub fn (mut app App) admin_restart_worker(mut ctx Context) veb.Result {
	start_ms := time.now().unix_milli()
	path := if ctx.req.url == '' { '/admin/workers/restart' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	if !app.control_plane.admin.on_data_plane {
		return admin_data_plane_text_response(mut app, mut ctx, 'POST', path, req_id, trace_id,
			start_ms, 404, 'Not Found', {
			'admin_endpoint': 'workers.restart'
		})
	}
	id_raw := (ctx.query['id'] or { '' }).trim_space()
	if id_raw == '' {
		return admin_data_plane_json_response(mut app, mut ctx, 'POST', path, req_id, trace_id,
			start_ms, 400, json.encode(admin.WorkerAdminErrorResponse{
			error: 'missing worker id, use ?id=<worker_id>'
		}), {
			'admin_endpoint': 'workers.restart'
			'error':          'missing_worker_id'
		})
	}
	worker_id := id_raw.int()
	status := app.restart_worker_by_id(worker_id) or {
		return admin_data_plane_json_response(mut app, mut ctx, 'POST', path, req_id, trace_id,
			start_ms, 404, json.encode(admin.WorkerAdminErrorResponse{
			error: err.msg()
		}), {
			'admin_endpoint': 'workers.restart'
			'error':          err.msg()
		})
	}
	app.emit('admin.worker.restart', {
		'request_id': req_id
		'trace_id':   trace_id
		'mode':       'single'
		'worker_id':  '${worker_id}'
		'plane':      'data'
	})
	return admin_data_plane_json_response(mut app, mut ctx, 'POST', path, req_id, trace_id,
		start_ms, 200, json.encode(admin.WorkerAdminRestartSingleResponse{
		ok:     true
		mode:   'single'
		worker: status
	}), {
		'admin_endpoint': 'workers.restart'
		'worker_id':      '${worker_id}'
	})
}

@['/admin/workers/restart/all'; post]
pub fn (mut app App) admin_restart_all_workers(mut ctx Context) veb.Result {
	start_ms := time.now().unix_milli()
	path := if ctx.req.url == '' { '/admin/workers/restart/all' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	if !app.control_plane.admin.on_data_plane {
		return admin_data_plane_text_response(mut app, mut ctx, 'POST', path, req_id, trace_id,
			start_ms, 404, 'Not Found', {
			'admin_endpoint': 'workers.restart_all'
		})
	}
	restarted := app.restart_all_workers()
	app.emit('admin.worker.restart', {
		'request_id': req_id
		'trace_id':   trace_id
		'mode':       'all'
		'restarted':  '${restarted}'
		'plane':      'data'
	})
	return admin_data_plane_json_response(mut app, mut ctx, 'POST', path, req_id, trace_id,
		start_ms, 200, json.encode(admin.WorkerAdminRestartAllResponse{
		ok:        true
		mode:      'all'
		restarted: restarted
	}), {
		'admin_endpoint': 'workers.restart_all'
		'restarted':      '${restarted}'
	})
}

@['/admin/workers/drain'; post]
pub fn (mut app App) admin_drain_workers(mut ctx Context) veb.Result {
	start_ms := time.now().unix_milli()
	path := if ctx.req.url == '' { '/admin/workers/drain' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	if !app.control_plane.admin.on_data_plane {
		return admin_data_plane_text_response(mut app, mut ctx, 'POST', path, req_id, trace_id,
			start_ms, 404, 'Not Found', {
			'admin_endpoint': 'workers.drain'
		})
	}
	engine := (ctx.query['engine'] or { ctx.query['kind'] or { '' } }).trim_space()
	status := app.drain_engine(engine) or {
		return admin_data_plane_json_response(mut app, mut ctx, 'POST', path, req_id, trace_id,
			start_ms, 404, json.encode(admin.WorkerAdminErrorResponse{
			error: err.msg()
		}), {
			'admin_endpoint': 'workers.drain'
			'error':          err.msg()
		})
	}
	return admin_data_plane_json_response(mut app, mut ctx, 'POST', path, req_id, trace_id,
		start_ms, 200, json.encode(status), {
		'admin_endpoint':    'workers.drain'
		'engine':            status.engine
		'draining_count':    '${status.draining_count}'
		'inflight_requests': '${status.inflight_requests}'
	})
}
