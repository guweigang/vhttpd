module main

import admin
import json
import veb

@['/admin/runtime'; get]
pub fn (mut app App) admin_runtime(mut ctx Context) veb.Result {
	req := admin_data_plane_request(ctx, '/admin/runtime')
	if !app.control_plane.admin.on_data_plane {
		return admin_data_plane_text(mut app, mut ctx, 'GET', req, 404, 'Not Found', {
			'admin_endpoint': 'runtime'
			'error':          'not_found'
		})
	}
	body := json.encode(app.admin_runtime_snapshot())
	return admin_data_plane_json(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'runtime'
	})
}

@['/admin/runtime/plan'; get]
pub fn (mut app App) admin_runtime_plan(mut ctx Context) veb.Result {
	req := admin_data_plane_request(ctx, '/admin/runtime/plan')
	if !app.control_plane.admin.on_data_plane {
		return admin_data_plane_text(mut app, mut ctx, 'GET', req, 404, 'Not Found', {
			'admin_endpoint': 'runtime_plan'
			'error':          'not_found'
		})
	}
	body := app.protocols.runtime_plan_json
	return admin_data_plane_json(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'runtime_plan'
	})
}

@['/admin/runtime/plan/replacement'; get]
pub fn (mut app App) admin_runtime_plan_replacement(mut ctx Context) veb.Result {
	req := admin_data_plane_request(ctx, '/admin/runtime/plan/replacement')
	if !app.control_plane.admin.on_data_plane {
		return admin_data_plane_text(mut app, mut ctx, 'GET', req, 404, 'Not Found', {
			'admin_endpoint': 'runtime_plan_replacement'
			'error':          'not_found'
		})
	}
	config_path := (ctx.query['config'] or { ctx.query['path'] or { '' } }).trim_space()
	preview := app.preview_runtime_plan_replacement(config_path) or {
		return admin_data_plane_json(mut app, mut ctx, 'GET', req, 400, json.encode({
			'error': err.msg()
		}), {
			'admin_endpoint': 'runtime_plan_replacement'
			'error':          err.msg()
		})
	}
	return admin_data_plane_json(mut app, mut ctx, 'GET', req, 200, json.encode(preview), {
		'admin_endpoint': 'runtime_plan_replacement'
		'allowed':        '${preview.allowed}'
	})
}

@['/admin/runtime/plan/replacement/state'; get]
pub fn (mut app App) admin_runtime_plan_replacement_state(mut ctx Context) veb.Result {
	req := admin_data_plane_request(ctx, '/admin/runtime/plan/replacement/state')
	if !app.control_plane.admin.on_data_plane {
		return admin_data_plane_text(mut app, mut ctx, 'GET', req, 404, 'Not Found', {
			'admin_endpoint': 'runtime_plan_replacement_state'
			'error':          'not_found'
		})
	}
	body := json.encode(app.runtime_plan_replacement_snapshot())
	return admin_data_plane_json(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'runtime_plan_replacement_state'
	})
}

@['/admin/runtime/plan/replacement/apply'; post]
pub fn (mut app App) admin_runtime_plan_replacement_apply(mut ctx Context) veb.Result {
	req := admin_data_plane_request(ctx, '/admin/runtime/plan/replacement/apply')
	if !app.control_plane.admin.on_data_plane {
		return admin_data_plane_text(mut app, mut ctx, 'POST', req, 404, 'Not Found', {
			'admin_endpoint': 'runtime_plan_replacement_apply'
			'error':          'not_found'
		})
	}
	config_path := (ctx.query['config'] or { ctx.query['path'] or { '' } }).trim_space()
	result := app.apply_runtime_plan_replacement(config_path) or {
		return admin_data_plane_json(mut app, mut ctx, 'POST', req, 400, json.encode({
			'error': err.msg()
		}), {
			'admin_endpoint': 'runtime_plan_replacement_apply'
			'error':          err.msg()
		})
	}
	status := runtime_plan_replacement_apply_status_code(result)
	return admin_data_plane_json(mut app, mut ctx, 'POST', req, status, json.encode(result), {
		'admin_endpoint': 'runtime_plan_replacement_apply'
		'applied':        '${result.applied}'
		'status':         result.status
		'error':          result.error
	})
}

