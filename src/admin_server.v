module main

import admin
import dispatch
import feishu
import json
import log
import os
import time
import upstream.transport
import veb

pub struct AdminApp {
	veb.Middleware[Context]
	veb.StaticHandler
pub:
	admin_host  string
	admin_port  int
	admin_token string
pub mut:
	shared &App = unsafe { nil }
}

struct AdminPlaneRuntime {}

struct AdminPlaneRequest {
	path     string
	req_id   string
	trace_id string
	start_ms i64
}

fn admin_plane_request(ctx Context, default_path string) AdminPlaneRequest {
	path := if ctx.req.url == '' { default_path } else { ctx.req.url }
	return AdminPlaneRequest{
		path:     path
		req_id:   resolve_request_id(ctx, path)
		trace_id: resolve_trace_id(ctx, path)
		start_ms: time.now().unix_milli()
	}
}

fn admin_plane_json_response(mut admin_app AdminApp, mut ctx Context, method string, req AdminPlaneRequest, status int, body string, metadata map[string]string) veb.Result {
	mut event_metadata := {
		'plane': 'admin'
	}
	for key, value in metadata {
		if key != '' && value != '' {
			event_metadata[key] = value
		}
	}
	return HttpResponseRuntime.delivery_outcome(mut admin_app.shared, mut ctx, http_ingress_request(method,
		req.path, req.path, '', if isnil(ctx.conn) { '' } else { ctx.conn.peer_ip() or { '' } },
		req.req_id, req.trace_id, req.start_ms), dispatch.outcome_with_metadata(dispatch.response_outcome(status, {
		'content-type': 'application/json; charset=utf-8'
	}, body), event_metadata), none)
}

fn admin_plane_text_response(mut admin_app AdminApp, mut ctx Context, method string, req AdminPlaneRequest, status int, body string, metadata map[string]string) veb.Result {
	mut event_metadata := {
		'plane': 'admin'
	}
	for key, value in metadata {
		if key != '' && value != '' {
			event_metadata[key] = value
		}
	}
	return HttpResponseRuntime.delivery_outcome(mut admin_app.shared, mut ctx, http_ingress_request(method,
		req.path, req.path, '', if isnil(ctx.conn) { '' } else { ctx.conn.peer_ip() or { '' } },
		req.req_id, req.trace_id, req.start_ms), dispatch.outcome_with_metadata(dispatch.response_outcome(status, {
		'content-type': 'text/plain; charset=utf-8'
	}, body), event_metadata), none)
}

fn admin_ui_dir_path() string {
	candidates := [
		os.join_path(os.getwd(), 'admin', 'ui'),
		os.join_path(os.dir(os.executable()), 'admin', 'ui'),
		os.join_path(os.dir(@FILE), '..', 'admin', 'ui'),
	]
	for candidate in candidates {
		if os.is_dir(candidate) {
			return candidate
		}
	}
	return candidates[0]
}

fn admin_ui_file_path(name string) string {
	return os.join_path(admin_ui_dir_path(), name)
}

fn admin_plane_forbidden(mut admin_app AdminApp, mut ctx Context, method string, req AdminPlaneRequest) veb.Result {
	return admin_plane_json_response(mut admin_app, mut ctx, method, req, 403, json.encode(admin.AdminErrorResponse{
		error: 'forbidden'
	}), {
		'error': 'forbidden'
	})
}

fn (app AdminApp) admin_authorized(ctx Context) bool {
	headers := transport.header_map_from_request(ctx.req)
	return admin.AdminAuth.authorized(app.admin_token, headers, ctx.query)
}

fn (app &App) api_authorized(ctx Context) bool {
	headers := transport.header_map_from_request(ctx.req)
	return admin.AdminAuth.authorized(app.control_plane.admin.token, headers, ctx.query)
}

@['/health'; get]
pub fn (mut app AdminApp) health(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/health')
	return admin_plane_text_response(mut app, mut ctx, 'GET', req, 200, 'OK', map[string]string{})
}

@['/admin/workers'; get]
pub fn (mut app AdminApp) admin_workers(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/workers')
	if !app.admin_authorized(ctx) {
		return admin_plane_text_response(mut app, mut ctx, 'GET', req, 403, 'Forbidden', {
			'error': 'forbidden'
		})
	}
	body := json.encode(app.shared.worker_admin_snapshot())
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'workers'
	})
}

