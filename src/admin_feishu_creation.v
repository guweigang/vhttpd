module main

import admin
import feishu
import json2 as json
import upstream
import upstream.transport
import veb

// Credentials are available only on the admin listener with an explicitly
// configured header token. Browser/query credentials cannot mint worker grants.
fn (app AdminApp) feishu_creation_authorized(ctx Context) bool {
	return app.admin_token.trim_space() != '' && admin.AdminAuth.authorized(app.admin_token, transport.header_map_from_request(ctx.req), {})
}

// Creation endpoints never put caller query strings into access events.
fn feishu_creation_request(ctx Context, route string) AdminPlaneRequest {
	req := admin_plane_request(ctx, route)
	return AdminPlaneRequest{ ...req, path: route }
}

@['/admin/runtime/feishu/creation'; get]
pub fn (mut app AdminApp) admin_feishu_creation_discover(mut ctx Context) veb.Result {
	req := feishu_creation_request(ctx, '/admin/runtime/feishu/creation')
	if !app.feishu_creation_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	discovery := app.shared.providers.feishu.external_creation_discovery() or { return admin_plane_json_response(mut app, mut ctx, 'GET', req, 503, json.encode(admin.AdminErrorResponse{ error: err.msg() }), {}) }
	ctx.set_header(.cache_control, 'no-store')
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, json.encode(discovery), {})
}

@['/admin/runtime/feishu/creation'; post]
pub fn (mut app AdminApp) admin_feishu_creation_issue(mut ctx Context) veb.Result {
	req := feishu_creation_request(ctx, '/admin/runtime/feishu/creation')
	if !app.feishu_creation_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'POST', req)
	}
	if ctx.req.data.len > 8192 {
		return admin_plane_json_response(mut app, mut ctx, 'POST', req, 400, json.encode(admin.AdminErrorResponse{ error: 'feishu_creation_request' }), {})
	}
	input := json.decode[feishu.ExternalCreationRequest](ctx.req.data) or { return admin_plane_json_response(mut app, mut ctx, 'POST', req, 400, json.encode(admin.AdminErrorResponse{ error: 'invalid_json' }), {}) }
	lease := app.shared.issue_external_feishu_creation(input) or { return admin_plane_json_response(mut app, mut ctx, 'POST', req, 409, json.encode(admin.AdminErrorResponse{ error: err.msg() }), {}) }
	ctx.set_header(.cache_control, 'no-store')
	return admin_plane_json_response(mut app, mut ctx, 'POST', req, 200, json.encode(lease), {})
}

fn (mut app App) issue_external_feishu_creation(req feishu.ExternalCreationRequest) !feishu.CreationLease {
	attempt := app.providers.feishu.begin_external_creation(req)!
	if attempt.cached { return attempt.lease }
	defer {
		app.providers.feishu.finish_external_creation(attempt)
		if app.providers.feishu_card_bridge_enabled() {
			app.providers.feishu_card_bridge_rotate_creation_capacity_if_idle()
		}
	}
	if app.providers.feishu_card_bridge_enabled() {
		result := app.providers.feishu_card_bridge_proxy_request('create', upstream.UpstreamSendRequest{
			provider:    'feishu'
			instance:    req.instance
			target:      req.message_id
			target_type: if req.kind == 'bind' {
				'message_id'
			} else {
				''
			}
			metadata:    {
				'stream_id': req.stream_id
			}
		})!
		if !result.ok { return error('feishu_creation_unavailable') }
		lease := feishu.CreationLease{ generation: result.stream_generation, token: result.creation_token }
		return app.providers.feishu.complete_external_remote_owned(attempt, lease, result.authority) or {
			app.revoke_remote_feishu_creation(req, lease, result.authority) or {}
			return err
		}
	}
	return app.providers.feishu.complete_external_local(attempt)
}

@['/admin/runtime/feishu/creation/revoke'; post]
pub fn (mut app AdminApp) admin_feishu_creation_revoke(mut ctx Context) veb.Result {
	req := feishu_creation_request(ctx, '/admin/runtime/feishu/creation/revoke')
	if !app.feishu_creation_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'POST', req)
	}
	if ctx.req.data.len > 8192 {
		return admin_plane_json_response(mut app, mut ctx, 'POST', req, 400, '{}', {})
	}
	input := json.decode[feishu.ExternalCreationRequest](ctx.req.data) or { return admin_plane_json_response(mut app, mut ctx, 'POST', req, 400, '{}', {}) }
	authority := app.shared.providers.feishu.external_creation_authority(input)
	lease := app.shared.providers.feishu.revoke_external_creation(input) or { return admin_plane_json_response(mut app, mut ctx, 'POST', req, 409, json.encode(admin.AdminErrorResponse{ error: err.msg() }), {}) }
	app.shared.revoke_remote_feishu_creation(input, lease, authority) or {
		return admin_plane_json_response(mut app, mut ctx, 'POST', req, 503, json.encode(admin.AdminErrorResponse{ error: 'feishu_creation_revoke_unavailable' }), {})
	}
	ctx.set_header(.cache_control, 'no-store')
	return admin_plane_json_response(mut app, mut ctx, 'POST', req, 200, '{"revoked":true}', {})
}

fn (mut app App) revoke_remote_feishu_creation(req feishu.ExternalCreationRequest, lease feishu.CreationLease, authority ?&feishu.BridgeAuthority) ! {
	if lease.token == '' || !app.providers.feishu_card_bridge_enabled() { return }
	if authority == none { return error('bridge_authority_retired') }
	result := app.providers.feishu_card_bridge_proxy_request_owned('revoke_creation', upstream.UpstreamSendRequest{
		provider: 'feishu'
		instance: req.instance
		metadata: {
			'stream_id':         req.stream_id
			'stream_generation': lease.generation
			'creation_token':    lease.token
		}
	}, authority)!
	if !result.ok { return error('feishu_creation_revoke_unavailable') }
}