@['/admin/runtime/plan/replacement/finalize'; post]
pub fn (mut app App) admin_runtime_plan_replacement_finalize(mut ctx Context) veb.Result {
	req := admin_data_plane_request(ctx, '/admin/runtime/plan/replacement/finalize')
	if !app.control_plane.admin.on_data_plane {
		return admin_data_plane_text(mut app, mut ctx, 'POST', req, 404, 'Not Found', {
			'admin_endpoint': 'runtime_plan_replacement_finalize'
			'error':          'not_found'
		})
	}
	result := app.finalize_runtime_plan_replacement()
	status := runtime_plan_replacement_finalize_status_code(result)
	return admin_data_plane_json(mut app, mut ctx, 'POST', req, status, json.encode(result), {
		'admin_endpoint': 'runtime_plan_replacement_finalize'
		'applied':        '${result.applied}'
		'status':         result.status
		'error':          result.error
	})
}

@['/admin/runtime/plan/replacement/cancel'; post]
pub fn (mut app App) admin_runtime_plan_replacement_cancel(mut ctx Context) veb.Result {
	req := admin_data_plane_request(ctx, '/admin/runtime/plan/replacement/cancel')
	if !app.control_plane.admin.on_data_plane {
		return admin_data_plane_text(mut app, mut ctx, 'POST', req, 404, 'Not Found', {
			'admin_endpoint': 'runtime_plan_replacement_cancel'
			'error':          'not_found'
		})
	}
	result := app.cancel_runtime_plan_replacement()
	status := runtime_plan_replacement_cancel_status_code(result)
	return admin_data_plane_json(mut app, mut ctx, 'POST', req, status, json.encode(result), {
		'admin_endpoint': 'runtime_plan_replacement_cancel'
		'cancelled':      '${result.cancelled}'
		'status':         result.status
		'error':          result.error
	})
}

@['/admin/runtime/transformers'; get]
pub fn (mut app App) admin_runtime_transformers(mut ctx Context) veb.Result {
	req := admin_data_plane_request(ctx, '/admin/runtime/transformers')
	if !app.control_plane.admin.on_data_plane {
		return admin_data_plane_text(mut app, mut ctx, 'GET', req, 404, 'Not Found', {
			'admin_endpoint': 'runtime_transformers'
			'error':          'not_found'
		})
	}
	body := json.encode(app.transformers.snapshot())
	return admin_data_plane_json(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'runtime_transformers'
	})
}

@['/admin/runtime/upstreams'; get]
pub fn (mut app App) admin_runtime_upstreams(mut ctx Context) veb.Result {
	req := admin_data_plane_request(ctx, '/admin/runtime/upstreams')
	if !app.control_plane.admin.on_data_plane {
		return admin_data_plane_text(mut app, mut ctx, 'GET', req, 404, 'Not Found', {
			'admin_endpoint': 'runtime_upstreams'
			'error':          'not_found'
		})
	}
	details := admin.AdminQuery.parse_boolish(ctx.query['details'] or { 'false' })
	limit := admin.AdminQuery.limit(ctx.query['limit'] or { '' }, 100, 1000)
	offset := admin.AdminQuery.offset(ctx.query['offset'] or { '' })
	role_filter := (ctx.query['role'] or { '' }).trim_space()
	provider_filter := (ctx.query['provider'] or { '' }).trim_space()
	body := json.encode(app.admin_upstreams_snapshot(details, limit, offset, role_filter,
		provider_filter))
	return admin_data_plane_json(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'runtime_upstreams'
	})
}

