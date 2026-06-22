module main

import json
import veb

@['/admin/providers/specs'; get]
pub fn (mut app App) admin_provider_specs(mut ctx Context) veb.Result {
	if !app.control_plane.admin.on_data_plane {
		ctx.res.set_status(.not_found)
		return ctx.text('Not Found')
	}
	path := if ctx.req.url == '' { '/admin/providers/specs' } else { ctx.req.url }
	req_id := HttpRequestIdentity.request_id(ctx, path)
	trace_id := HttpRequestIdentity.trace_id(ctx, path)
	body := json.encode(app.admin_provider_specs_snapshot())
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {} // safe to ignore: client may have disconnected
	ctx.set_content_type('application/json; charset=utf-8')
	app.emit('http.request', {
		'method':     'GET'
		'path':       '/admin/providers/specs'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
	})
	return ctx.text(body)
}

@['/admin/providers/runtimes'; get]
pub fn (mut app App) admin_provider_runtimes(mut ctx Context) veb.Result {
	if !app.control_plane.admin.on_data_plane {
		ctx.res.set_status(.not_found)
		return ctx.text('Not Found')
	}
	path := if ctx.req.url == '' { '/admin/providers/runtimes' } else { ctx.req.url }
	req_id := HttpRequestIdentity.request_id(ctx, path)
	trace_id := HttpRequestIdentity.trace_id(ctx, path)
	body := json.encode(app.admin_provider_runtimes_snapshot())
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {} // safe to ignore: client may have disconnected
	ctx.set_content_type('application/json; charset=utf-8')
	app.emit('http.request', {
		'method':     'GET'
		'path':       '/admin/providers/runtimes'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
	})
	return ctx.text(body)
}
