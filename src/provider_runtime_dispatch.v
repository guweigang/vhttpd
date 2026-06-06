module main

import db
import json
import provider

fn (mut app App) build_provider_runtime_dispatch_context() provider.RuntimeDispatchContext {
	return provider.RuntimeDispatchContext{
		instances_fn:         fn [mut app] (name string) []string {
			return app.provider_runtime_instances(name)
		}
		upstream_enabled_fn:  fn [mut app] (name string, instance string) bool {
			return app.provider_runtime_upstream_enabled(name, instance)
		}
		bootstrap_enabled_fn: fn [mut app] (name string) bool {
			return app.provider_bootstrap_enabled(name)
		}
		ready_fn:             fn [mut app] (name string) bool {
			return app.provider_runtime_ready(name)
		}
		pull_url_fn:          fn [mut app] (name string, instance string) !string {
			return app.provider_runtime_pull_url(name, instance)
		}
	}
}

pub fn (mut app App) provider_runtime_snapshot(name string) ?string {
	return match name {
		'feishu' {
			json.encode(app.feishu_runtime_snapshot())
		}
		'codex' {
			json.encode(app.admin_codex_snapshot())
		}
		'db' {
			app.db_runtime_snapshot()
		}
		else {
			mut spec := app.get_provider_spec(name) or { return none }
			spec.runtime.snapshot(mut spec.lifecycle_ctx)
		}
	}
}

// build_provider_context constructs a provider.RuntimeContext whose closures
// capture App, bridging provider adapters to the main program.
fn (mut app App) build_provider_context(name string) provider.RuntimeContext {
	return provider.RuntimeContext{
		snapshot: fn [mut app, name] () string {
			return match name {
				'feishu' { json.encode(app.feishu_runtime_snapshot()) }
				'codex' { json.encode(app.admin_codex_snapshot()) }
				'db' { app.db_runtime_snapshot() }
				else { '{}' }
			}
		}
		start:    fn [mut app, name] () ! {
			if name == 'db' {
				if app.db_runtime.enabled && app.db_runtime.socket.trim_space() != '' {
					go app.db_runtime_server_run(app.db_runtime.socket)
				}
			}
			return
		}
		stop:     fn [mut app, name] () ! {
			if name == 'db' {
				app.mu.@lock()
				mut listener := app.db_runtime.request_stop()
				app.mu.unlock()
				if !isnil(listener) {
					listener.close() or {}
				}
			}
			return
		}
		emit:     fn [mut app] (kind string, fields map[string]string) {
			app.emit(kind, fields)
		}
	}
}

pub fn (mut app App) provider_runtime_feishu_snapshot() FeishuRuntimeSnapshot {
	return app.feishu_runtime_snapshot()
}

pub fn (mut app App) provider_runtime_feishu_app_snapshot(instance string) ?FeishuRuntimeAppSnapshot {
	return app.feishu_runtime_app_snapshot(instance)
}

pub fn (mut app App) provider_runtime_upstream_snapshot(name string, instance string) ?WebSocketUpstreamSnapshot {
	return match name {
		'feishu' {
			snapshot := app.provider_runtime_feishu_app_snapshot(instance) or { return none }
			provider.feishu_upstream_snapshot(snapshot)
		}
		'codex' {
			mut resolved_instance := instance.trim_space()
			if resolved_instance == '' {
				resolved_instance = 'main'
			}
			state := app.codex_runtime_state_view(resolved_instance)
			enabled := app.provider_runtime_upstream_enabled('codex', resolved_instance)
			return provider.codex_upstream_snapshot(resolved_instance, state,
				enabled)
		}
		else {
			none
		}
	}
}

pub fn (mut app App) provider_runtime_upstream_snapshots(name string) []WebSocketUpstreamSnapshot {
	mut snapshots := []WebSocketUpstreamSnapshot{}
	for instance in app.provider_runtime_instances(name) {
		if snapshot := app.provider_runtime_upstream_snapshot(name, instance) {
			snapshots << snapshot
		}
	}
	return snapshots
}

pub fn (mut app App) provider_runtime_upstream_events(name string, instance_filter string) []WebSocketUpstreamEventSnapshot {
	return match name {
		'feishu' {
			provider.feishu_upstream_events(app.provider_runtime_feishu_snapshot(),
				instance_filter)
		}
		'codex' {
			[]WebSocketUpstreamEventSnapshot{}
		}
		else {
			[]WebSocketUpstreamEventSnapshot{}
		}
	}
}

