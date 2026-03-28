module main

import json
import time
import veb

struct AdminRuntimeStats {
	started_at_unix                        i64
	uptime_seconds                         i64
	http_requests_total                    i64
	http_errors_total                      i64
	http_timeouts_total                    i64
	http_streams_total                     i64
	admin_actions_total                    i64
	worker_queue_waits_total               i64
	worker_queue_rejected_total            i64
	worker_queue_timeouts_total            i64
	upstream_plans_total                   i64
	upstream_plan_errors_total             i64
	mcp_sessions_expired_total             i64
	mcp_sessions_evicted_total             i64
	mcp_pending_dropped_total              i64
	mcp_sampling_capability_warnings_total i64
	mcp_sampling_capability_dropped_total  i64
	mcp_sampling_capability_errors_total   i64
	feishu_connect_attempts                i64
	feishu_connect_successes               i64
	feishu_received_frames                 i64
	feishu_acked_events                    i64
	feishu_messages_sent                   i64
	feishu_send_errors                     i64
}

struct AdminRuntimeSummary {
	started_at_unix          i64
	uptime_seconds           i64
	worker_pool_size         int
	worker_backend_mode      string
	worker_queue_capacity    int
	worker_queue_timeout_ms  int
	worker_queue_depth       int
	logic_executor           string
	logic_executor_lifecycle string
	logic_executor_model     string
	logic_provider           string
	capabilities             map[string]bool
	active_websockets        int
	active_upstreams         int
	active_mcp_sessions      int
	active_gateways          int
	stats                    AdminRuntimeStats
}

fn (mut app App) admin_stats_snapshot() AdminRuntimeStats {
	app.mu.@lock()
	defer {
		app.mu.unlock()
	}
	feishu_metrics := app.provider_runtime_metrics('feishu')
	now := time.now().unix()
	started := if app.started_at_unix > 0 { app.started_at_unix } else { now }
	uptime := if now > started { now - started } else { 0 }
	return AdminRuntimeStats{
		started_at_unix:                        started
		uptime_seconds:                         uptime
		http_requests_total:                    app.stat_http_requests_total
		http_errors_total:                      app.stat_http_errors_total
		http_timeouts_total:                    app.stat_http_timeouts_total
		http_streams_total:                     app.stat_http_streams_total
		admin_actions_total:                    app.stat_admin_actions_total
		worker_queue_waits_total:               app.stat_worker_queue_waits_total
		worker_queue_rejected_total:            app.stat_worker_queue_rejected_total
		worker_queue_timeouts_total:            app.stat_worker_queue_timeouts_total
		upstream_plans_total:                   app.stat_upstream_plans_total
		upstream_plan_errors_total:             app.stat_upstream_plan_errors_total
		mcp_sessions_expired_total:             app.stat_mcp_sessions_expired_total
		mcp_sessions_evicted_total:             app.stat_mcp_sessions_evicted_total
		mcp_pending_dropped_total:              app.stat_mcp_pending_dropped_total
		mcp_sampling_capability_warnings_total: app.stat_mcp_sampling_capability_warnings_total
		mcp_sampling_capability_dropped_total:  app.stat_mcp_sampling_capability_dropped_total
		mcp_sampling_capability_errors_total:   app.stat_mcp_sampling_capability_errors_total
		feishu_connect_attempts:                feishu_metrics.connect_attempts
		feishu_connect_successes:               feishu_metrics.connect_successes
		feishu_received_frames:                 feishu_metrics.received_frames
		feishu_acked_events:                    feishu_metrics.acked_events
		feishu_messages_sent:                   feishu_metrics.messages_sent
		feishu_send_errors:                     feishu_metrics.send_errors
	}
}