@['/admin/runtime/websockets'; get]
pub fn (mut app App) admin_runtime_websockets(mut ctx Context) veb.Result {
	req := admin_data_plane_request(ctx, '/admin/runtime/websockets')
	if !app.control_plane.admin.on_data_plane {
		return admin_data_plane_text(mut app, mut ctx, 'GET', req, 404, 'Not Found', {
			'admin_endpoint': 'runtime_websockets'
			'error':          'not_found'
		})
	}
	details := admin.AdminQuery.parse_boolish(ctx.query['details'] or { 'false' })
	limit := admin.AdminQuery.limit(ctx.query['limit'] or { '' }, 100, 1000)
	offset := admin.AdminQuery.offset(ctx.query['offset'] or { '' })
	room_filter := (ctx.query['room'] or { '' }).trim_space()
	conn_filter := (ctx.query['conn_id'] or { '' }).trim_space()
	body := json.encode(app.websocket.snapshot(details, limit, offset, room_filter, conn_filter))
	return admin_data_plane_json(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'runtime_websockets'
	})
}

@['/admin/runtime/mcp'; get]
pub fn (mut app App) admin_runtime_mcp(mut ctx Context) veb.Result {
	req := admin_data_plane_request(ctx, '/admin/runtime/mcp')
	if !app.control_plane.admin.on_data_plane {
		return admin_data_plane_text(mut app, mut ctx, 'GET', req, 404, 'Not Found', {
			'admin_endpoint': 'runtime_mcp'
			'error':          'not_found'
		})
	}
	details := admin.AdminQuery.parse_boolish(ctx.query['details'] or { 'false' })
	limit := admin.AdminQuery.limit(ctx.query['limit'] or { '' }, 100, 1000)
	offset := admin.AdminQuery.offset(ctx.query['offset'] or { '' })
	session_filter := (ctx.query['session_id'] or { '' }).trim_space()
	protocol_filter := (ctx.query['protocol_version'] or { '' }).trim_space()
	body := json.encode(app.protocols.mcp.snapshot(details, limit, offset, session_filter,
		protocol_filter))
	return admin_data_plane_json(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'runtime_mcp'
	})
}

@['/admin/runtime/provider-instances'; get]
pub fn (mut app App) admin_runtime_provider_instances(mut ctx Context) veb.Result {
	req := admin_data_plane_request(ctx, '/admin/runtime/provider-instances')
	if !app.control_plane.admin.on_data_plane {
		return admin_data_plane_text(mut app, mut ctx, 'GET', req, 404, 'Not Found', {
			'admin_endpoint': 'runtime_provider_instances'
			'error':          'not_found'
		})
	}
	provider_filter := (ctx.query['provider'] or { '' }).trim_space()
	body := json.encode(app.admin_provider_instance_snapshots(provider_filter))
	return admin_data_plane_json(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'runtime_provider_instances'
	})
}

@['/admin/runtime/provider-instances'; post]
pub fn (mut app App) admin_runtime_provider_instance_upsert(mut ctx Context) veb.Result {
	req := admin_data_plane_request(ctx, '/admin/runtime/provider-instances')
	if !app.control_plane.admin.on_data_plane {
		return admin_data_plane_text(mut app, mut ctx, 'POST', req, 404, 'Not Found', {
			'admin_endpoint': 'runtime_provider_instances'
			'error':          'not_found'
		})
	}
	result := app.admin_provider_instance_upsert_from_body(ctx.req.data) or {
		status := if err.msg() == 'invalid_json' || err.msg() == 'missing_provider' {
			400
		} else {
			422
		}
		return admin_data_plane_json(mut app, mut ctx, 'POST', req, status, json.encode({
			'error': err.msg()
		}), {
			'admin_endpoint': 'runtime_provider_instances'
			'admin_action':   'provider_instance_upsert'
			'error':          err.msg()
		})
	}
	return admin_data_plane_json(mut app, mut ctx, 'POST', req, 200, json.encode(result), {
		'admin_endpoint': 'runtime_provider_instances'
		'admin_action':   'provider_instance_upsert'
		'provider':       result.snapshot.provider
		'instance':       result.snapshot.instance
	})
}