pub fn (mut app App) provider_runtime_metrics(name string) ProviderRuntimeMetrics {
	return match name {
		'feishu' {
			connect_attempts, connect_successes, received_frames, acked_events, messages_sent, send_errors :=
				app.feishu_runtime_totals()
			ProviderRuntimeMetrics{
				connect_attempts:  connect_attempts
				connect_successes: connect_successes
				received_frames:   received_frames
				acked_events:      acked_events
				messages_sent:     messages_sent
				send_errors:       send_errors
			}
		}
		'codex' {
			mut instances := app.provider_runtime_instances('codex')
			if instances.len == 0 {
				instances = ['main']
			}
			mut states := []CodexRuntimeStateView{cap: instances.len}
			for instance in instances {
				states << app.codex_runtime_state_view(instance)
			}
			provider.codex_metrics(states)
		}
		else {
			ProviderRuntimeMetrics{}
		}
	}
}

pub fn (mut app App) provider_runtime_capabilities() map[string]bool {
	ctx := app.build_provider_runtime_dispatch_context()
	return provider.capabilities(ctx)
}

pub fn (mut app App) provider_runtime_gateway_count() int {
	ctx := app.build_provider_runtime_dispatch_context()
	return provider.gateway_count(ctx)
}

pub fn (mut app App) provider_runtime_upstream_launches() []ProviderRuntimeUpstreamLaunch {
	ctx := app.build_provider_runtime_dispatch_context()
	return provider.upstream_launches(ctx)
}

pub fn (mut app App) provider_runtime_upstream_enabled(name string, instance string) bool {
	ctx := app.build_provider_runtime_dispatch_context()
	return provider.upstream_enabled(ctx, name, instance)
}

pub fn (mut app App) provider_runtime_upstream_provider_names() []string {
	ctx := app.build_provider_runtime_dispatch_context()
	return provider.upstream_provider_names(ctx)
}

pub fn (app &App) provider_bootstrap_enabled(name string) bool {
	return match name {
		'feishu' { app.feishu_runtime_enabled() }
		'codex' { app.codex.runtime.enabled || app.provider_instance_list('codex').len > 0 }
		'ollama' { app.codex.ollama_enabled }
		'db' { app.db_runtime.enabled && db.Runtime.compiled() }
		else { false }
	}
}

pub fn (mut app App) provider_runtime_ready(name string) bool {
	return match name {
		'feishu' { app.feishu_runtime_ready() }
		'codex' { app.provider_enabled('codex') }
		'ollama' { app.provider_enabled('ollama') }
		'db' { app.provider_enabled('db') }
		else { false }
	}
}

pub fn (mut app App) provider_runtime_default_instance(name string) string {
	if name == 'feishu' {
		return app.feishu.default_app_name()
	}
	return provider.default_instance(name)
}

pub fn (mut app App) provider_runtime_instances(name string) []string {
	return match name {
		'feishu' {
			app.feishu.app_names()
		}
		'codex' {
			mut out := []string{}
			if app.provider_enabled('codex') {
				out << 'main'
			}
			for spec in app.provider_instance_list('codex') {
				if spec.instance !in out {
					out << spec.instance
				}
			}
			out.sort()
			out
		}
		'ollama' {
			if app.provider_runtime_ready('ollama') {
				['main']
			} else {
				[]string{}
			}
		}
		'db' {
			if app.provider_runtime_ready('db') {
				['main']
			} else {
				[]string{}
			}
		}
		else {
			[]string{}
		}
	}
}

pub fn (mut app App) provider_runtime_pull_url(name string, instance string) !string {
	return match name {
		'feishu' { app.feishu_provider_pull_ws_endpoint(instance) }
		'codex' { app.codex_provider_pull_url(instance) }
		else { error('unknown provider ${name}') }
	}
}

pub fn (mut app App) provider_runtime_reconnect_delay_ms(name string, instance string) int {
	return match name {
		'feishu' {
			if app.feishu.reconnect_delay_ms > 0 {
				app.feishu.reconnect_delay_ms
			} else {
				3000
			}
		}
		'codex' {
			app.codex_provider_reconnect_delay_ms(instance)
		}
		else {
			3000
		}
	}
}

pub fn (mut app App) provider_runtime_on_connecting(name string, instance string) {
	match name {
		'feishu' {
			app.feishu.note_connecting(instance)
		}
		'codex' {
			app.codex_provider_on_connecting(instance)
		}
		else {}
	}
}

pub fn (mut app App) provider_runtime_on_connected(name string, instance string, ws_url string) {
	match name {
		'feishu' {
			app.feishu.note_connected(instance, ws_url)
		}
		'codex' {
			app.codex_provider_on_connected(instance, ws_url)
		}
		else {}
	}
}

pub fn (mut app App) provider_runtime_on_disconnected(name string, instance string, reason string) {
	match name {
		'feishu' {
			app.feishu.note_disconnected(instance, reason)
		}
		'codex' {
			app.codex_provider_on_disconnected(instance, reason)
		}
		else {}
	}
}
