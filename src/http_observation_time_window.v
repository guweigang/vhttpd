module main

import executor
import json2 as json
import time
import veb

struct HttpObservationBucket {
mut:
	total executor.AdminHttpMetrics
	routes map[string]executor.AdminHttpMetrics
}

fn http_metrics_merge(a executor.AdminHttpMetrics, b executor.AdminHttpMetrics) executor.AdminHttpMetrics {
	mut buckets := []i64{len: 9}
	for i in 0 .. 9 { buckets[i] = (a.duration_buckets[i] or { i64(0) }) + (b.duration_buckets[i] or { i64(0) }) }
	latest := if b.last_completed_unix >= a.last_completed_unix { b } else { a }
	return executor.AdminHttpMetrics{
		requests_total: a.requests_total + b.requests_total
		errors_total: a.errors_total + b.errors_total
		client_errors_total: a.client_errors_total + b.client_errors_total
		server_errors_total: a.server_errors_total + b.server_errors_total
		timeouts_total: a.timeouts_total + b.timeouts_total
		duration_sum_ms: a.duration_sum_ms + b.duration_sum_ms
		duration_count: a.duration_count + b.duration_count
		duration_max_ms: if a.duration_max_ms > b.duration_max_ms { a.duration_max_ms } else { b.duration_max_ms }
		duration_buckets: buckets
		last_status: latest.last_status
		last_completed_unix: latest.last_completed_unix
	}
}

fn (mut observations HttpObservations) record_window(key string, status int, duration_ms i64, at_unix i64) {
	stamp := at_unix / 10 * 10
	if observations.last_bucket_unix > stamp {
		observations.buckets.clear()
		observations.requests.clear()
		observations.window_reset_unix = at_unix
	}
	observations.last_bucket_unix = stamp
	for old in observations.buckets.keys() {
		if old < stamp - 900 { observations.buckets.delete(old) }
	}
	mut bucket := observations.buckets[stamp] or { HttpObservationBucket{} }
	bucket.total = http_metrics_record(bucket.total, status, duration_ms, at_unix)
	bucket.routes[key] = http_metrics_record(bucket.routes[key] or { executor.AdminHttpMetrics{} }, status, duration_ms, at_unix)
	observations.buckets[stamp] = bucket
}

fn (r &ActiveRuntimeRegistry) traffic_window(listener string, pipeline string, filtered bool, seconds int, now i64) executor.AdminHttpTrafficWindow {
	r.mu.@lock()
	apps := r.apps.clone()
	cfgs := r.cfgs.clone()
	r.mu.unlock()
	lower := (now - seconds) / 10 * 10
	mut start := now
	mut total := executor.AdminHttpMetrics{}
	mut series := map[i64]executor.AdminHttpMetrics{}
	mut listeners := []executor.AdminHttpListenerWindow{}
	mut seen := map[string]bool{}
	for i, app in apps {
		cfg := cfgs[i] or { continue }
		if !cfg.serve_data_plane || (listener != '' && cfg.plan_listener_id != listener) || seen[cfg.plan_listener_id] { continue }
		seen[cfg.plan_listener_id] = true
		app.control_plane.mu.@lock()
		mut since := app.lifecycle.started_at_unix
		if app.control_plane.http_observations.window_reset_unix > since { since = app.control_plane.http_observations.window_reset_unix }
		if since < lower { since = lower }
		if since < start { start = since }
		mut metrics := executor.AdminHttpMetrics{}
		mut routes := map[string]executor.AdminHttpMetrics{}
		for stamp, bucket in app.control_plane.http_observations.buckets {
			if stamp < lower || stamp > now { continue }
			value := if filtered { bucket.routes[pipeline] or { executor.AdminHttpMetrics{} } } else { bucket.total }
			metrics = http_metrics_merge(metrics, value)
			series[stamp] = http_metrics_merge(series[stamp] or { executor.AdminHttpMetrics{} }, value)
			for id, route in bucket.routes {
				if filtered && id != pipeline { continue }
				routes[id] = http_metrics_merge(routes[id] or { executor.AdminHttpMetrics{} }, route)
			}
		}
		app.control_plane.mu.unlock()
		mut route_metrics := []executor.AdminHttpRouteMetrics{}
		mut ids := routes.keys()
		ids.sort()
		for id in ids { route_metrics << executor.AdminHttpRouteMetrics{pipeline_id: id, metrics: routes[id]} }
		listeners << executor.AdminHttpListenerWindow{listener_id: cfg.plan_listener_id, metrics: metrics, routes: route_metrics}
		total = http_metrics_merge(total, metrics)
	}
	mut points := []executor.AdminHttpTimePoint{}
	if listeners.len > 0 {
		mut stamp := start / 10 * 10
		for stamp <= now {
			begin := if stamp > start { stamp } else { start }
			end := if stamp + 10 < now { stamp + 10 } else { now }
			span := if end > begin { end - begin } else { i64(1) }
			points << executor.AdminHttpTimePoint{at_unix: stamp, span_seconds: span, metrics: series[stamp] or { executor.AdminHttpMetrics{} }}
			stamp += 10
		}
	}
	return executor.AdminHttpTrafficWindow{at_unix: now, start_unix: start, window_seconds: seconds, listener: listener, pipeline: pipeline, route_filtered: filtered, listeners: listeners, metrics: total, series: points}
}

