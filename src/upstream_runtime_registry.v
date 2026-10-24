module main

import time
import upstream
import upstream.transport
import sync
import veb

// Opaque per-execution ownership; client request IDs are correlation data only.
struct UpstreamRuntimeRegistration {
	owner &UpstreamRuntimeRegistry @[required]
	key   u64
}

struct UpstreamRuntimeRegistry {
mut:
	mu                     sync.Mutex
	next_registration      u64
	sessions               map[u64]upstream.UpstreamRuntimeSession
	stat_plans_total       i64
	stat_plan_errors_total i64
}

fn UpstreamRuntimeRegistry.new() UpstreamRuntimeRegistry {
	return UpstreamRuntimeRegistry{
		sessions: map[u64]upstream.UpstreamRuntimeSession{}
	}
}

fn (mut registry UpstreamRuntimeRegistry) register(plan transport.WorkerUpstreamPlanFrame, method string, path string, req_id string, trace_id string) ?UpstreamRuntimeRegistration {
	if req_id == '' {
		return none
	}
	normalized_path, _ := transport.WorkerHttpRequestCodec.normalize_request_target(path)
	registry.mu.@lock()
	defer { registry.mu.unlock() }
	registry.next_registration++
	registration := UpstreamRuntimeRegistration{ owner: &registry, key: registry.next_registration }
	registry.sessions[registration.key] = upstream.UpstreamRuntimeSession{
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
	return registration
}

fn (mut registry UpstreamRuntimeRegistry) unregister(registration UpstreamRuntimeRegistration) {
	if voidptr(registration.owner) != voidptr(&registry) { return }
	registry.mu.@lock()
	registry.sessions.delete(registration.key)
	registry.mu.unlock()
}

fn (mut registry UpstreamRuntimeRegistry) note_error() {
	registry.mu.@lock()
	registry.stat_plan_errors_total++
	registry.mu.unlock()
}

fn (mut registry UpstreamRuntimeRegistry) snapshot(details bool, limit int, offset int, role_filter string, provider_filter string) AdminUpstreamRuntimeSnapshot {
	registry.mu.@lock()
	mut sort_keys := []string{}
	mut session_by_key := map[string]upstream.UpstreamRuntimeSession{}
	for registration, session in registry.sessions {
		if role_filter != '' && session.role != role_filter { continue }
		if provider_filter != '' && session.provider != provider_filter { continue }
		key := '${session.started_at_unix}_${session.id}_${registration}'
		sort_keys << key
		session_by_key[key] = session
	}
	registry.mu.unlock()
	// Project outside the owner lock from one detached set of session values.
	sort_keys.sort()
	page_limit := if limit > 0 { limit } else { 0 }
	page_offset := if offset > 0 { offset } else { 0 }
	mut sessions := []upstream.UpstreamRuntimeSession{}
	if details {
		start := if page_offset < sort_keys.len { page_offset } else { sort_keys.len }
		remaining := sort_keys.len - start
		count := if page_limit < remaining { page_limit } else { remaining }
		for i in start .. start + count { sessions << session_by_key[sort_keys[i]] }
	}
	return AdminUpstreamRuntimeSnapshot{
		active_count:   sort_keys.len
		returned_count: sessions.len
		details:        details
		limit:          page_limit
		offset:         page_offset
		sessions:       sessions
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

fn (mut registry UpstreamRuntimeRegistry) build_context(emit_fn fn (string, map[string]string), render_fn fn (mut Context, HttpIngressRequest, string) veb.Result) UpstreamRuntimeContext {
	return UpstreamRuntimeContext{
		render_validation_failure_fn: render_fn
		register_fn:                  fn [mut registry] (plan transport.WorkerUpstreamPlanFrame, method string, path string, req_id string, trace_id string) ?UpstreamRuntimeRegistration {
			return registry.register(plan, method, path, req_id, trace_id)
		}
		unregister_fn:                fn [mut registry] (registration UpstreamRuntimeRegistration) {
			registry.unregister(registration)
		}
		note_error_fn:                fn [mut registry] () {
			registry.note_error()
		}
		emit_fn:                      emit_fn
		snapshot_fn:                  fn [mut registry] (details bool, limit int, offset int, role_filter string, provider_filter string) AdminUpstreamRuntimeSnapshot {
			return registry.snapshot(details, limit, offset, role_filter, provider_filter)
		}
	}
}