fn (mut app App) admin_runtime_snapshot() AdminRuntimeSummary {
	stats := app.admin_stats_snapshot()
	mut active_websockets := 0
	app.ws_hub_mu.@lock()
	active_websockets = app.ws_hub_conns.len
	app.ws_hub_mu.unlock()
	mut active_upstreams := 0
	app.upstream_mu.@lock()
	active_upstreams = app.upstream_sessions.len
	app.upstream_mu.unlock()
	mut active_mcp_sessions := 0
	app.mcp_mu.@lock()
	app.mcp_prune_sessions_locked(time.now().unix())
	active_mcp_sessions = app.mcp_sessions.len
	app.mcp_mu.unlock()
	mut worker_queue_depth := 0
	app.pool_mu.@lock()
	worker_queue_depth = app.worker_backend.queue_waiting_requests
	app.pool_mu.unlock()
	mut capabilities := map[string]bool{}
	capabilities['http'] = true
	capabilities['stream'] = true
	capabilities['stream_direct'] = true
	capabilities['stream_dispatch'] = app.stream_dispatch
	capabilities['stream_upstream_plan'] = true
	capabilities['websocket'] = true
	capabilities['websocket_dispatch'] = app.websocket_dispatch_mode
	capabilities['mcp'] = true
	capabilities['websocket_upstream'] = true
	for key, value in app.provider_runtime_capabilities() {
		capabilities[key] = value
	}
	return AdminRuntimeSummary{
		started_at_unix:          stats.started_at_unix
		uptime_seconds:           stats.uptime_seconds
		worker_pool_size:         app.worker_backend.sockets.len
		worker_backend_mode:      '${app.worker_backend_mode}'
		worker_queue_capacity:    app.worker_backend.queue_capacity
		worker_queue_timeout_ms:  app.worker_backend.queue_timeout_ms
		worker_queue_depth:       worker_queue_depth
		logic_executor:           app.logic_executor_kind()
		logic_executor_lifecycle: app.logic_executor_lifecycle
		logic_executor_model:     '${app.logic_executor_model()}'
		logic_provider:           app.logic_executor_provider()
		capabilities:             capabilities
		active_websockets:        active_websockets
		active_upstreams:         active_upstreams
		active_mcp_sessions:      active_mcp_sessions
		active_gateways:          app.provider_runtime_gateway_count()
		stats:                    stats
	}
}

fn admin_query_boolish(raw string) bool {
	return raw.trim_space().to_lower() in ['1', 'true', 'yes', 'on']
}

fn admin_query_limit(raw string, default_value int, max_value int) int {
	mut value := raw.trim_space().int()
	if value <= 0 {
		value = default_value
	}
	if value > max_value {
		value = max_value
	}
	return value
}

fn admin_query_offset(raw string) int {
	mut value := raw.trim_space().int()
	if value < 0 {
		value = 0
	}
	return value
}

@['/admin/runtime'; get]
pub fn (mut app App) admin_runtime(mut ctx Context) veb.Result {
	if !app.admin_on_data_plane {
		ctx.res.set_status(.not_found)
		return ctx.text('Not Found')
	}
	path := if ctx.req.url == '' { '/admin/runtime' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	body := json.encode(app.admin_runtime_snapshot())
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
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
	if !app.admin_on_data_plane {
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
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
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
	if !app.admin_on_data_plane {
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
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
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
	if !app.admin_on_data_plane {
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
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
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

@['/admin/providers/specs'; get]
pub fn (mut app App) admin_provider_specs(mut ctx Context) veb.Result {
	if !app.admin_on_data_plane {
		ctx.res.set_status(.not_found)
		return ctx.text('Not Found')
	}
	path := if ctx.req.url == '' { '/admin/providers/specs' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	body := json.encode(app.admin_provider_specs_snapshot())
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
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
	if !app.admin_on_data_plane {
		ctx.res.set_status(.not_found)
		return ctx.text('Not Found')
	}
	path := if ctx.req.url == '' { '/admin/providers/runtimes' } else { ctx.req.url }
	req_id := resolve_request_id(ctx, path)
	trace_id := resolve_trace_id(ctx, path)
	body := json.encode(app.admin_provider_runtimes_snapshot())
	ctx.set_custom_header('x-vhttpd-trace-id', trace_id) or {}
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