@['/admin/stats'; get]
pub fn (mut app AdminApp) admin_stats(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/stats')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	body := json.encode(app.shared.admin_stats_snapshot())
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'stats'
	})
}

@['/admin/runtime'; get]
pub fn (mut app AdminApp) admin_runtime(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/runtime')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	body := json.encode(app.shared.admin_runtime_snapshot())
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'runtime'
	})
}

@['/admin/runtime/plan'; get]
pub fn (mut app AdminApp) admin_runtime_plan(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/runtime/plan')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	body := app.shared.protocols.runtime_plan_json
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'runtime_plan'
	})
}

@['/admin/events'; get]
pub fn (mut app AdminApp) admin_events(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/events')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	limit := admin.AdminQuery.limit(ctx.query['limit'] or { '' }, 100, 1000)
	events := app.shared.admin_state_list_events(limit) or {
		return admin_plane_json_response(mut app, mut ctx, 'GET', req, 500, json.encode(admin.AdminErrorResponse{
			error: err.msg()
		}), {
			'admin_endpoint': 'events'
			'error':          err.msg()
		})
	}
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, json.encode(events), {
		'admin_endpoint': 'events'
	})
}

@['/admin/runtime/graph'; get]
pub fn (mut app AdminApp) admin_runtime_graph(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/runtime/graph')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	body := json.encode(app.shared.admin_runtime_graph_snapshot())
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'runtime_graph'
	})
}

@['/admin/apps'; get]
pub fn (mut app AdminApp) admin_apps(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/apps')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	body := json.encode(app.shared.admin_apps_snapshot())
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'apps'
	})
}

@['/admin/applications'; get]
pub fn (mut app AdminApp) admin_applications(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/applications')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	body := json.encode(app.shared.admin_apps_snapshot())
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'applications'
	})
}

@['/admin/sites'; get]
pub fn (mut app AdminApp) admin_sites(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/sites')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	body := json.encode(app.shared.admin_apps_snapshot())
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'sites'
	})
}

@['/admin/schema'; get]
pub fn (mut app AdminApp) admin_schema(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/schema')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200,
		json.encode(admin_schema_catalog()), {
		'admin_endpoint': 'schema'
	})
}

@['/admin/schema/:domain'; get]
pub fn (mut app AdminApp) admin_schema_domain(mut ctx Context, domain string) veb.Result {
	req := admin_plane_request(ctx, '/admin/schema/${domain}')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	item := admin_schema_domain(domain) or {
		return admin_plane_json_response(mut app, mut ctx, 'GET', req, 404, json.encode(admin.AdminErrorResponse{
			error: 'schema_domain_not_found'
		}), {
			'admin_endpoint': 'schema_domain'
			'error':          'schema_domain_not_found'
		})
	}
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, json.encode(item), {
		'admin_endpoint': 'schema_domain'
		'domain':         domain
	})
}

@['/admin/schema/:domain/:kind'; get]
pub fn (mut app AdminApp) admin_schema_kind(mut ctx Context, domain string, kind string) veb.Result {
	req := admin_plane_request(ctx, '/admin/schema/${domain}/${kind}')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	item := admin_schema_kind(domain, kind) or {
		return admin_plane_json_response(mut app, mut ctx, 'GET', req, 404, json.encode(admin.AdminErrorResponse{
			error: 'schema_kind_not_found'
		}), {
			'admin_endpoint': 'schema_kind'
			'error':          'schema_kind_not_found'
		})
	}
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, json.encode(item), {
		'admin_endpoint': 'schema_kind'
		'domain':         domain
		'kind':           kind
	})
}

@['/admin/drafts'; get]
pub fn (mut app AdminApp) admin_drafts(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/drafts')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	drafts := app.shared.admin_state_list_drafts() or {
		return admin_plane_json_response(mut app, mut ctx, 'GET', req, 500, json.encode(admin.AdminErrorResponse{
			error: err.msg()
		}), {
			'admin_endpoint': 'drafts'
			'error':          err.msg()
		})
	}
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, json.encode(drafts), {
		'admin_endpoint': 'drafts'
	})
}

@['/admin/config/files'; get]
pub fn (mut app AdminApp) admin_config_files(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/config/files')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	files := app.shared.admin_state_list_config_files()
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, json.encode(files), {
		'admin_endpoint': 'config_files'
	})
}

