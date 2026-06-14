module main

import command
import executor
import provider as provider_pkg
import upstream
import upstream.transport
import ws

fn upstream_activity_from_ws(snapshot ws.UpstreamActivitySnapshot) upstream.UpstreamActivitySnapshot {
	return upstream.UpstreamActivitySnapshot{
		provider:       snapshot.provider
		instance:       snapshot.instance
		trace_id:       snapshot.trace_id
		activity_id:    snapshot.activity_id
		event_type:     snapshot.event_type
		message_id:     snapshot.message_id
		target_type:    snapshot.target_type
		target:         snapshot.target
		payload:        snapshot.payload
		received_at:    snapshot.received_at
		worker_handled: snapshot.worker_handled
		worker_error:   snapshot.worker_error
		error_class:    snapshot.error_class
		command_error:  snapshot.command_error
		commands:       snapshot.commands.clone()
		recorded_at:    snapshot.recorded_at
	}
}

fn ws_activity_from_upstream(snapshot upstream.UpstreamActivitySnapshot) ws.UpstreamActivitySnapshot {
	return ws.UpstreamActivitySnapshot{
		provider:       snapshot.provider
		instance:       snapshot.instance
		trace_id:       snapshot.trace_id
		activity_id:    snapshot.activity_id
		event_type:     snapshot.event_type
		message_id:     snapshot.message_id
		target_type:    snapshot.target_type
		target:         snapshot.target
		payload:        snapshot.payload
		received_at:    snapshot.received_at
		worker_handled: snapshot.worker_handled
		worker_error:   snapshot.worker_error
		error_class:    snapshot.error_class
		command_error:  snapshot.command_error
		commands:       snapshot.commands.clone()
		recorded_at:    snapshot.recorded_at
	}
}

fn upstream_event_from_ws(snapshot ws.UpstreamEventSnapshot) upstream.UpstreamEventSnapshot {
	return upstream.UpstreamEventSnapshot{
		provider:    snapshot.provider
		instance:    snapshot.instance
		event_type:  snapshot.event_type
		message_id:  snapshot.message_id
		target:      snapshot.target
		target_type: snapshot.target_type
		trace_id:    snapshot.trace_id
		received_at: snapshot.received_at
		payload:     snapshot.payload
		metadata:    snapshot.metadata.clone()
	}
}

fn upstream_snapshot_from_ws(snapshot ws.UpstreamSnapshot) upstream.UpstreamSnapshot {
	return upstream.UpstreamSnapshot{
		provider:                snapshot.provider
		instance:                snapshot.instance
		enabled:                 snapshot.enabled
		configured:              snapshot.configured
		connected:               snapshot.connected
		url:                     snapshot.url
		last_connect_at_unix:    snapshot.last_connect_at_unix
		last_disconnect_at_unix: snapshot.last_disconnect_at_unix
		last_error:              snapshot.last_error
		connect_attempts:        snapshot.connect_attempts
		connect_successes:       snapshot.connect_successes
		received_frames:         snapshot.received_frames
	}
}

fn ws_event_from_upstream(snapshot upstream.UpstreamEventSnapshot) ws.UpstreamEventSnapshot {
	return ws.UpstreamEventSnapshot{
		provider:    snapshot.provider
		instance:    snapshot.instance
		event_type:  snapshot.event_type
		message_id:  snapshot.message_id
		target:      snapshot.target
		target_type: snapshot.target_type
		trace_id:    snapshot.trace_id
		received_at: snapshot.received_at
		payload:     snapshot.payload
		metadata:    snapshot.metadata.clone()
	}
}

fn (mut app App) websocket_upstream_record_activity(snapshot upstream.UpstreamActivitySnapshot) {
	app.transport.websocket.record_upstream_activity(ws_activity_from_upstream(snapshot))
}

fn (mut app App) admin_websocket_upstream_activities_snapshot(limit int, offset int, provider_filter string, instance_filter string) upstream.UpstreamActivityListSnapshot {
	ws_snapshot := app.transport.websocket.upstream_activities_snapshot(limit, offset, provider_filter,
		instance_filter)
	mut activities := []upstream.UpstreamActivitySnapshot{cap: ws_snapshot.activities.len}
	for activity in ws_snapshot.activities {
		activities << upstream_activity_from_ws(activity)
	}
	return upstream.UpstreamActivityListSnapshot{
		returned_count: ws_snapshot.returned_count
		limit:          ws_snapshot.limit
		offset:         ws_snapshot.offset
		activities:     activities
	}
}

fn (mut app App) execute_websocket_upstream_commands(source_activity_id string, commands []transport.WorkerWebSocketUpstreamCommand) ([]executor.WebSocketUpstreamCommandActivity, string) {
	cmd_ctx := app.build_command_context()
	mut exec := command.CommandExecutor.new(cmd_ctx)
	ctx := DispatchContext{}
	return exec.execute(source_activity_id, ctx, commands)
}

fn (mut app App) admin_websocket_upstreams_snapshot(details bool, limit int, offset int, provider_filter string, instance_filter string) upstream.UpstreamRuntimeSnapshot {
	mut sessions := []upstream.UpstreamSnapshot{}
	for name in app.provider_runtime_instances(provider_pkg.ProviderName.feishu()) {
		if provider_filter != '' && provider_filter != websocket_upstream_provider_feishu {
			break
		}
		if instance_filter != '' && instance_filter != name {
			continue
		}
		if snapshot := app.websocket_upstream_snapshot(websocket_upstream_provider_feishu, name) {
			sessions << snapshot
		}
	}
	for snapshot in app.provider_runtime_upstream_snapshots(provider_pkg.ProviderName.codex()) {
		if provider_filter != '' && provider_filter != websocket_upstream_provider_codex {
			break
		}
		if instance_filter != '' && instance_filter != snapshot.instance {
			continue
		}
		sessions << snapshot
	}
	for name in app.transport.websocket.fixture_app_names() {
		if provider_filter != '' && provider_filter != websocket_upstream_provider_fixture {
			continue
		}
		if instance_filter != '' && instance_filter != name {
			continue
		}
		if snapshot := app.websocket_upstream_snapshot(websocket_upstream_provider_fixture, name) {
			sessions << snapshot
		}
	}
	return upstream.UpstreamRuntimeSnapshot.from_sessions(sessions, details, limit, offset)
}

fn (mut app App) admin_websocket_upstream_events_snapshot(limit int, offset int, provider_filter string, instance_filter string) upstream.UpstreamEventListSnapshot {
	mut events := []upstream.UpstreamEventSnapshot{}
	if provider_filter == '' || provider_filter == websocket_upstream_provider_feishu {
		events << app.provider_runtime_upstream_events(provider_pkg.ProviderName.feishu(),
			instance_filter)
	}
	if provider_filter == '' || provider_filter == websocket_upstream_provider_fixture {
		for name in app.transport.websocket.fixture_app_names() {
			if instance_filter != '' && name != instance_filter {
				continue
			}
			runtime := app.transport.websocket.fixture_ensure(name)
			for event in runtime.recent_events {
				events << upstream_event_from_ws(event)
			}
		}
	}
	events.sort(a.received_at > b.received_at)
	return upstream.UpstreamEventListSnapshot.from_events(events, limit, offset)
}
