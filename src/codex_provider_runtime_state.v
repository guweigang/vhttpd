module main

import config
import json
import codex

// ── Codex Provider Runtime ──────────────────────────────────────────────

fn (mut hub ProviderRuntimeHub) codex_runtime_ensure_instance(instance string) codex.ProviderRuntime {
	resolved := codex.ProviderRuntime.normalize_instance(instance)
	hub.codex.mu.@lock()
	defer {
		hub.codex.mu.unlock()
	}
	if resolved == 'main' {
		if hub.codex.runtime.instance == '' {
			hub.codex.runtime.instance = 'main'
		}
		return hub.codex.runtime
	}
	if resolved in hub.codex.instances {
		return hub.codex.instances[resolved] or { hub.codex.runtime.for_instance(resolved) }
	}
	mut next := hub.codex.runtime.for_instance(resolved)
	if spec := hub.provider_instance_get('codex', resolved) {
		if spec.config_json.trim_space() != '' {
			cfg := json.decode(config.CodexConfig, spec.config_json) or { config.CodexConfig{} }
			if cfg.url.trim_space() != '' {
				next.url = cfg.url
			}
			if cfg.model.trim_space() != '' {
				next.model = cfg.model
			}
			if cfg.effort.trim_space() != '' {
				next.effort = cfg.effort
			}
			if cfg.cwd.trim_space() != '' {
				next.cwd = cfg.cwd
			}
			if cfg.approval_policy.trim_space() != '' {
				next.approval_policy = cfg.approval_policy
			}
			if cfg.sandbox.trim_space() != '' {
				next.sandbox = cfg.sandbox
			}
			if cfg.reconnect_delay_ms > 0 {
				next.reconnect_delay_ms = cfg.reconnect_delay_ms
			}
			if cfg.flush_interval_ms > 0 {
				next.flush_interval_ms = cfg.flush_interval_ms
			}
		}
	}
	hub.codex.instances[resolved] = next
	return next
}

fn (mut app App) codex_runtime_ensure_instance(instance string) codex.ProviderRuntime {
	return app.providers.codex_runtime_ensure_instance(instance)
}

fn (hub ProviderRuntimeHub) codex_runtime_known_instances() []string {
	mut names := ['main']
	for name, _ in hub.codex.instances {
		if name !in names {
			names << name
		}
	}
	for spec in hub.provider_instance_list('codex') {
		if spec.instance !in names {
			names << spec.instance
		}
	}
	names.sort()
	return names
}

fn (app &App) codex_runtime_known_instances() []string {
	return app.providers.codex_runtime_known_instances()
}

fn (mut app App) codex_note_frame_received(instance string) i64 {
	mut rt := app.codex_runtime_ensure_instance(instance)
	count := rt.note_frame_received()
	app.providers.codex.update(instance, rt)
	return count
}

fn (mut app App) codex_take_pending_rpc(instance string, id int) (codex.PendingRpc, bool) {
	mut rt := app.codex_runtime_ensure_instance(instance)
	pending, ok := rt.take_pending_rpc(id)
	app.providers.codex.update(instance, rt)
	return pending, ok
}

fn (mut app App) codex_remember_pending_rpc(instance string, id int, pending codex.PendingRpc) {
	mut rt := app.codex_runtime_ensure_instance(instance)
	rt.remember_pending_rpc(id, pending)
	app.providers.codex.update(instance, rt)
}

fn (mut app App) codex_bind_stream_to_thread(instance string, thread_id string, stream_id string) string {
	mut rt := app.codex_runtime_ensure_instance(instance)
	bound := rt.bind_stream_to_thread(thread_id, stream_id)
	app.providers.codex.update(instance, rt)
	return bound
}

fn (mut app App) codex_bind_stream_to_current_thread(instance string, stream_id string) string {
	mut rt := app.codex_runtime_ensure_instance(instance)
	bound := rt.bind_stream_to_current_thread(stream_id)
	app.providers.codex.update(instance, rt)
	return bound
}

fn (mut app App) codex_add_stream_target(instance string, stream_id string, target codex.CodexTarget) {
	mut rt := app.codex_runtime_ensure_instance(instance)
	rt.add_stream_target(stream_id, target)
	app.providers.codex.update(instance, rt)
}

fn (mut app App) codex_stream_targets(instance string, stream_id string) []codex.CodexTarget {
	return app.providers.codex.snapshot(instance).stream_targets(stream_id)
}

fn (mut app App) codex_clear_stream_targets(instance string, stream_id string) bool {
	mut rt := app.codex_runtime_ensure_instance(instance)
	cleared := rt.clear_stream_targets(stream_id)
	app.providers.codex.update(instance, rt)
	return cleared
}

