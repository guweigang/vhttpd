module main

import json
import time
import veb

@['/admin/providers/specs'; get]
pub fn (mut app App) admin_provider_specs(mut ctx Context) veb.Result {
	start_ms := time.now().unix_milli()
	path := if ctx.req.url == '' { '/admin/providers/specs' } else { ctx.req.url }
	req_id := HttpRequestIdentity.request_id(ctx, path)
	trace_id := HttpRequestIdentity.trace_id(ctx, path)
	if !app.control_plane.admin.on_data_plane {
		return admin_data_plane_text_response(mut app, mut ctx, 'GET', path, req_id, trace_id,
			start_ms, 404, 'Not Found', {
			'admin_endpoint': 'providers.specs'
		})
	}
	body := json.encode(app.admin_provider_specs_snapshot())
	return admin_data_plane_json_response(mut app, mut ctx, 'GET', path, req_id, trace_id,
		start_ms, 200, body, {
		'admin_endpoint': 'providers.specs'
	})
}

@['/admin/providers/runtimes'; get]
pub fn (mut app App) admin_provider_runtimes(mut ctx Context) veb.Result {
	start_ms := time.now().unix_milli()
	path := if ctx.req.url == '' { '/admin/providers/runtimes' } else { ctx.req.url }
	req_id := HttpRequestIdentity.request_id(ctx, path)
	trace_id := HttpRequestIdentity.trace_id(ctx, path)
	if !app.control_plane.admin.on_data_plane {
		return admin_data_plane_text_response(mut app, mut ctx, 'GET', path, req_id, trace_id,
			start_ms, 404, 'Not Found', {
			'admin_endpoint': 'providers.runtimes'
		})
	}
	body := json.encode(app.admin_provider_runtimes_snapshot())
	return admin_data_plane_json_response(mut app, mut ctx, 'GET', path, req_id, trace_id,
		start_ms, 200, body, {
		'admin_endpoint': 'providers.runtimes'
	})
}
