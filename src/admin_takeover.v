module main

import admin
import json2 as json
import relay
import upstream.transport
import veb

// This endpoint is management-plane only and requires the explicit header
// token. Relay credentials remain in the project, never in the UI request.
@['/admin/runtime/takeover'; post]
pub fn (mut app AdminApp) admin_takeover_control(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/runtime/takeover')
	if app.admin_token == '' || !admin.AdminAuth.authorized(app.admin_token, transport.header_map_from_request(ctx.req), {}) {
		return admin_plane_forbidden(mut app, mut ctx, 'POST', req)
	}
	ctx.set_header(.cache_control, 'no-store')
	if ctx.req.data.len > 8192 {
		return admin_plane_json_response(mut app, mut ctx, 'POST', req, 400, '{"error":"takeover_limit"}', {})
	}
	input := json.decode[TakeoverControl](ctx.req.data) or { return admin_plane_json_response(mut app, mut ctx, 'POST', req, 400, '{"error":"invalid_json"}', {}) }
	body := app.shared.control_local_takeover(input) or { return admin_plane_json_response(mut app, mut ctx, 'POST', req, 409, '{"error":"takeover_control_failed_check_connection_and_remote_export"}', {}) }
	return admin_plane_json_response(mut app, mut ctx, 'POST', req, 200, body, {})
}

fn (mut app App) control_local_takeover(input TakeoverControl) !string {
	if input.action !in ['start', 'stop', 'status'] || input.route == '' || input.route.len > 128 {
		return error('takeover_invalid_control')
	}
	view := app.pipeline_dispatch_view()
	descriptor := view.plan.relays[input.relay_id] or { return error('takeover_unknown_relay') }
	if descriptor.mode != 'agent' || descriptor.options.strings['token'] == '' {
		return error('takeover_requires_authenticated_agent')
	}
	// Opening a session without a receiver would divert and fail live requests.
	if input.action == 'start' {
		mut registry := app.takeovers
		if registry.executions() > 0 { return error('takeover_local_draining') }
		mut receiver := false
		for pipeline in view.plan.pipelines {
			if pipeline.ingress.str() != 'relay:${input.relay_id}' || pipeline.egress.domain != .adapter {
				continue
			}
			adapter := view.plan.adapters[pipeline.egress.id] or { continue }
			if adapter.kind == 'debug-http' { receiver = true }
		}
		if !receiver { return error('takeover_receiver_missing') }
	}
	binding := relay.carrier_dispatch_plan(app.relay.carriers, input.relay_id, relay.WireFrame{})
	result := app.request_takeover_relay(input.relay_id, input.route, json.encode(input), 5000, binding)!
	value := json.decode[json.Any](result.body)!.as_map()
	active := value['active'] or { return error('takeover_invalid_control_response') }
	if active !is bool { return error('takeover_invalid_control_response') }
	status := json.decode[TakeoverStatus](result.body)!
	if input.action != 'status' {
		app.emit('relay.takeover.control', {'relay_id': input.relay_id, 'route': input.route,
			'action': input.action, 'state': if status.active { 'active' } else { 'remote' }})
	}
	mut registry := app.takeovers
	return json.encode(TakeoverStatus{ ...status, local_in_flight: registry.executions() })
}

@['/admin/runtime/relay'; get]
pub fn (mut app AdminApp) admin_relay_diagnostics(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/runtime/relay')
	if !app.admin_authorized(ctx) { return admin_plane_forbidden(mut app, mut ctx, 'GET', req) }
	ctx.set_header(.cache_control, 'no-store')
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200,
		json.encode(app.shared.admin_relay_runtime_snapshot()), {'admin_endpoint': 'relay_diagnostics'})
}