fn (mut app App) codex_clear_stream_targets_any(stream_id string) bool {
	mut cleared := false
	for instance in app.providers.codex_runtime_known_instances() {
		if app.codex_clear_stream_targets(instance, stream_id) {
			cleared = true
		}
	}
	return cleared
}

fn (mut app App) codex_clear_thread_binding(instance string, thread_id string) bool {
	mut rt := app.codex_runtime_ensure_instance(instance)
	cleared := rt.clear_thread_binding(thread_id)
	app.providers.codex.update(instance, rt)
	return cleared
}

fn (mut app App) codex_capture_thread_id(instance string, thread_id string) bool {
	mut rt := app.codex_runtime_ensure_instance(instance)
	ok := rt.capture_thread_id(thread_id)
	app.providers.codex.update(instance, rt)
	return ok
}

fn (mut app App) codex_ensure_thread_id(instance string, thread_id string) bool {
	mut rt := app.codex_runtime_ensure_instance(instance)
	ok := rt.ensure_thread_id(thread_id)
	app.providers.codex.update(instance, rt)
	return ok
}

fn (mut app App) codex_repair_thread_stream_binding(instance string, thread_id string) string {
	mut rt := app.codex_runtime_ensure_instance(instance)
	stream_id := rt.repair_thread_stream_binding(thread_id)
	app.providers.codex.update(instance, rt)
	return stream_id
}

fn (mut app App) codex_pending_stream_id(instance string) string {
	return app.providers.codex.snapshot(instance).pending_stream_id()
}

fn (mut app App) codex_queue_error_burst(instance string, stream_id string, raw_payload string) bool {
	mut rt := app.codex_runtime_ensure_instance(instance)
	should_flush := rt.queue_error_burst(stream_id, raw_payload)
	app.providers.codex.update(instance, rt)
	return should_flush
}

fn (mut app App) codex_schedule_read_fallback(instance string, stream_id string, thread_id string) (codex.ReadFallback, bool) {
	if stream_id.trim_space() == '' || thread_id.trim_space() == '' {
		return codex.ReadFallback{}, false
	}
	mut rt := app.codex_runtime_ensure_instance(instance)
	fallback := rt.schedule_read_fallback(stream_id, thread_id)
	app.providers.codex.update(instance, rt)
	return fallback, true
}

fn (mut app App) codex_clear_read_fallback(instance string, stream_id string) bool {
	mut rt := app.codex_runtime_ensure_instance(instance)
	cleared := rt.clear_read_fallback(stream_id)
	app.providers.codex.update(instance, rt)
	return cleared
}

fn (mut app App) codex_read_fallback(instance string, stream_id string) (codex.ReadFallback, bool) {
	rt := app.providers.codex.snapshot(instance)
	return rt.read_fallback(stream_id)
}

fn (mut app App) codex_take_error_burst(instance string, stream_id string) []string {
	mut rt := app.codex_runtime_ensure_instance(instance)
	errors := rt.take_error_burst(stream_id)
	app.providers.codex.update(instance, rt)
	return errors
}

fn (mut app App) codex_resolve_instance_for_stream(stream_id string) string {
	if stream_id.trim_space() == '' {
		return 'main'
	}
	for instance in app.providers.codex_runtime_known_instances() {
		rt := app.providers.codex.snapshot(instance)
		if stream_id in rt.stream_map {
			return instance
		}
		if rt.active_stream_id == stream_id {
			return instance
		}
		if rt.pending_stream_id() == stream_id {
			return instance
		}
		for _, bound_stream_id in rt.thread_stream_map {
			if bound_stream_id == stream_id {
				return instance
			}
		}
	}
	return 'main'
}

fn (mut app App) codex_get_active_stream_id_for_instance(instance string) string {
	return app.providers.codex.snapshot(instance).current_stream_id()
}

fn (mut app App) codex_find_stream_targets(stream_id string) []codex.CodexTarget {
	if stream_id.trim_space() == '' {
		return []codex.CodexTarget{}
	}
	resolved := app.codex_resolve_instance_for_stream(stream_id)
	mut seen := map[string]bool{}
	mut targets := []codex.CodexTarget{}
	mut instances := []string{}
	if resolved != '' {
		instances << resolved
		seen[resolved] = true
	}
	for instance in app.providers.codex_runtime_known_instances() {
		if seen[instance] {
			continue
		}
		instances << instance
		seen[instance] = true
	}
	for instance in instances {
		candidates := app.codex_stream_targets(instance, stream_id)
		if candidates.len == 0 {
			continue
		}
		targets << candidates
	}
	return targets
}
