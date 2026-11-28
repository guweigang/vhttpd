module main

import admin
import application_logs
import json2 as json
import veb

// An authenticated Admin query filters at the source. Missing support is an
// explicit error to clients; they must never substitute mixed process output.
@['/admin/logs'; get]
pub fn (mut app AdminApp) admin_application_logs(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx,'/admin/logs')
	if !app.admin_authorized(ctx) { return admin_plane_forbidden(mut app,mut ctx,'GET',req) }
	application := ctx.query['application'] or { '*' }
	source := ctx.query['source'] or { '' }
	if source !in ['','console','request','relay'] {
		return admin_plane_json_response(mut app,mut ctx,'GET',req,400,'{"error":"invalid_log_source"}',{'admin_endpoint':'application_logs'})
	}
	limit := admin.AdminQuery.limit(ctx.query['limit'] or { '' },200,1000)
	mut store := application_logs.shared()
	data := store.snapshot(application,source,(ctx.query['after'] or { '0' }).u64(),limit)
	return admin_plane_json_response(mut app,mut ctx,'GET',req,200,json.encode(data,escape_unicode:true,time_as_unix:true),{'admin_endpoint':'application_logs'})
}

@['/admin/logs'; get]
pub fn (mut app App) admin_application_logs(mut ctx Context) veb.Result {
	req := admin_data_plane_request(ctx,'/admin/logs')
	if !app.control_plane.admin.on_data_plane { return admin_data_plane_text(mut app,mut ctx,'GET',req,404,'Not Found',{'admin_endpoint':'application_logs'}) }
	source := ctx.query['source'] or { '' }
	if source !in ['','console','request','relay'] { return admin_data_plane_json(mut app,mut ctx,'GET',req,400,'{"error":"invalid_log_source"}',{'admin_endpoint':'application_logs'}) }
	mut store := application_logs.shared()
	data := store.snapshot(ctx.query['application'] or { '*' },source,(ctx.query['after'] or { '0' }).u64(),admin.AdminQuery.limit(ctx.query['limit'] or { '' },200,1000))
	return admin_data_plane_json(mut app,mut ctx,'GET',req,200,json.encode(data,escape_unicode:true,time_as_unix:true),{'admin_endpoint':'application_logs'})
}
