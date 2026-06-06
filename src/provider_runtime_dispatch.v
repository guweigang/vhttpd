module main

import db
import json
import provider

struct ProviderRuntimeDispatch {}

struct ProviderRuntimeDispatchContext {
	instances_fn         fn (string) []string        = unsafe { nil }
	upstream_enabled_fn  fn (string, string) bool    = unsafe { nil }
	bootstrap_enabled_fn fn (string) bool            = unsafe { nil }
	ready_fn             fn (string) bool            = unsafe { nil }
	pull_url_fn          fn (string, string) !string = unsafe { nil }
}

fn (ctx ProviderRuntimeDispatchContext) instances(name string) []string {
	return ctx.instances_fn(name)
}

fn (ctx ProviderRuntimeDispatchContext) upstream_enabled(name string, instance string) bool {
	return ctx.upstream_enabled_fn(name, instance)
}

fn (ctx ProviderRuntimeDispatchContext) bootstrap_enabled(name string) bool {
	return ctx.bootstrap_enabled_fn(name)
}

fn (ctx ProviderRuntimeDispatchContext) ready(name string) bool {
	return ctx.ready_fn(name)
}

fn (ctx ProviderRuntimeDispatchContext) pull_url(name string, instance string) !string {
	return ctx.pull_url_fn(name, instance)
}

