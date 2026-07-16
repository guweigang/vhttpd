module main

import ws

struct WebSocketRuntime {
mut:
	state ws.HubState
}

fn WebSocketRuntime.new(dispatch_mode bool) WebSocketRuntime {
	return WebSocketRuntime{
		state: ws.HubState{
			dispatch_mode:                dispatch_mode
			recent_dispatch_limit:        50
			auto_start_dynamic_upstreams: true
			conns:                        map[string]ws.HubConn{}
			room_members:                 map[string]map[string]bool{}
			conn_rooms:                   map[string]map[string]bool{}
			conn_meta:                    map[string]map[string]string{}
			pending:                      map[string][]ws.HubPendingMessage{}
			upstream_started:             map[string]bool{}
			fixture_runtime:              map[string]ws.FixtureRuntime{}
			recent_activities:            []ws.UpstreamActivitySnapshot{}
		}
	}
}

fn (mut runtime WebSocketRuntime) snapshot(details bool, limit int, offset int, room_filter string, conn_filter string) ws.RuntimeSnapshot {
	return ws.hub_snapshot(mut runtime.state, details, limit, offset, room_filter, conn_filter)
}

fn (mut runtime WebSocketRuntime) active_connections() int {
	runtime.state.mu.@lock()
	defer { runtime.state.mu.unlock() }
	return runtime.state.conns.len
}

fn (runtime &WebSocketRuntime) dispatch_enabled() bool {
	return runtime.state.dispatch_mode
}

fn (runtime &WebSocketRuntime) dynamic_upstream_autostart_enabled() bool {
	return runtime.state.auto_start_dynamic_upstreams
}

fn (mut runtime WebSocketRuntime) mark_upstream_started(key string) bool {
	if key == '' || key == '/' {
		return false
	}
	runtime.state.upstream_mu.@lock()
	defer { runtime.state.upstream_mu.unlock() }
	if key in runtime.state.upstream_started {
		return false
	}
	runtime.state.upstream_started[key] = true
	return true
}

fn (mut runtime WebSocketRuntime) record_upstream_activity(snapshot ws.UpstreamActivitySnapshot) {
	runtime.state.record_upstream_activity(snapshot)
}

fn (mut runtime WebSocketRuntime) upstream_activities_snapshot(limit int, offset int, provider_filter string, instance_filter string) ws.UpstreamActivityListSnapshot {
	return runtime.state.upstream_activities_snapshot(limit, offset, provider_filter,
		instance_filter)
}

fn (mut runtime WebSocketRuntime) fixture_names() []string {
	return runtime.state.fixture_app_names()
}

fn (mut runtime WebSocketRuntime) fixture_snapshot(instance string) ws.UpstreamSnapshot {
	return runtime.state.fixture_snapshot(instance)
}

fn (mut runtime WebSocketRuntime) fixture_events(instance string) []ws.UpstreamEventSnapshot {
	fixture := runtime.state.fixture_ensure(instance)
	return fixture.recent_events.clone()
}

fn (mut runtime WebSocketRuntime) fixture_push_event(instance string, event ws.UpstreamEventSnapshot, recent_event_limit int) {
	runtime.state.fixture_push_event(instance, event, recent_event_limit)
}

fn (mut runtime WebSocketRuntime) fixture_send(instance string) ws.UpstreamSendResult {
	return runtime.state.fixture_send(instance)
}

fn (mut runtime WebSocketRuntime) fixture_update(instance string, target string) !ws.UpstreamUpdateResult {
	return runtime.state.fixture_update_msg(instance, target)
}