@['/admin/config/files/draft'; post]
pub fn (mut app AdminApp) admin_config_file_draft(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/config/files/draft')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'POST', req)
	}
	target_path := (ctx.query['path'] or { ctx.query['include_path'] or { '' } }).trim_space()
	result := app.shared.admin_state_open_config_file_draft(target_path)
	status := if result.ok { 200 } else { 422 }
	return admin_plane_json_response(mut app, mut ctx, 'POST', req, status, json.encode(result), {
		'admin_endpoint': 'config_file_draft'
		'admin_action':   'config_file_draft'
		'draft_id':       result.draft_id
		'error':          result.error
	})
}

@['/admin/drafts'; post]
pub fn (mut app AdminApp) admin_drafts_create(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/drafts')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'POST', req)
	}
	id := ctx.query['id'] or { '' }
	entry := app.shared.admin_state_put_draft(id, ctx.req.data) or {
		return admin_plane_json_response(mut app, mut ctx, 'POST', req, 400, json.encode(admin.AdminErrorResponse{
			error: err.msg()
		}), {
			'admin_endpoint': 'drafts'
			'error':          err.msg()
		})
	}
	return admin_plane_json_response(mut app, mut ctx, 'POST', req, 200, json.encode(entry), {
		'admin_endpoint': 'drafts'
		'admin_action':   'draft_save'
		'draft_id':       entry.key
	})
}

@['/admin/drafts/:id'; get]
pub fn (mut app AdminApp) admin_draft_get(mut ctx Context, id string) veb.Result {
	req := admin_plane_request(ctx, '/admin/drafts/${id}')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	entry := app.shared.admin_state_get_draft(id) or {
		return admin_plane_json_response(mut app, mut ctx, 'GET', req, 404, json.encode(admin.AdminErrorResponse{
			error: err.msg()
		}), {
			'admin_endpoint': 'draft'
			'error':          err.msg()
		})
	}
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, json.encode(entry), {
		'admin_endpoint': 'draft'
		'draft_id':       entry.key
	})
}

@['/admin/drafts/:id'; put]
pub fn (mut app AdminApp) admin_draft_put(mut ctx Context, id string) veb.Result {
	req := admin_plane_request(ctx, '/admin/drafts/${id}')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'PUT', req)
	}
	entry := app.shared.admin_state_put_draft(id, ctx.req.data) or {
		return admin_plane_json_response(mut app, mut ctx, 'PUT', req, 400, json.encode(admin.AdminErrorResponse{
			error: err.msg()
		}), {
			'admin_endpoint': 'draft'
			'error':          err.msg()
		})
	}
	return admin_plane_json_response(mut app, mut ctx, 'PUT', req, 200, json.encode(entry), {
		'admin_endpoint': 'draft'
		'admin_action':   'draft_save'
		'draft_id':       entry.key
	})
}

@['/admin/drafts/:id'; delete]
pub fn (mut app AdminApp) admin_draft_delete(mut ctx Context, id string) veb.Result {
	req := admin_plane_request(ctx, '/admin/drafts/${id}')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'DELETE', req)
	}
	app.shared.admin_state_delete_draft(id) or {
		return admin_plane_json_response(mut app, mut ctx, 'DELETE', req, 400, json.encode(admin.AdminErrorResponse{
			error: err.msg()
		}), {
			'admin_endpoint': 'draft'
			'error':          err.msg()
		})
	}
	return admin_plane_json_response(mut app, mut ctx, 'DELETE', req, 200, json.encode(AdminDraftDeleteResponse{
		ok:       true
		draft_id: id
	}), {
		'admin_endpoint': 'draft'
		'admin_action':   'draft_delete'
		'draft_id':       id
	})
}

@['/admin/runtime/plan/replacement'; get]
pub fn (mut app AdminApp) admin_runtime_plan_replacement(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/runtime/plan/replacement')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	config_path := (ctx.query['config'] or { ctx.query['path'] or { '' } }).trim_space()
	preview := app.shared.preview_runtime_plan_replacement(config_path) or {
		return admin_plane_json_response(mut app, mut ctx, 'GET', req, 400, json.encode({
			'error': err.msg()
		}), {
			'admin_endpoint': 'runtime_plan_replacement'
			'error':          err.msg()
		})
	}
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, json.encode(preview), {
		'admin_endpoint': 'runtime_plan_replacement'
		'allowed':        '${preview.allowed}'
	})
}