fn (mut app App) build_provider_runtime_dispatch_context() ProviderRuntimeDispatchContext {
	return ProviderRuntimeDispatchContext{
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

fn ProviderRuntimeDispatch.gateway_count(ctx ProviderRuntimeDispatchContext) int {
	mut total := 0
	for provider_name in ['feishu', 'codex'] {
		for instance in ctx.instances(provider_name) {
			if ctx.upstream_enabled(provider_name, instance) {
				total++
			}
		}
	}
	return total
}

fn ProviderRuntimeDispatch.capabilities(ctx ProviderRuntimeDispatchContext) map[string]bool {
	feishu_ready := ctx.ready('feishu')
	return {
		'feishu_runtime': feishu_ready
		'feishu_gateway': feishu_ready
	}
}

fn ProviderRuntimeDispatch.upstream_enabled(ctx ProviderRuntimeDispatchContext, name string, instance string) bool {
	return match name {
		'feishu' {
			ctx.ready('feishu') && instance in ctx.instances('feishu')
		}
		'codex' {
			instance in ctx.instances('codex')
		}
		'ollama' {
			ctx.ready('ollama') && instance in ctx.instances('ollama')
		}
		else {
			false
		}
	}
}

fn ProviderRuntimeDispatch.default_instance(name string) string {
	return match name {
		'feishu' { 'main' }
		'codex' { 'main' }
		'ollama' { 'main' }
		'db' { 'main' }
		else { '' }
	}
}

fn ProviderRuntimeDispatch.upstream_provider_names(ctx ProviderRuntimeDispatchContext) []string {
	mut names := []string{}
	for name in ['feishu', 'codex'] {
		mut has_enabled_instance := false
		for instance in ctx.instances(name) {
			if ctx.upstream_enabled(name, instance) {
				has_enabled_instance = true
				break
			}
		}
		if has_enabled_instance {
			names << name
		}
	}
	return names
}

fn ProviderRuntimeDispatch.upstream_launches(ctx ProviderRuntimeDispatchContext) []ProviderRuntimeUpstreamLaunch {
	mut launches := []ProviderRuntimeUpstreamLaunch{}
	feishu_instances := ctx.instances('feishu')
	if ctx.bootstrap_enabled('feishu') && feishu_instances.len > 0 {
		launches << ProviderRuntimeUpstreamLaunch{
			provider: 'feishu'
			instance: ''
			label:    feishu_instances.join(', ')
		}
		for instance in feishu_instances {
			launches << ProviderRuntimeUpstreamLaunch{
				provider: 'feishu'
				instance: instance
				label:    instance
			}
		}
	}
	codex_instances := ctx.instances('codex')
	for instance in codex_instances {
		launches << ProviderRuntimeUpstreamLaunch{
			provider: 'codex'
			instance: instance
			label:    instance
			url:      ctx.pull_url('codex', instance) or { '' }
		}
	}
	return launches
}

fn ProviderRuntimeDispatch.feishu_upstream_snapshot(snapshot FeishuRuntimeAppSnapshot) WebSocketUpstreamSnapshot {
	return WebSocketUpstreamSnapshot{
		provider:                'feishu'
		instance:                snapshot.name
		enabled:                 snapshot.enabled
		configured:              snapshot.configured
		connected:               snapshot.connected
		url:                     snapshot.ws_url
		last_connect_at_unix:    snapshot.last_connect_at_unix
		last_disconnect_at_unix: snapshot.last_disconnect_at_unix
		last_error:              snapshot.last_error
		connect_attempts:        snapshot.connect_attempts
		connect_successes:       snapshot.connect_successes
		received_frames:         snapshot.received_frames
	}
}

fn ProviderRuntimeDispatch.codex_upstream_snapshot(instance string, state CodexRuntimeStateView, enabled bool) WebSocketUpstreamSnapshot {
	return WebSocketUpstreamSnapshot{
		provider:                'codex'
		instance:                instance
		enabled:                 enabled
		configured:              enabled
		connected:               state.connected
		url:                     state.ws_url
		last_connect_at_unix:    state.last_connect_at
		last_disconnect_at_unix: state.last_disconnect_at
		last_error:              state.last_error
		connect_attempts:        state.connect_attempts
		connect_successes:       state.connect_successes
		received_frames:         state.received_frames
	}
}

fn ProviderRuntimeDispatch.feishu_upstream_events(snapshot FeishuRuntimeSnapshot, instance_filter string) []WebSocketUpstreamEventSnapshot {
	mut events := []WebSocketUpstreamEventSnapshot{}
	for app_snapshot in snapshot.apps {
		if instance_filter != '' && app_snapshot.name != instance_filter {
			continue
		}
		for event in app_snapshot.recent_events {
			events << WebSocketUpstreamEventSnapshot{
				provider:    'feishu'
				instance:    app_snapshot.name
				event_type:  event.event_type
				message_id:  event.message_id
				target:      event.chat_id
				target_type: 'chat_id'
				trace_id:    event.trace_id
				received_at: event.received_at
				payload:     event.payload
				metadata:    {
					'action':            event.action
					'event_id':          event.event_id
					'event_kind':        event.event_kind
					'chat_type':         event.chat_type
					'message_type':      event.message_type
					'open_message_id':   event.open_message_id
					'root_id':           event.root_id
					'parent_id':         event.parent_id
					'create_time':       event.create_time
					'sender_id':         event.sender_id
					'sender_id_type':    event.sender_id_type
					'sender_tenant_key': event.sender_tenant_key
					'action_tag':        event.action_tag
					'action_value':      event.action_value
					'token':             event.token
				}
			}
		}
	}
	return events
}

fn ProviderRuntimeDispatch.codex_metrics(states []CodexRuntimeStateView) ProviderRuntimeMetrics {
	mut connect_attempts := i64(0)
	mut connect_successes := i64(0)
	mut received_frames := i64(0)
	for state in states {
		connect_attempts += state.connect_attempts
		connect_successes += state.connect_successes
		received_frames += state.received_frames
	}
	return ProviderRuntimeMetrics{
		connect_attempts:  connect_attempts
		connect_successes: connect_successes
		received_frames:   received_frames
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
			ProviderRuntimeDispatch.feishu_upstream_snapshot(snapshot)
		}
		'codex' {
			mut resolved_instance := instance.trim_space()
			if resolved_instance == '' {
				resolved_instance = 'main'
			}
			state := app.codex_runtime_state_view(resolved_instance)
			enabled := app.provider_runtime_upstream_enabled('codex', resolved_instance)
			return ProviderRuntimeDispatch.codex_upstream_snapshot(resolved_instance, state,
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
			ProviderRuntimeDispatch.feishu_upstream_events(app.provider_runtime_feishu_snapshot(),
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
			ProviderRuntimeDispatch.codex_metrics(states)
		}
		else {
			ProviderRuntimeMetrics{}
		}
	}
}

pub fn (mut app App) provider_runtime_capabilities() map[string]bool {
	ctx := app.build_provider_runtime_dispatch_context()
	return ProviderRuntimeDispatch.capabilities(ctx)
}

pub fn (mut app App) provider_runtime_gateway_count() int {
	ctx := app.build_provider_runtime_dispatch_context()
	return ProviderRuntimeDispatch.gateway_count(ctx)
}

pub fn (mut app App) provider_runtime_upstream_launches() []ProviderRuntimeUpstreamLaunch {
	ctx := app.build_provider_runtime_dispatch_context()
	return ProviderRuntimeDispatch.upstream_launches(ctx)
}

pub fn (mut app App) provider_runtime_upstream_enabled(name string, instance string) bool {
	ctx := app.build_provider_runtime_dispatch_context()
	return ProviderRuntimeDispatch.upstream_enabled(ctx, name, instance)
}

pub fn (mut app App) provider_runtime_upstream_provider_names() []string {
	ctx := app.build_provider_runtime_dispatch_context()
	return ProviderRuntimeDispatch.upstream_provider_names(ctx)
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
		return app.feishu_runtime_default_app_name()
	}
	return ProviderRuntimeDispatch.default_instance(name)
}

pub fn (mut app App) provider_runtime_instances(name string) []string {
	return match name {
		'feishu' {
			app.feishu_runtime_app_names()
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
			app.feishu_runtime_note_connecting(instance)
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
			app.feishu_runtime_note_connected(instance, ws_url)
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
			app.feishu_runtime_note_disconnected(instance, reason)
		}
		'codex' {
			app.codex_provider_on_disconnected(instance, reason)
		}
		else {}
	}
}
