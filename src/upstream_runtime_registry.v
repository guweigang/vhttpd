module main

import time
import upstream
import upstream.transport

struct UpstreamRuntimeRegistry {}

fn (mut app App) build_upstream_runtime_context() UpstreamRuntimeContext {
	return UpstreamRuntimeContext{
		register_fn:   fn [mut app] (plan transport.WorkerUpstreamPlanFrame, method string, path string, req_id string, trace_id string) {
			UpstreamRuntimeRegistry.register(mut app, plan, method, path, req_id, trace_id)
		}
		unregister_fn: fn [mut app] (req_id string) {
			UpstreamRuntimeRegistry.unregister(mut app, req_id)
		}
		note_error_fn: fn [mut app] () {
			UpstreamRuntimeRegistry.note_error(mut app)
		}
		emit_fn:       fn [mut app] (kind string, fields map[string]string) {
			app.emit(kind, fields)
		}
		snapshot_fn:   fn [mut app] (details bool, limit int, offset int, role_filter string, provider_filter string) AdminUpstreamRuntimeSnapshot {
			return UpstreamRuntimeRegistry.snapshot(mut app, details, limit, offset, role_filter,
				provider_filter)
		}
	}
}

fn (mut app App) upstream_runtime_register(plan transport.WorkerUpstreamPlanFrame, method string, path string, req_id string, trace_id string) {
	runtime := app.build_upstream_runtime_context()
	runtime.register(plan, method, path, req_id, trace_id)
}

fn UpstreamRuntimeRegistry.register(mut app App, plan transport.WorkerUpstreamPlanFrame, method string, path string, req_id string, trace_id string) {
	if req_id == '' {
		return
	}
	normalized_path, _ := transport.WorkerHttpRequestCodec.normalize_request_target(path)
	app.transport.websocket.upstream_mu.@lock()
	app.transport.websocket.upstream_sessions[req_id] = upstream.UpstreamRuntimeSession{
		id:              req_id
		request_id:      req_id
		trace_id:        trace_id
		role:            'external_upstream'
		provider:        plan.name
		method:          method.to_upper()
		path:            normalized_path
		name:            plan.name
		transport:       plan.transport
		codec:           plan.codec
		mapper:          plan.mapper
		stream_type:     if plan.output_stream_type == '' { 'sse' } else { plan.output_stream_type }
		source:          if plan.fixture_path != '' { 'fixture' } else { 'http' }
		started_at_unix: time.now().unix()
	}
	app.transport.websocket.upstream_mu.unlock()
	app.mu.@lock()
	app.transport.websocket.stat_upstream_plans_total++
	app.mu.unlock()
}

fn (mut app App) upstream_runtime_unregister(req_id string) {
	runtime := app.build_upstream_runtime_context()
	runtime.unregister(req_id)
}

fn UpstreamRuntimeRegistry.unregister(mut app App, req_id string) {
	if req_id == '' {
		return
	}
	app.transport.websocket.upstream_mu.@lock()
	app.transport.websocket.upstream_sessions.delete(req_id)
	app.transport.websocket.upstream_mu.unlock()
}

fn (mut app App) upstream_runtime_note_error() {
	runtime := app.build_upstream_runtime_context()
	runtime.note_error()
}

fn UpstreamRuntimeRegistry.note_error(mut app App) {
	app.mu.@lock()
	app.transport.websocket.stat_upstream_plan_errors_total++
	app.mu.unlock()
}

fn (mut app App) admin_upstreams_snapshot(details bool, limit int, offset int, role_filter string, provider_filter string) AdminUpstreamRuntimeSnapshot {
	runtime := app.build_upstream_runtime_context()
	return runtime.snapshot(details, limit, offset, role_filter, provider_filter)
}

fn UpstreamRuntimeRegistry.snapshot(mut app App, details bool, limit int, offset int, role_filter string, provider_filter string) AdminUpstreamRuntimeSnapshot {
	app.transport.websocket.upstream_mu.@lock()
	defer {
		app.transport.websocket.upstream_mu.unlock()
	}
	mut sessions := []upstream.UpstreamRuntimeSession{}
	for _, session in app.transport.websocket.upstream_sessions {
		if role_filter != '' && session.role != role_filter {
			continue
		}
		if provider_filter != '' && session.provider != provider_filter {
			continue
		}
		sessions << session
	}
	mut ordered := []upstream.UpstreamRuntimeSession{}
	mut sort_keys := []string{}
	mut session_by_key := map[string]upstream.UpstreamRuntimeSession{}
	for session in sessions {
		key := '${session.started_at_unix}_${session.id}'
		sort_keys << key
		session_by_key[key] = session
	}
	sort_keys.sort()
	for key in sort_keys {
		ordered << session_by_key[key]
	}
	if !details {
		return AdminUpstreamRuntimeSnapshot{
			active_count:   ordered.len
			returned_count: 0
			details:        false
			limit:          limit
			offset:         offset
			sessions:       []upstream.UpstreamRuntimeSession{}
		}
	}
	mut sliced := []upstream.UpstreamRuntimeSession{}
	if offset < ordered.len {
		end := if offset + limit < ordered.len { offset + limit } else { ordered.len }
		for i in offset .. end {
			sliced << ordered[i]
		}
	}
	return AdminUpstreamRuntimeSnapshot{
		active_count:   ordered.len
		returned_count: sliced.len
		details:        true
		limit:          limit
		offset:         offset
		sessions:       sliced
	}
}