@['/admin/runtime/events'; post]
pub fn (mut app App) admin_runtime_events_dispatch(mut ctx Context) veb.Result {
	req := admin_data_plane_request(ctx, '/admin/runtime/events')
	if !app.control_plane.admin.on_data_plane {
		return admin_data_plane_text(mut app, mut ctx, 'POST', req, 404, 'Not Found', {
			'admin_endpoint': 'runtime_events'
			'error':          'not_found'
		})
	}
	result := app.dispatch_runtime_event(ctx.req.data, req.req_id, req.trace_id) or {
		return admin_data_plane_json(mut app, mut ctx, 'POST', req, 400, json.encode({
			'error': err.msg()
		}), {
			'admin_endpoint': 'runtime_events'
			'admin_action':   'event_dispatch'
			'error':          err.msg()
		})
	}
	return admin_data_plane_json(mut app, mut ctx, 'POST', req, 202, json.encode(result), {
		'admin_endpoint': 'runtime_events'
		'admin_action':   'event_dispatch'
		'pipeline':       result.pipeline
		'ingress':        result.ingress
		'event':          result.name
	})
}

@['/admin/runtime/codex'; get]
pub fn (mut app App) admin_runtime_codex(mut ctx Context) veb.Result {
	req := admin_data_plane_request(ctx, '/admin/runtime/codex')
	if !app.control_plane.admin.on_data_plane {
		return admin_data_plane_text(mut app, mut ctx, 'GET', req, 404, 'Not Found', {
			'admin_endpoint': 'runtime_codex'
			'error':          'not_found'
		})
	}
	body := app.provider_runtime_snapshot('codex') or { '{}' }
	return admin_data_plane_json(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'runtime_codex'
	})
}

@['/admin/runtime/feishu'; get]
pub fn (mut app App) admin_runtime_feishu(mut ctx Context) veb.Result {
	req := admin_data_plane_request(ctx, '/admin/runtime/feishu')
	if !app.control_plane.admin.on_data_plane {
		return admin_data_plane_text(mut app, mut ctx, 'GET', req, 404, 'Not Found', {
			'admin_endpoint': 'runtime_feishu'
			'error':          'not_found'
		})
	}
	body := app.provider_runtime_snapshot('feishu') or { '{}' }
	return admin_data_plane_json(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'runtime_feishu'
	})
}

@['/admin/runtime/db'; get]
pub fn (mut app App) admin_runtime_db(mut ctx Context) veb.Result {
	req := admin_data_plane_request(ctx, '/admin/runtime/db')
	if !app.control_plane.admin.on_data_plane {
		return admin_data_plane_text(mut app, mut ctx, 'GET', req, 404, 'Not Found', {
			'admin_endpoint': 'runtime_db'
			'error':          'not_found'
		})
	}
	body := app.provider_runtime_snapshot('db') or { '{}' }
	return admin_data_plane_json(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'runtime_db'
	})
}

@['/admin/runtime/cache'; get]
pub fn (mut app App) admin_runtime_cache(mut ctx Context) veb.Result {
	req := admin_data_plane_request(ctx, '/admin/runtime/cache')
	if !app.control_plane.admin.on_data_plane {
		return admin_data_plane_text(mut app, mut ctx, 'GET', req, 404, 'Not Found', {
			'admin_endpoint': 'runtime_cache'
			'error':          'not_found'
		})
	}
	body := app.provider_runtime_snapshot('cache') or { '{}' }
	return admin_data_plane_json(mut app, mut ctx, 'GET', req, 200, body, {
		'admin_endpoint': 'runtime_cache'
	})
}
