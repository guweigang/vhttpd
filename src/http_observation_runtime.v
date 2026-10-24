module main

import executor
import json2 as json
import log
import time

// Bounded per-listener state; owned by ControlPlaneRuntime.mu. Keys are pipeline
// IDs, never request URLs. Empty ID covers requests without a compiled route.
struct HttpObservations {
mut:
	total executor.AdminHttpMetrics
	routes map[string]executor.AdminHttpMetrics
	errors []executor.AdminHttpObservationError
	requests map[string][]executor.AdminHttpObservationError
	buckets map[i64]HttpObservationBucket
	last_bucket_unix i64
	window_reset_unix i64
}

fn http_metrics_record(previous executor.AdminHttpMetrics, status int, duration_ms i64, at_unix i64) executor.AdminHttpMetrics {
	duration := if duration_ms > 0 { duration_ms } else { i64(0) }
	mut buckets := previous.duration_buckets.clone()
	if buckets.len != 9 { buckets = []i64{len: 9} }
	for i, upper in [i64(1), 5, 10, 50, 100, 500, 1000, 5000] {
		if duration <= upper { buckets[i]++ }
	}
	buckets[8]++ // +Inf; buckets are cumulative.
	return executor.AdminHttpMetrics{
		requests_total: previous.requests_total + 1
		errors_total: previous.errors_total + if status >= 400 { i64(1) } else { i64(0) }
		client_errors_total: previous.client_errors_total + if status >= 400 && status < 500 { i64(1) } else { i64(0) }
		server_errors_total: previous.server_errors_total + if status >= 500 { i64(1) } else { i64(0) }
		timeouts_total: previous.timeouts_total + if status in [408, 504] { i64(1) } else { i64(0) }
		duration_sum_ms: previous.duration_sum_ms + duration
		duration_count: previous.duration_count + 1
		duration_max_ms: if duration > previous.duration_max_ms { duration } else { previous.duration_max_ms }
		duration_buckets: buckets
		last_status: status
		last_completed_unix: at_unix
	}
}

fn (mut observations HttpObservations) record(pipeline string, method string, status int, duration_ms i64, observation_id string, at_unix i64) {
	observations.record_staged(pipeline,method,status,duration_ms,observation_id,at_unix,executor.AdminHttpStages{})
}

fn (mut observations HttpObservations) record_staged(pipeline string, method string, status int, duration_ms i64, observation_id string, at_unix i64, stages executor.AdminHttpStages) {
	observations.total = http_metrics_record(observations.total, status, duration_ms, at_unix)
	key := if pipeline in observations.routes || observations.routes.len < 512 { pipeline } else { '@overflow' }
	previous := observations.routes[key] or { executor.AdminHttpMetrics{} }
	observations.routes[key] = http_metrics_record(previous, status, duration_ms, at_unix)
	observations.record_window(key, status, duration_ms, at_unix)
	if duration_ms >= 1 {
		mut samples := observations.requests[key] or { []executor.AdminHttpObservationError{} }
		samples << executor.AdminHttpObservationError{stages:stages,pipeline_id: key, method: method, status: status, duration_ms: duration_ms, observation_id: observation_id, at_unix: at_unix}
		if samples.len > 50 { samples = samples[samples.len - 50..].clone() }
		observations.requests[key] = samples
	}
	if status >= 400 {
		observations.errors << executor.AdminHttpObservationError{stages:stages,pipeline_id: key, method: method, status: status, duration_ms: duration_ms, observation_id: observation_id, at_unix: at_unix}
		if observations.errors.len > 20 { observations.errors = observations.errors[observations.errors.len - 20..].clone() }
	}
}

fn (mut app App) complete_http_observation(ctx Context, started i64, observation_id string) {
	status := if ctx.res.status_code > 0 { ctx.res.status_code } else { 200 }
	total_ns := time.sys_mono_now() - started
	duration_ms := total_ns / 1000000
	stages := ctx.observed_stages(total_ns)
	at_unix := time.now().unix()
	app.control_plane.mu.@lock()
	pipeline := if ctx.observed_pipeline in app.control_plane.http_observations.routes || app.control_plane.http_observations.routes.len < 512 { ctx.observed_pipeline } else { '@overflow' }
	app.control_plane.http_observations.record_staged(ctx.observed_pipeline, ctx.req.method.str(), status, duration_ms, observation_id, at_unix, stages)
	app.control_plane.mu.unlock()
	if duration_ms >= 1 || status >= 400 {
		entry := executor.AdminHttpObservationError{stages:stages,pipeline_id: pipeline, method: ctx.req.method.str(), status: status, duration_ms: duration_ms, observation_id: observation_id, at_unix: at_unix}
		line := http_observation_log(app.app_build_cfg.plan_listener_id, entry)
		if status >= 400 { log.warn(line) } else { log.info(line) }
	}
}

// Allowlisted structured completion log: never include URL, headers, body or errors.
fn http_observation_log(listener string, entry executor.AdminHttpObservationError) string {
	return '[http.observation] ' + json.encode({'observation_id': entry.observation_id, 'listener': listener, 'pipeline': entry.pipeline_id, 'method': entry.method, 'status': '${entry.status}', 'duration_ms': '${entry.duration_ms}', 'at_unix': '${entry.at_unix}', 'queue_ms':'${entry.stages.queue_ms:.3f}', 'vjsx_ms':'${entry.stages.vjsx_ms:.3f}', 'adapter_ms':'${entry.stages.adapter_ms:.3f}', 'other_ms':'${entry.stages.other_ms:.3f}', 'queue_observed':'${entry.stages.queue_observed}', 'vjsx_observed':'${entry.stages.vjsx_observed}', 'adapter_observed':'${entry.stages.adapter_observed}', 'stages_available':'${entry.stages.available}'}, escape_unicode: true)
}
