module main

import admin
import executor
import json
import veb

// build_admin_context constructs an admin.RuntimeContext whose closures
// capture App, bridging the admin sub-module to the main program.
fn (mut app App) build_admin_context() admin.RuntimeContext {
	return admin.RuntimeContext{
		started_at_unix:                        fn [app] () i64 {
			return app.started_at_unix
		}
		http_requests_total:                    fn [app] () i64 {
			return app.http_stats.requests_total
		}
		http_errors_total:                      fn [app] () i64 {
			return app.http_stats.errors_total
		}
		http_timeouts_total:                    fn [app] () i64 {
			return app.http_stats.timeouts_total
		}
		http_streams_total:                     fn [app] () i64 {
			return app.http_stats.streams_total
		}
		http_admin_actions_total:               fn [app] () i64 {
			return app.http_stats.admin_actions_total
		}
		worker_queue_waits_total:               fn [app] () i64 {
			return app.worker.stat_queue_waits_total
		}
		worker_queue_rejected_total:            fn [app] () i64 {
			return app.worker.stat_queue_rejected_total
		}
		worker_queue_timeouts_total:            fn [app] () i64 {
			return app.worker.stat_queue_timeouts_total
		}
		ws_hub_upstream_plans_total:            fn [app] () i64 {
			return app.ws_hub.stat_upstream_plans_total
		}
		ws_hub_upstream_plan_errors_total:      fn [app] () i64 {
			return app.ws_hub.stat_upstream_plan_errors_total
		}
		mcp_sessions_expired_total:             fn [app] () i64 {
			return app.mcp.stat_sessions_expired_total
		}
		mcp_sessions_evicted_total:             fn [app] () i64 {
			return app.mcp.stat_sessions_evicted_total
		}
		mcp_pending_dropped_total:              fn [app] () i64 {
			return app.mcp.stat_pending_dropped_total
		}
		mcp_sampling_capability_warnings_total: fn [app] () i64 {
			return app.mcp.stat_sampling_capability_warnings_total
		}
		mcp_sampling_capability_dropped_total:  fn [app] () i64 {
			return app.mcp.stat_sampling_capability_dropped_total
		}
		mcp_sampling_capability_errors_total:   fn [app] () i64 {
			return app.mcp.stat_sampling_capability_errors_total
		}
		feishu_runtime_totals:                  fn [mut app] () (i64, i64, i64, i64, i64, i64) {
			return app.feishu_runtime_totals()
		}
		ws_hub_active_conns:                    fn [app] () int {
			app.ws_hub.mu.@lock()
			defer { app.ws_hub.mu.unlock() }
			return app.ws_hub.conns.len
		}
		ws_hub_active_upstreams:                fn [app] () int {
			app.ws_hub.upstream_mu.@lock()
			defer { app.ws_hub.upstream_mu.unlock() }
			return app.ws_hub.upstream_sessions.len
		}
		mcp_active_sessions:                    fn [mut app] (now i64) int {
			app.mcp.mu.@lock()
			defer { app.mcp.mu.unlock() }
			app.mcp.prune_sessions_locked(now)
			return app.mcp.sessions.len
		}
		worker_queue_depth:                     fn [app] () int {
			app.worker.mu.@lock()
			defer { app.worker.mu.unlock() }
			return app.worker.worker_backend.queue_waiting_requests
		}
		worker_pool_size:                       fn [app] () i64 {
			return app.worker.worker_backend.sockets.len
		}
		worker_backend_mode:                    fn [app] () string {
			return '${app.worker.worker_backend_mode}'
		}
		worker_queue_capacity:                  fn [app] () int {
			return app.worker.worker_backend.queue_capacity
		}
		worker_queue_timeout_ms:                fn [app] () int {
			return app.worker.worker_backend.queue_timeout_ms
		}
		worker_stream_dispatch:                 fn [app] () bool {
			return app.worker.stream_dispatch
		}
		ws_hub_dispatch_mode:                   fn [app] () bool {
			return app.ws_hub.dispatch_mode
		}
		worker_lifecycle:                       fn [app] () string {
			return app.worker.lifecycle
		}
		logic_executor_admin_details:           fn [app] () executor.LogicExecutorAdminDetails {
			return app.logic_executor_admin_details()
		}
		logic_executor_kind:                    fn [app] () string {
			return app.logic_executor_kind()
		}
		logic_executor_model:                   fn [app] () executor.LogicExecutorModel {
			return app.logic_executor_model()
		}
		logic_executor_provider:                fn [app] () string {
			return app.logic_executor_provider()
		}
		provider_runtime_capabilities:          fn [mut app] () map[string]bool {
			return app.provider_runtime_capabilities()
		}
		provider_runtime_gateway_count:         fn [mut app] () int {
			return app.provider_runtime_gateway_count()
		}
	}
}

fn (mut app App) admin_stats_snapshot() executor.AdminRuntimeStats {
	app.mu.@lock()
	defer { app.mu.unlock() }
	ctx := app.build_admin_context()
	return app.admin.stats_snapshot(ctx)
}

fn (mut app App) admin_runtime_snapshot() executor.AdminRuntimeSummary {
	ctx := app.build_admin_context()
	return app.admin.runtime_snapshot(ctx)
}