@['/admin/runtime/plan/replacement/state'; get]
pub fn (mut app AdminApp) admin_runtime_plan_replacement_state(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/runtime/plan/replacement/state')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	body := json.encode(app.shared.runtime_plan_replacement_snapshot())
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'runtime_plan_replacement_state'
	})
}

@['/admin/runtime/plan/replacement/apply'; post]
pub fn (mut app AdminApp) admin_runtime_plan_replacement_apply(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/runtime/plan/replacement/apply')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'POST', req)
	}
	config_path := (ctx.query['config'] or { ctx.query['path'] or { '' } }).trim_space()
	result := app.shared.apply_runtime_plan_replacement(config_path) or {
		return admin_plane_json_response(mut app, mut ctx, 'POST', req, 400, json.encode({
			'error': err.msg()
		}), {
			'admin_endpoint': 'runtime_plan_replacement_apply'
			'error':          err.msg()
		})
	}
	status := runtime_plan_replacement_apply_status_code(result)
	return admin_plane_json_response(mut app, mut ctx, 'POST', req, status, json.encode(result), {
		'admin_endpoint': 'runtime_plan_replacement_apply'
		'applied':        '${result.applied}'
		'status':         result.status
		'error':          result.error
	})
}

@['/admin/runtime/plan/replacement/finalize'; post]
pub fn (mut app AdminApp) admin_runtime_plan_replacement_finalize(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/runtime/plan/replacement/finalize')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'POST', req)
	}
	result := app.shared.finalize_runtime_plan_replacement()
	status := runtime_plan_replacement_finalize_status_code(result)
	return admin_plane_json_response(mut app, mut ctx, 'POST', req, status, json.encode(result), {
		'admin_endpoint': 'runtime_plan_replacement_finalize'
		'applied':        '${result.applied}'
		'status':         result.status
		'error':          result.error
	})
}

@['/admin/runtime/plan/replacement/cancel'; post]
pub fn (mut app AdminApp) admin_runtime_plan_replacement_cancel(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/runtime/plan/replacement/cancel')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'POST', req)
	}
	result := app.shared.cancel_runtime_plan_replacement()
	status := runtime_plan_replacement_cancel_status_code(result)
	return admin_plane_json_response(mut app, mut ctx, 'POST', req, status, json.encode(result), {
		'admin_endpoint': 'runtime_plan_replacement_cancel'
		'cancelled':      '${result.cancelled}'
		'status':         result.status
		'error':          result.error
	})
}

@['/admin/runtime/transformers'; get]
pub fn (mut app AdminApp) admin_runtime_transformers(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/runtime/transformers')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	body := json.encode(app.shared.transformers.snapshot())
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'runtime_transformers'
	})
}

// New: return registered provider names as a stable admin endpoint so callers
// don't need to parse /admin/runtime wrapper. This keeps API surface small
// and explicit for tooling.
@['/admin/providers'; get]
pub fn (mut app AdminApp) admin_providers(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/providers')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	// provider_names returns []string
	body := json.encode(app.shared.provider_names())
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'providers'
	})
}

@['/admin/executors'; get]
pub fn (mut app AdminApp) admin_executors(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/executors')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	body := json.encode(app.shared.admin_logic_executor_specs_snapshot())
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'executors'
	})
}

@['/admin/providers/specs'; get]
pub fn (mut app AdminApp) admin_provider_specs(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/providers/specs')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	body := json.encode(app.shared.admin_provider_specs_snapshot())
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'provider_specs'
	})
}

@['/admin/providers/runtimes'; get]
pub fn (mut app AdminApp) admin_provider_runtimes(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/providers/runtimes')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	body := json.encode(app.shared.admin_provider_runtimes_snapshot())
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'provider_runtimes'
	})
}

@['/admin/runtime/upstreams'; get]
pub fn (mut app AdminApp) admin_runtime_upstreams(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/runtime/upstreams')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	details := admin.AdminQuery.parse_boolish(ctx.query['details'] or { 'false' })
	limit := admin.AdminQuery.limit(ctx.query['limit'] or { '' }, 100, 1000)
	offset := admin.AdminQuery.offset(ctx.query['offset'] or { '' })
	role_filter := (ctx.query['role'] or { '' }).trim_space()
	provider_filter := (ctx.query['provider'] or { '' }).trim_space()
	body := json.encode(app.shared.admin_upstreams_snapshot(details, limit, offset, role_filter,
		provider_filter))
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'runtime_upstreams'
	})
}

