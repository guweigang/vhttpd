module main

import json
import veb

@['/admin/providers/specs'; get]
pub fn (mut app App) admin_provider_specs(mut ctx Context) veb.Result {
	req := admin_data_plane_request(ctx, '/admin/providers/specs')
	if !app.control_plane.admin.on_data_plane {
		return admin_data_plane_text(mut app, mut ctx, 'GET', req, 404, 'Not Found', {
			'admin_endpoint': 'providers.specs'
		})
	}
	body := json.encode(app.admin_provider_specs_snapshot())
	return admin_data_plane_json(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'providers.specs'
	})
}

@['/admin/providers/runtimes'; get]
pub fn (mut app App) admin_provider_runtimes(mut ctx Context) veb.Result {
	req := admin_data_plane_request(ctx, '/admin/providers/runtimes')
	if !app.control_plane.admin.on_data_plane {
		return admin_data_plane_text(mut app, mut ctx, 'GET', req, 404, 'Not Found', {
			'admin_endpoint': 'providers.runtimes'
		})
	}
	body := json.encode(app.admin_provider_runtimes_snapshot())
	return admin_data_plane_json(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'providers.runtimes'
	})
}
