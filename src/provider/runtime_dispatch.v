module provider

import codex
import feishu
import upstream

// ── Dispatch Context ──

pub struct UpstreamRuntimeMapper {}

pub struct RuntimeDispatchContext {
pub:
	instances_fn         fn (string) []string        = unsafe { nil }
	upstream_enabled_fn  fn (string, string) bool    = unsafe { nil }
	bootstrap_enabled_fn fn (string) bool            = unsafe { nil }
	ready_fn             fn (string) bool            = unsafe { nil }
	pull_url_fn          fn (string, string) !string = unsafe { nil }
}

pub fn (ctx RuntimeDispatchContext) instances(name string) []string {
	return ctx.instances_fn(name)
}

pub fn (ctx RuntimeDispatchContext) upstream_enabled(name string, instance string) bool {
	return ctx.upstream_enabled_fn(name, instance)
}

pub fn (ctx RuntimeDispatchContext) bootstrap_enabled(name string) bool {
	return ctx.bootstrap_enabled_fn(name)
}

pub fn (ctx RuntimeDispatchContext) ready(name string) bool {
	return ctx.ready_fn(name)
}

pub fn (ctx RuntimeDispatchContext) pull_url(name string, instance string) !string {
	return ctx.pull_url_fn(name, instance)
}

// ── Dispatch Functions ──

pub fn gateway_count(ctx RuntimeDispatchContext) int {
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

pub fn (ctx RuntimeDispatchContext) gateway_count() int {
	return gateway_count(ctx)
}

pub fn capabilities(ctx RuntimeDispatchContext) map[string]bool {
	feishu_ready := ctx.ready('feishu')
	return {
		'feishu_runtime': feishu_ready
		'feishu_gateway': feishu_ready
	}
}

pub fn (ctx RuntimeDispatchContext) capabilities() map[string]bool {
	return capabilities(ctx)
}

pub fn upstream_enabled(ctx RuntimeDispatchContext, name string, instance string) bool {
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

pub fn (ctx RuntimeDispatchContext) is_upstream_enabled(name string, instance string) bool {
	return upstream_enabled(ctx, name, instance)
}

pub fn default_instance(name string) string {
	return match name {
		'feishu' { 'main' }
		'codex' { 'main' }
		'ollama' { 'main' }
		'db' { 'main' }
		else { '' }
	}
}

pub fn upstream_provider_names(ctx RuntimeDispatchContext) []string {
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

pub fn (ctx RuntimeDispatchContext) upstream_provider_names() []string {
	return upstream_provider_names(ctx)
}

pub fn upstream_launches(ctx RuntimeDispatchContext) []ProviderRuntimeUpstreamLaunch {
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

pub fn (ctx RuntimeDispatchContext) upstream_launches() []ProviderRuntimeUpstreamLaunch {
	return upstream_launches(ctx)
}

pub fn feishu_upstream_snapshot(snapshot feishu.RuntimeAppSnapshot) upstream.UpstreamSnapshot {
	return upstream.UpstreamSnapshot{
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

pub fn codex_upstream_snapshot(instance string, state codex.RuntimeStateView, enabled bool) upstream.UpstreamSnapshot {
	return upstream.UpstreamSnapshot{
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

pub fn feishu_upstream_events(snapshot feishu.RuntimeSnapshot, instance_filter string) []upstream.UpstreamEventSnapshot {
	mut events := []upstream.UpstreamEventSnapshot{}
	for app_snapshot in snapshot.apps {
		if instance_filter != '' && app_snapshot.name != instance_filter {
			continue
		}
		for event in app_snapshot.recent_events {
			events << upstream.UpstreamEventSnapshot{
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

pub fn codex_metrics(states []codex.RuntimeStateView) ProviderRuntimeMetrics {
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

pub fn UpstreamRuntimeMapper.from_feishu_snapshot(snapshot feishu.RuntimeAppSnapshot) upstream.UpstreamSnapshot {
	return feishu_upstream_snapshot(snapshot)
}

pub fn UpstreamRuntimeMapper.from_codex_state(instance string, state codex.RuntimeStateView, enabled bool) upstream.UpstreamSnapshot {
	return codex_upstream_snapshot(instance, state, enabled)
}

pub fn UpstreamRuntimeMapper.events_from_feishu_snapshot(snapshot feishu.RuntimeSnapshot, instance_filter string) []upstream.UpstreamEventSnapshot {
	return feishu_upstream_events(snapshot, instance_filter)
}

pub fn ProviderRuntimeMetrics.from_feishu_totals(connect_attempts i64, connect_successes i64, received_frames i64, acked_events i64, messages_sent i64, send_errors i64) ProviderRuntimeMetrics {
	return ProviderRuntimeMetrics{
		connect_attempts:  connect_attempts
		connect_successes: connect_successes
		received_frames:   received_frames
		acked_events:      acked_events
		messages_sent:     messages_sent
		send_errors:       send_errors
	}
}

pub fn ProviderRuntimeMetrics.from_codex_states(states []codex.RuntimeStateView) ProviderRuntimeMetrics {
	return codex_metrics(states)
}