@['/admin/runtime/websockets'; get]
pub fn (mut app AdminApp) admin_runtime_websockets(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/runtime/websockets')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	details := admin.AdminQuery.parse_boolish(ctx.query['details'] or { 'false' })
	limit := admin.AdminQuery.limit(ctx.query['limit'] or { '' }, 100, 1000)
	offset := admin.AdminQuery.offset(ctx.query['offset'] or { '' })
	room_filter := (ctx.query['room'] or { '' }).trim_space()
	conn_filter := (ctx.query['conn_id'] or { '' }).trim_space()
	body := json.encode(app.shared.websocket.snapshot(details, limit, offset, room_filter,
		conn_filter))
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'runtime_websockets'
	})
}

@['/admin/runtime/mcp'; get]
pub fn (mut app AdminApp) admin_runtime_mcp(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/runtime/mcp')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	details := admin.AdminQuery.parse_boolish(ctx.query['details'] or { 'false' })
	limit := admin.AdminQuery.limit(ctx.query['limit'] or { '' }, 100, 1000)
	offset := admin.AdminQuery.offset(ctx.query['offset'] or { '' })
	session_filter := (ctx.query['session_id'] or { '' }).trim_space()
	protocol_filter := (ctx.query['protocol_version'] or { '' }).trim_space()
	body := json.encode(app.shared.protocols.mcp.snapshot(details, limit, offset, session_filter,
		protocol_filter))
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'runtime_mcp'
	})
}

@['/admin/runtime/provider-instances'; get]
pub fn (mut app AdminApp) admin_runtime_provider_instances(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/runtime/provider-instances')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	provider_filter := (ctx.query['provider'] or { '' }).trim_space()
	body := json.encode(app.shared.admin_provider_instance_snapshots(provider_filter))
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'runtime_provider_instances'
	})
}

@['/admin/runtime/provider-instances'; post]
pub fn (mut app AdminApp) admin_runtime_provider_instance_upsert(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/runtime/provider-instances')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'POST', req)
	}
	result := app.shared.admin_provider_instance_upsert_from_body(ctx.req.data) or {
		status := if err.msg() == 'invalid_json' || err.msg() == 'missing_provider' {
			400
		} else {
			422
		}
		return admin_plane_json_response(mut app, mut ctx, 'POST', req, status, json.encode(admin.AdminErrorResponse{
			error: err.msg()
		}), {
			'admin_endpoint': 'runtime_provider_instances'
			'admin_action':   'provider_instance_upsert'
			'error':          err.msg()
		})
	}
	return admin_plane_json_response(mut app, mut ctx, 'POST', req, 200, json.encode(result), {
		'admin_endpoint': 'runtime_provider_instances'
		'admin_action':   'provider_instance_upsert'
		'provider':       result.snapshot.provider
		'instance':       result.snapshot.instance
	})
}

@['/admin/runtime/events'; post]
pub fn (mut app AdminApp) admin_runtime_events_dispatch(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/runtime/events')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'POST', req)
	}
	result := app.shared.dispatch_runtime_event(ctx.req.data, req.req_id, req.trace_id) or {
		return admin_plane_json_response(mut app, mut ctx, 'POST', req, 400, json.encode(admin.AdminErrorResponse{
			error: err.msg()
		}), {
			'admin_endpoint': 'runtime_events'
			'admin_action':   'event_dispatch'
			'error':          err.msg()
		})
	}
	return admin_plane_json_response(mut app, mut ctx, 'POST', req, 202, json.encode(result), {
		'admin_endpoint': 'runtime_events'
		'admin_action':   'event_dispatch'
		'pipeline':       result.pipeline
		'ingress':        result.ingress
		'event':          result.name
	})
}

@['/admin/runtime/feishu'; get]
pub fn (mut app AdminApp) admin_runtime_feishu(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/runtime/feishu')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	body := app.shared.provider_runtime_snapshot('feishu') or { '{}' }
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'runtime_feishu'
	})
}