fn read_http_traffic_window(ctx Context) executor.AdminHttpTrafficWindow {
	requested := (ctx.query['window'] or { '60' }).int()
	seconds := if requested in [60, 300, 900] { requested } else { 60 }
	unsafe { return g_active_runtime_registry.traffic_window(ctx.query['listener'] or { '' }, ctx.query['pipeline'] or { '' }, (ctx.query['route'] or { '' }) == '1', seconds, time.now().unix()) }
}

@['/admin/http/traffic'; get]
pub fn (mut app AdminApp) admin_http_traffic(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/http/traffic')
	if !app.admin_authorized(ctx) { return admin_plane_forbidden(mut app, mut ctx, 'GET', req) }
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, json.encode(read_http_traffic_window(ctx), escape_unicode: true, time_as_unix: true), {'admin_endpoint': 'http_traffic'})
}

@['/admin/http/traffic'; get]
pub fn (mut app App) admin_http_traffic(mut ctx Context) veb.Result {
	req := admin_data_plane_request(ctx, '/admin/http/traffic')
	if !app.control_plane.admin.on_data_plane { return admin_data_plane_text(mut app, mut ctx, 'GET', req, 404, 'Not Found', map[string]string{}) }
	if !app.api_authorized(ctx) { return admin_data_plane_json(mut app, mut ctx, 'GET', req, 403, '{"error":"forbidden"}', map[string]string{}) }
	return admin_data_plane_json(mut app, mut ctx, 'GET', req, 200, json.encode(read_http_traffic_window(ctx), escape_unicode: true, time_as_unix: true), {'admin_endpoint': 'http_traffic'})
}

fn (r &ActiveRuntimeRegistry) request_details(listener string, pipeline string, seconds int, min_ms i64, now i64) executor.AdminHttpRequestDetails {
	r.mu.@lock()
	apps := r.apps.clone()
	cfgs := r.cfgs.clone()
	r.mu.unlock()
	mut requests := []executor.AdminHttpRequestDetail{}
	mut retained := 0
	for i, app in apps {
		cfg := cfgs[i] or { continue }
		if !cfg.serve_data_plane || cfg.plan_listener_id != listener { continue }
		app.control_plane.mu.@lock()
		samples := (app.control_plane.http_observations.requests[pipeline] or { []executor.AdminHttpObservationError{} }).clone()
		app.control_plane.mu.unlock()
		retained = samples.len
		for entry in samples {
			if entry.at_unix < now - seconds || entry.at_unix > now || entry.duration_ms < min_ms { continue }
			requests << executor.AdminHttpRequestDetail{request: entry, log_line: http_observation_log(listener, entry)}
		}
		break
	}
	requests.sort(a.request.at_unix > b.request.at_unix)
	return executor.AdminHttpRequestDetails{at_unix: now, listener: listener, pipeline: pipeline, window_seconds: seconds, min_ms: min_ms, retained: retained, requests: requests}
}

fn read_http_request_details(ctx Context) executor.AdminHttpRequestDetails {
	requested := (ctx.query['window'] or { '60' }).int()
	seconds := if requested in [60, 300, 900] { requested } else { 60 }
	requested_ms := (ctx.query['min_ms'] or { '500' }).i64()
	min_ms := if requested_ms < 1 { i64(1) } else if requested_ms > 3600000 { i64(3600000) } else { requested_ms }
	unsafe { return g_active_runtime_registry.request_details(ctx.query['listener'] or { '' }, ctx.query['pipeline'] or { '' }, seconds, min_ms, time.now().unix()) }
}

@['/admin/http/requests'; get]
pub fn (mut app AdminApp) admin_http_requests(mut ctx Context) veb.Result {
	req := admin_plane_request(ctx, '/admin/http/requests')
	if !app.admin_authorized(ctx) { return admin_plane_forbidden(mut app, mut ctx, 'GET', req) }
	return admin_plane_json_response(mut app, mut ctx, 'GET', req, 200, json.encode(read_http_request_details(ctx), escape_unicode: true, time_as_unix: true), {'admin_endpoint': 'http_requests'})
}

@['/admin/http/requests'; get]
pub fn (mut app App) admin_http_requests(mut ctx Context) veb.Result {
	req := admin_data_plane_request(ctx, '/admin/http/requests')
	if !app.control_plane.admin.on_data_plane { return admin_data_plane_text(mut app, mut ctx, 'GET', req, 404, 'Not Found', map[string]string{}) }
	if !app.api_authorized(ctx) { return admin_data_plane_json(mut app, mut ctx, 'GET', req, 403, '{"error":"forbidden"}', map[string]string{}) }
	return admin_data_plane_json(mut app, mut ctx, 'GET', req, 200, json.encode(read_http_request_details(ctx), escape_unicode: true, time_as_unix: true), {'admin_endpoint': 'http_requests'})
}
