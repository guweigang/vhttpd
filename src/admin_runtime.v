module main
import admin
import executor

import json
import time
import veb

type AdminRuntimeStats = executor.AdminRuntimeStats
type AdminRuntimeSummary = executor.AdminRuntimeSummary
type AdminHttpStats = executor.AdminHttpStats
type AdminWorkerQueueStats = executor.AdminWorkerQueueStats
type AdminUpstreamStats = executor.AdminUpstreamStats
type AdminMcpStats = executor.AdminMcpStats
type AdminFeishuStats = executor.AdminFeishuStats

fn (mut app App) admin_stats_snapshot() executor.AdminRuntimeStats {
	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	connect_attempts, connect_successes, received_frames, acked_events, messages_sent, send_errors :=
		app.feishu_runtime_totals()
	return app.admin.stats_snapshot(app, connect_attempts, connect_successes, received_frames,
		acked_events, messages_sent, send_errors)
}

type AdminWorkerPoolSummary = executor.AdminWorkerPoolSummary
type AdminLogicExecutorSummary = executor.AdminLogicExecutorSummary
type AdminActiveCounts = executor.AdminActiveCounts

fn (mut app App) admin_runtime_snapshot() executor.AdminRuntimeSummary {
	// These two values require mutating internal sub-struct locks;
	// compute them here (in main) and pass to the admin sub-module.
	mut active_mcp_sessions := 0
	app.mcp.mu.@lock()
	app.mcp_prune_sessions_locked(time.now().unix())
	active_mcp_sessions = app.mcp.sessions.len
	app.mcp.mu.unlock()
	mut worker_queue_depth := 0
	app.worker.mu.@lock()
	worker_queue_depth = app.worker.worker_backend.queue_waiting_requests
	app.worker.mu.unlock()
	provider_capabilities := app.provider_runtime_capabilities()
	provider_gateway_count := app.provider_runtime_gateway_count()
	connect_attempts, connect_successes, received_frames, acked_events, messages_sent, send_errors :=
		app.feishu_runtime_totals()
	return app.admin.runtime_snapshot(app, active_mcp_sessions, worker_queue_depth, provider_capabilities, provider_gateway_count, connect_attempts, connect_successes, received_frames, acked_events, messages_sent, send_errors)
}

fn admin_query_boolish(raw string) bool {
	return admin.parse_boolish(raw)
}

fn admin_query_limit(raw string, default_value int, max_value int) int {
	return admin.query_limit(raw, default_value, max_value)
}

fn admin_query_offset(raw string) int {
	return admin.query_offset(raw)
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
	details := admin_query_boolish(ctx.query['details'] or { 'false' })
	limit := admin_query_limit(ctx.query['limit'] or { '' }, 100, 1000)
	offset := admin_query_offset(ctx.query['offset'] or { '' })
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
	details := admin_query_boolish(ctx.query['details'] or { 'false' })
	limit := admin_query_limit(ctx.query['limit'] or { '' }, 100, 1000)
	offset := admin_query_offset(ctx.query['offset'] or { '' })
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
	details := admin_query_boolish(ctx.query['details'] or { 'false' })
	limit := admin_query_limit(ctx.query['limit'] or { '' }, 100, 1000)
	offset := admin_query_offset(ctx.query['offset'] or { '' })
	session_filter := (ctx.query['session_id'] or { '' }).trim_space()
	protocol_filter := (ctx.query['protocol_version'] or { '' }).trim_space()
	body := json.encode(app.admin_mcp_snapshot(details, limit, offset, session_filter,
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

// ── admin.RuntimeContext implementation ──
// These methods allow App to satisfy the admin.RuntimeContext interface
// so admin/ sub-module can call back without importing main.
// All are assumed to be called under app.mu lock.

fn (app &App) started_at_unix() i64 {
	return app.started_at_unix
}

fn (app &App) http_requests_total() i64 {
	return app.http_stats.requests_total
}

fn (app &App) http_errors_total() i64 {
	return app.http_stats.errors_total
}

fn (app &App) http_timeouts_total() i64 {
	return app.http_stats.timeouts_total
}

fn (app &App) http_streams_total() i64 {
	return app.http_stats.streams_total
}

fn (app &App) http_admin_actions_total() i64 {
	return app.http_stats.admin_actions_total
}

fn (app &App) worker_queue_waits_total() i64 {
	return app.worker.stat_queue_waits_total
}

fn (app &App) worker_queue_rejected_total() i64 {
	return app.worker.stat_queue_rejected_total
}

fn (app &App) worker_queue_timeouts_total() i64 {
	return app.worker.stat_queue_timeouts_total
}

fn (app &App) ws_hub_upstream_plans_total() i64 {
	return app.ws_hub.stat_upstream_plans_total
}

fn (app &App) ws_hub_upstream_plan_errors_total() i64 {
	return app.ws_hub.stat_upstream_plan_errors_total
}

fn (app &App) mcp_sessions_expired_total() i64 {
	return app.mcp.stat_sessions_expired_total
}

fn (app &App) mcp_sessions_evicted_total() i64 {
	return app.mcp.stat_sessions_evicted_total
}

fn (app &App) mcp_pending_dropped_total() i64 {
	return app.mcp.stat_pending_dropped_total
}

fn (app &App) mcp_sampling_capability_warnings_total() i64 {
	return app.mcp.stat_sampling_capability_warnings_total
}

fn (app &App) mcp_sampling_capability_dropped_total() i64 {
	return app.mcp.stat_sampling_capability_dropped_total
}

fn (app &App) mcp_sampling_capability_errors_total() i64 {
	return app.mcp.stat_sampling_capability_errors_total
}

fn (app &App) ws_hub_active_conns() int {
	app.ws_hub.mu.@lock()
	defer {
		app.ws_hub.mu.unlock()
	}
	return app.ws_hub.conns.len
}

fn (app &App) ws_hub_active_upstreams() int {
	app.ws_hub.upstream_mu.@lock()
	defer {
		app.ws_hub.upstream_mu.unlock()
	}
	return app.ws_hub.upstream_sessions.len
}

fn (app &App) worker_pool_size() int {
	return app.worker.worker_backend.sockets.len
}

fn (app &App) worker_backend_mode() string {
	return '${app.worker.worker_backend_mode}'
}

fn (app &App) worker_queue_capacity() int {
	return app.worker.worker_backend.queue_capacity
}

fn (app &App) worker_queue_timeout_ms() int {
	return app.worker.worker_backend.queue_timeout_ms
}

fn (app &App) worker_stream_dispatch() bool {
	return app.worker.stream_dispatch
}

fn (app &App) ws_hub_dispatch_mode() bool {
	return app.ws_hub.dispatch_mode
}

fn (app &App) worker_lifecycle() string {
	return app.worker.lifecycle
}
