module main

import config
import json2 as json
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
		return hub.codex.runtime.snapshot_copy()
	}
	next := hub.codex_runtime_instance_unlocked(resolved)
	hub.codex.instances[resolved] = next
	return next.snapshot_copy()
}

// Synchronous, state-only transitions. No network, App callback or nested
// acquisition of codex.mu may run inside change; publish before unlocking.
fn (mut hub ProviderRuntimeHub) codex_runtime_mutate[T](instance string, change fn (mut codex.ProviderRuntime) T) T {
	resolved := codex.ProviderRuntime.normalize_instance(instance)
	hub.codex.mu.@lock()
	defer { hub.codex.mu.unlock() }
	mut rt := hub.codex_runtime_instance_unlocked(resolved)
	if rt.instance == '' { rt.instance = resolved }
	result := change(mut rt)
	if resolved == 'main' { hub.codex.runtime = rt } else { hub.codex.instances[resolved] = rt }
	return result
}

fn (mut hub ProviderRuntimeHub) codex_register_rpc(instance string, pending codex.PendingRpc) codex.RpcRegistration {
	mut state := &hub.codex
	return hub.codex_runtime_mutate[codex.RpcRegistration](instance, fn [mut state, instance, pending] (mut rt codex.ProviderRuntime) codex.RpcRegistration {
		return state.register_rpc_unlocked(instance, mut rt, pending)
	})
}

struct CodexPendingRpcResult {
	pending codex.PendingRpc
	found   bool
}