@['/admin/runtime/codex'; get]
pub fn (mut app AdminApp) admin_runtime_codex(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/runtime/codex')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	body := app.shared.provider_runtime_snapshot('codex') or { '{}' }
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'runtime_codex'
	})
}

@['/admin/runtime/db'; get]
pub fn (mut app AdminApp) admin_runtime_db(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/runtime/db')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	body := app.shared.provider_runtime_snapshot('db') or { '{}' }
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'runtime_db'
	})
}

@['/admin/runtime/cache'; get]
pub fn (mut app AdminApp) admin_runtime_cache(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/runtime/cache')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	body := app.shared.provider_runtime_snapshot('cache') or { '{}' }
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'runtime_cache'
	})
}

@['/admin/runtime/feishu/chats'; get]
pub fn (mut app AdminApp) admin_runtime_feishu_chats(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/runtime/feishu/chats')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	limit := admin.AdminQuery.limit(ctx.query['limit'] or { '' }, 100, 1000)
	offset := admin.AdminQuery.offset(ctx.query['offset'] or { '' })
	instance_filter := (ctx.query['instance'] or { '' }).trim_space()
	chat_type_filter := (ctx.query['chat_type'] or { '' }).trim_space()
	chat_id_filter := (ctx.query['chat_id'] or { '' }).trim_space()
	body := json.encode(app.shared.providers.feishu.chats_snapshot(limit, offset, instance_filter,
		chat_type_filter, chat_id_filter))
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'runtime_feishu_chats'
	})
}

@['/admin/runtime/feishu/messages'; post]
pub fn (mut app AdminApp) admin_runtime_feishu_send(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/runtime/feishu/messages')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'POST', req)
	}
	send_req := json.decode(feishu.SendMessageRequest, ctx.req.data) or {
		return admin_plane_json_response(mut app, mut ctx, 'POST', req, 400, json.encode(admin.AdminErrorResponse{
			error: 'invalid_json'
		}), {
			'admin_endpoint': 'runtime_feishu_messages'
			'error':          'invalid_json'
		})
	}
	result := app.shared.providers.feishu_provider_runtime_send_message(send_req, mut app.shared) or {
		return admin_plane_json_response(mut app, mut ctx, 'POST', req, 502, json.encode(admin.AdminFeishuSendResponse{
			ok:    false
			error: err.msg()
		}), {
			'admin_endpoint': 'runtime_feishu_messages'
			'error':          err.msg()
		})
	}
	return admin_plane_json_response(mut app, mut ctx, 'POST', req, 200, json.encode(admin.AdminFeishuSendResponse{
		ok:         true
		message_id: result.message_id
	}), {
		'admin_endpoint': 'runtime_feishu_messages'
	})
}

@['/admin/workers/restart'; post]
pub fn (mut app AdminApp) admin_restart_worker(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/workers/restart')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'POST', req)
	}
	id_raw := (ctx.query['id'] or { '' }).trim_space()
	if id_raw == '' {
		return admin_plane_json_response(mut app, mut ctx, 'POST', req, 400, json.encode(admin.AdminErrorResponse{
			error: 'missing worker id, use ?id=<worker_id>'
		}), {
			'admin_endpoint': 'workers_restart'
			'error':          'missing_worker_id'
		})
	}
	worker_id := id_raw.int()
	status := app.shared.restart_worker_by_id(worker_id) or {
		return admin_plane_json_response(mut app, mut ctx, 'POST', req, 404, json.encode(admin.AdminErrorResponse{
			error: err.msg()
		}), {
			'admin_endpoint': 'workers_restart'
			'error':          err.msg()
		})
	}
	body := json.encode(admin.AdminRestartSingleResponse{
		ok:     true
		mode:   'single'
		worker: status
	})
	app.shared.emit('admin.worker.restart', {
		'request_id': req.req_id
		'trace_id':   req.trace_id
		'mode':       'single'
		'worker_id':  '${worker_id}'
	})
	return admin_plane_json_response(mut app, mut ctx, 'POST', req, 200, body, {
		'admin_endpoint': 'workers_restart'
		'admin_action':   'worker_restart'
	})
}

@['/admin/workers/restart/all'; post]
pub fn (mut app AdminApp) admin_restart_all_workers(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/workers/restart/all')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'POST', req)
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
		'request_id': req.req_id
		'trace_id':   req.trace_id
		'mode':       'all'
		'restarted':  '${restarted}'
	})
	return admin_plane_json_response(mut app, mut ctx, 'POST', req, 200, body, {
		'admin_endpoint': 'workers_restart_all'
		'admin_action':   'worker_restart_all'
	})
}