@['/admin/runtime'; get]
pub fn (mut app App) admin_runtime(mut ctx Context) veb.Result {
	if !app.admin.on_data_plane {
		ctx.res.set_status(.not_found)
		return ctx.text('Not Found')
	}
	path := if ctx.req.url == '' { '/admin/runtime' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	body := json.encode(app.admin_runtime_snapshot())
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {} // safe to ignore: client may have disconnected
	ctx.set_content_type('application/json; charset=utf-8')
	app.emit('http.request', {
		'method':     'GET'
		'path':       '/admin/runtime'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
	})
	return ctx.text(body)
}

@['/admin/runtime/upstreams'; get]
pub fn (mut app App) admin_runtime_upstreams(mut ctx Context) veb.Result {
	if !app.admin.on_data_plane {
		ctx.res.set_status(.not_found)
		return ctx.text('Not Found')
	}
	path := if ctx.req.url == '' { '/admin/runtime/upstreams' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	details := admin.AdminQuery.parse_boolish(ctx.query['details'] or { 'false' })
	limit := admin.AdminQuery.limit(ctx.query['limit'] or { '' }, 100, 1000)
	offset := admin.AdminQuery.offset(ctx.query['offset'] or { '' })
	role_filter := (ctx.query['role'] or { '' }).trim_space()
	provider_filter := (ctx.query['provider'] or { '' }).trim_space()
	body := json.encode(app.admin_upstreams_snapshot(details, limit, offset, role_filter,
		provider_filter))
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {} // safe to ignore: client may have disconnected
	ctx.set_content_type('application/json; charset=utf-8')
	app.emit('http.request', {
		'method':     'GET'
		'path':       '/admin/runtime/upstreams'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
	})
	return ctx.text(body)
}

@['/admin/runtime/websockets'; get]
pub fn (mut app App) admin_runtime_websockets(mut ctx Context) veb.Result {
	if !app.admin.on_data_plane {
		ctx.res.set_status(.not_found)
		return ctx.text('Not Found')
	}
	path := if ctx.req.url == '' { '/admin/runtime/websockets' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	details := admin.AdminQuery.parse_boolish(ctx.query['details'] or { 'false' })
	limit := admin.AdminQuery.limit(ctx.query['limit'] or { '' }, 100, 1000)
	offset := admin.AdminQuery.offset(ctx.query['offset'] or { '' })
	room_filter := (ctx.query['room'] or { '' }).trim_space()
	conn_filter := (ctx.query['conn_id'] or { '' }).trim_space()
	body := json.encode(app.admin_websockets_snapshot(details, limit, offset, room_filter,
		conn_filter))
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {} // safe to ignore: client may have disconnected
	ctx.set_content_type('application/json; charset=utf-8')
	app.emit('http.request', {
		'method':     'GET'
		'path':       '/admin/runtime/websockets'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
	})
	return ctx.text(body)
}

@['/admin/runtime/mcp'; get]
pub fn (mut app App) admin_runtime_mcp(mut ctx Context) veb.Result {
	if !app.admin.on_data_plane {
		ctx.res.set_status(.not_found)
		return ctx.text('Not Found')
	}
	path := if ctx.req.url == '' { '/admin/runtime/mcp' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	details := admin.AdminQuery.parse_boolish(ctx.query['details'] or { 'false' })
	limit := admin.AdminQuery.limit(ctx.query['limit'] or { '' }, 100, 1000)
	offset := admin.AdminQuery.offset(ctx.query['offset'] or { '' })
	session_filter := (ctx.query['session_id'] or { '' }).trim_space()
	protocol_filter := (ctx.query['protocol_version'] or { '' }).trim_space()
	body := json.encode(app.mcp.snapshot(details, limit, offset, session_filter,
		protocol_filter))
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {} // safe to ignore: client may have disconnected
	ctx.set_content_type('application/json; charset=utf-8')
	app.emit('http.request', {
		'method':     'GET'
		'path':       '/admin/runtime/mcp'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
	})
	return ctx.text(body)
}

@['/admin/runtime/provider-instances'; get]
pub fn (mut app App) admin_runtime_provider_instances(mut ctx Context) veb.Result {
	if !app.admin.on_data_plane {
		ctx.res.set_status(.not_found)
		return ctx.text('Not Found')
	}
	path := if ctx.req.url == '' { '/admin/runtime/provider-instances' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	provider_filter := (ctx.query['provider'] or { '' }).trim_space()
	body := json.encode(app.admin_provider_instance_snapshots(provider_filter))
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {} // safe to ignore: client may have disconnected
	ctx.set_content_type('application/json; charset=utf-8')
	app.emit('http.request', {
		'method':     'GET'
		'path':       '/admin/runtime/provider-instances'
		'status':     '200'
		'request_id': req_id
		'trace_id':   trace_id
	})
	return ctx.text(body)
}

@['/admin/providers/specs'; get]
pub fn (mut app App) admin_provider_specs(mut ctx Context) veb.Result {
	if !app.admin.on_data_plane {
		ctx.res.set_status(.not_found)
		return ctx.text('Not Found')
	}
	path := if ctx.req.url == '' { '/admin/providers/specs' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
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
	if !app.admin.on_data_plane {
		ctx.res.set_status(.not_found)
		return ctx.text('Not Found')
	}
	path := if ctx.req.url == '' { '/admin/providers/runtimes' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
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