// Caller holds codex.mu; instance lookup uses the registry's own mutex.
fn (hub ProviderRuntimeHub) codex_runtime_instance_unlocked(resolved string) codex.ProviderRuntime {
	if resolved == 'main' { return hub.codex.runtime }
	if resolved in hub.codex.instances {
		return hub.codex.instances[resolved] or { hub.codex.runtime.for_instance(resolved) }
	}
	mut next := hub.codex.runtime.for_instance(resolved)
	if spec := hub.provider_instance_get('codex', resolved) {
		if spec.config_json.trim_space() != '' {
			cfg := json.decode[config.CodexConfig](spec.config_json) or { config.CodexConfig{} }
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
	return next
}

fn (mut app App) codex_runtime_ensure_instance(instance string) codex.ProviderRuntime {
	return app.providers.codex_runtime_ensure_instance(instance)
}

fn (mut hub ProviderRuntimeHub) codex_runtime_known_instances() []string {
	mut names := ['main']
	hub.codex.mu.@lock()
	for name, _ in hub.codex.instances {
		if name !in names {
			names << name
		}
	}
	hub.codex.mu.unlock()
	for spec in hub.provider_instance_list('codex') {
		if spec.instance !in names {
			names << spec.instance
		}
	}
	names.sort()
	return names
}

fn (mut app App) codex_runtime_known_instances() []string {
	return app.providers.codex_runtime_known_instances()
}

fn (mut app App) codex_note_frame_received(instance string) i64 {
	return app.providers.codex_runtime_mutate[i64](instance, fn (mut rt codex.ProviderRuntime) i64 {
		return rt.note_frame_received()
	})
}

fn (mut app App) codex_take_pending_rpc(instance string, id int) (codex.PendingRpc, bool) {
	result := app.providers.codex_runtime_mutate[CodexPendingRpcResult](instance, fn [id] (mut rt codex.ProviderRuntime) CodexPendingRpcResult {
		pending, found := rt.take_pending_rpc(id)
		return CodexPendingRpcResult{ pending: pending, found: found }
	})
	return result.pending, result.found
}

fn (mut app App) codex_remember_pending_rpc(instance string, id int, pending codex.PendingRpc) {
	app.providers.codex_runtime_mutate[bool](instance, fn [id, pending] (mut rt codex.ProviderRuntime) bool {
		rt.remember_pending_rpc(id, pending)
		return true
	})
}

fn (mut app App) codex_bind_stream_to_thread(instance string, thread_id string, stream_id string) string {
	return app.providers.codex_runtime_mutate[string](instance, fn [thread_id, stream_id] (mut rt codex.ProviderRuntime) string {
		return rt.bind_stream_to_thread(thread_id, stream_id)
	})
}

fn (mut app App) codex_bind_stream_to_current_thread(instance string, stream_id string) string {
	return app.providers.codex_runtime_mutate[string](instance, fn [stream_id] (mut rt codex.ProviderRuntime) string {
		return rt.bind_stream_to_current_thread(stream_id)
	})
}

fn (mut app App) codex_add_stream_target(instance string, stream_id string, target codex.CodexTarget) {
	app.providers.codex_runtime_mutate[bool](instance, fn [stream_id, target] (mut rt codex.ProviderRuntime) bool {
		rt.add_stream_target(stream_id, target)
		return true
	})
}

fn (mut app App) codex_stream_targets(instance string, stream_id string) []codex.CodexTarget {
	return app.providers.codex.snapshot(instance).stream_targets(stream_id)
}

fn (mut app App) codex_clear_stream_targets(instance string, stream_id string) bool {
	return app.providers.codex_runtime_mutate[bool](instance, fn [stream_id] (mut rt codex.ProviderRuntime) bool {
		return rt.clear_stream_targets(stream_id)
	})
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
	return app.providers.codex_runtime_mutate[bool](instance, fn [thread_id] (mut rt codex.ProviderRuntime) bool {
		return rt.clear_thread_binding(thread_id)
	})
}

fn (mut app App) codex_capture_thread_id(instance string, thread_id string) bool {
	return app.providers.codex_runtime_mutate[bool](instance, fn [thread_id] (mut rt codex.ProviderRuntime) bool {
		return rt.capture_thread_id(thread_id)
	})
}

fn (mut app App) codex_ensure_thread_id(instance string, thread_id string) bool {
	return app.providers.codex_runtime_mutate[bool](instance, fn [thread_id] (mut rt codex.ProviderRuntime) bool {
		return rt.ensure_thread_id(thread_id)
	})
}

fn (mut app App) codex_repair_thread_stream_binding(instance string, thread_id string) string {
	return app.providers.codex_runtime_mutate[string](instance, fn [thread_id] (mut rt codex.ProviderRuntime) string {
		return rt.repair_thread_stream_binding(thread_id)
	})
}

fn (mut app App) codex_pending_stream_id(instance string) string {
	return app.providers.codex.snapshot(instance).pending_stream_id()
}

fn (mut app App) codex_queue_error_burst(instance string, stream_id string, raw_payload string) ?&codex.ErrorBurstJob {
	return app.providers.codex.error_bursts.enqueue(mut app.websocket.upstream_runs, instance, stream_id, raw_payload)
}

fn (mut app App) codex_schedule_read_fallback(instance string, stream_id string, thread_id string) (codex.ReadFallback, bool) {
	if stream_id.trim_space() == '' || thread_id.trim_space() == '' {
		return codex.ReadFallback{}, false
	}
	fallback := app.providers.codex_runtime_mutate[codex.ReadFallback](instance, fn [stream_id, thread_id] (mut rt codex.ProviderRuntime) codex.ReadFallback {
		return rt.schedule_read_fallback(stream_id, thread_id)
	})
	return fallback, true
}

fn (mut app App) codex_clear_read_fallback(instance string, stream_id string) bool {
	return app.providers.codex_runtime_mutate[bool](instance, fn [stream_id] (mut rt codex.ProviderRuntime) bool {
		return rt.clear_read_fallback(stream_id)
	})
}

fn (mut app App) codex_read_fallback(instance string, stream_id string) (codex.ReadFallback, bool) {
	rt := app.providers.codex.snapshot(instance)
	return rt.read_fallback(stream_id)
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