@['/admin/workers/drain'; post]
pub fn (mut app AdminApp) admin_drain_workers(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/workers/drain')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'POST', req)
	}
	engine := (ctx.query['engine'] or { ctx.query['kind'] or { '' } }).trim_space()
	status := app.shared.drain_engine(engine) or {
		return admin_plane_json_response(mut app, mut ctx, 'POST', req, 404, json.encode(admin.AdminErrorResponse{
			error: err.msg()
		}), {
			'admin_endpoint': 'workers_drain'
			'error':          err.msg()
		})
	}
	return admin_plane_json_response(mut app, mut ctx, 'POST', req, 200, json.encode(status), {
		'admin_endpoint':    'workers_drain'
		'admin_action':      'worker_drain'
		'engine':            status.engine
		'draining_count':    '${status.draining_count}'
		'inflight_requests': '${status.inflight_requests}'
	})
}

@['/admin/drafts/:id/validate'; post]
pub fn (mut app AdminApp) admin_draft_validate(mut ctx Context, id string) veb.Result {
	req := admin_plane_request(ctx, '/admin/drafts/${id}/validate')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'POST', req)
	}
	result := app.shared.admin_state_validate_draft(id)
	status := if result.ok { 200 } else { 422 }
	return admin_plane_json_response(mut app, mut ctx, 'POST', req, status, json.encode(result), {
		'admin_endpoint': 'draft_validate'
		'draft_id':       id
		'ok':             '${result.ok}'
		'error':          result.error
	})
}

@['/admin/drafts/:id/diff'; get]
pub fn (mut app AdminApp) admin_draft_diff(mut ctx Context, id string) veb.Result {
	req := admin_plane_request(ctx, '/admin/drafts/${id}/diff')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'GET', req)
	}
	preview := app.shared.admin_state_diff_draft(id) or {
		return admin_plane_json_response(mut app, mut ctx, 'GET', req, 422, json.encode(admin.AdminErrorResponse{
			error: err.msg()
		}), {
			'admin_endpoint': 'draft_diff'
			'draft_id':       id
			'error':          err.msg()
		})
	}
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, json.encode(preview), {
		'admin_endpoint': 'draft_diff'
		'draft_id':       id
		'allowed':        '${preview.allowed}'
		'strategy':       preview.strategy
	})
}

@['/admin/drafts/:id/publish'; post]
pub fn (mut app AdminApp) admin_draft_publish(mut ctx Context, id string) veb.Result {
	req := admin_plane_request(ctx, '/admin/drafts/${id}/publish')
	if !app.admin_authorized(ctx) {
		return admin_plane_forbidden(mut app, mut ctx, 'POST', req)
	}
	target_path := (ctx.query['path'] or { ctx.query['include_path'] or { '' } }).trim_space()
	result := app.shared.admin_state_publish_draft(id, target_path)
	status := if result.ok { 200 } else { 422 }
	return admin_plane_json_response(mut app, mut ctx, 'POST', req, status, json.encode(result), {
		'admin_endpoint': 'draft_publish'
		'admin_action':   'draft_publish'
		'draft_id':       id
		'ok':             '${result.ok}'
		'error':          result.error
	})
}

fn run_admin_server(mut shared_app App, host string, port int, token string) {
	mut admin_app := &AdminApp{
		admin_host:  host
		admin_port:  port
		admin_token: token
		shared:      unsafe { shared_app }
	}
	admin_app.mount_static_folder_at(admin_ui_dir_path(), '/admin/ui') or {
		log.error('admin ui mount failed: ${err}')
	}
	admin_app.serve_static('/admin/ui', admin_ui_file_path('index.html')) or {
		log.error('admin ui index alias failed: ${err}')
	}
	admin_app.serve_static('/', admin_ui_file_path('index.html')) or {
		log.error('admin ui root alias failed: ${err}')
	}
	admin_app.serve_static('/admin/ui/app', admin_ui_file_path('app.js')) or {
		log.error('admin ui app alias failed: ${err}')
	}
	admin_app.serve_static('/admin/ui/style', admin_ui_file_path('style.css')) or {
		log.error('admin ui style alias failed: ${err}')
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
