module main

import time
import upstream
import upstream.transport
import sync

struct UpstreamRuntimeRegistry {
mut:
	mu                     sync.Mutex
	sessions               map[string]upstream.UpstreamRuntimeSession
	stat_plans_total       i64
	stat_plan_errors_total i64
}

fn UpstreamRuntimeRegistry.new() UpstreamRuntimeRegistry {
	return UpstreamRuntimeRegistry{
		sessions: map[string]upstream.UpstreamRuntimeSession{}
	}
}

fn (mut app App) build_upstream_runtime_context() UpstreamRuntimeContext {
	return UpstreamRuntimeContext{
		register_fn:   fn [mut app] (plan transport.WorkerUpstreamPlanFrame, method string, path string, req_id string, trace_id string) {
			app.upstreams.register(plan, method, path, req_id, trace_id)
		}
		unregister_fn: fn [mut app] (req_id string) {
			app.upstreams.unregister(req_id)
		}
		note_error_fn: fn [mut app] () {
			app.upstreams.note_error()
		}
		emit_fn:       fn [mut app] (kind string, fields map[string]string) {
			app.emit(kind, fields)
		}
		snapshot_fn:   fn [mut app] (details bool, limit int, offset int, role_filter string, provider_filter string) AdminUpstreamRuntimeSnapshot {
			return app.upstreams.snapshot(details, limit, offset, role_filter, provider_filter)
		}
	}
}

fn (mut app App) upstream_runtime_register(plan transport.WorkerUpstreamPlanFrame, method string, path string, req_id string, trace_id string) {
	runtime := app.build_upstream_runtime_context()
	runtime.register(plan, method, path, req_id, trace_id)
}

fn (mut registry UpstreamRuntimeRegistry) register(plan transport.WorkerUpstreamPlanFrame, method string, path string, req_id string, trace_id string) {
	if req_id == '' {
		return
	}
	normalized_path, _ := transport.WorkerHttpRequestCodec.normalize_request_target(path)
	registry.mu.@lock()
	defer { registry.mu.unlock() }
	registry.sessions[req_id] = upstream.UpstreamRuntimeSession{
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
	registry.stat_plans_total++
}

fn (mut app App) upstream_runtime_unregister(req_id string) {
	runtime := app.build_upstream_runtime_context()
	runtime.unregister(req_id)
}

fn (mut registry UpstreamRuntimeRegistry) unregister(req_id string) {
	if req_id == '' {
		return
	}
	registry.mu.@lock()
	registry.sessions.delete(req_id)
	registry.mu.unlock()
}

fn (mut app App) upstream_runtime_note_error() {
	runtime := app.build_upstream_runtime_context()
	runtime.note_error()
}

fn (mut registry UpstreamRuntimeRegistry) note_error() {
	registry.mu.@lock()
	registry.stat_plan_errors_total++
	registry.mu.unlock()
}

fn (mut app App) admin_upstreams_snapshot(details bool, limit int, offset int, role_filter string, provider_filter string) AdminUpstreamRuntimeSnapshot {
	runtime := app.build_upstream_runtime_context()
	return runtime.snapshot(details, limit, offset, role_filter, provider_filter)
}

fn (mut registry UpstreamRuntimeRegistry) snapshot(details bool, limit int, offset int, role_filter string, provider_filter string) AdminUpstreamRuntimeSnapshot {
	registry.mu.@lock()
	defer {
		registry.mu.unlock()
	}
	mut sessions := []upstream.UpstreamRuntimeSession{}
	for _, session in registry.sessions {
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

fn (mut registry UpstreamRuntimeRegistry) active_count() int {
	registry.mu.@lock()
	defer { registry.mu.unlock() }
	return registry.sessions.len
}

fn (mut registry UpstreamRuntimeRegistry) totals() (i64, i64) {
	registry.mu.@lock()
	defer { registry.mu.unlock() }
	return registry.stat_plans_total, registry.stat_plan_errors_total
}
